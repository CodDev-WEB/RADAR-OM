// Camada de persistência. Implementação via PostgREST (Supabase) usando apenas fetch.
// A chave service_role fica SOMENTE no backend (secret do Worker/Edge Function).
type Linha = Record<string, unknown>

/** Cabeçalhos de autenticação de serviço no Supabase.
 *  Chaves novas (sb_secret_/sb_publishable_) não são JWT: vão SOMENTE em `apikey`.
 *  Chaves legadas (JWT service_role/anon, começam com "eyJ") vão em `apikey` e `Authorization`. */
export function cabecalhosChave(chave: string): Record<string, string> {
  return chave.startsWith('eyJ') ? { apikey: chave, authorization: `Bearer ${chave}` } : { apikey: chave }
}

export interface Armazenamento {
  upsert(tabela: string, linhas: Linha[], conflito: string, ignorarDuplicados?: boolean): Promise<Linha[]>
  select(tabela: string, filtro: string): Promise<Linha[]>
  rpc<T = unknown>(funcao: string, args: Linha): Promise<T>
  update(tabela: string, filtro: string, valores: Linha): Promise<void>
}

export class SupabaseRest implements Armazenamento {
  constructor(private url: string, private chave: string, private schema = 'radar', private f: typeof fetch = fetch) {}

  private h(extra: Record<string, string> = {}) {
    return { ...cabecalhosChave(this.chave), 'content-type': 'application/json',
             'accept-profile': this.schema, 'content-profile': this.schema, ...extra }
  }
  private async ok(r: Response) {
    if (!r.ok) throw new Error(`PostgREST ${r.status}: ${(await r.text()).slice(0, 300)}`)
    return r.status === 204 ? [] : r.json()
  }
  async upsert(tabela: string, linhas: Linha[], conflito: string, ignorar = false) {
    if (!linhas.length) return []
    const out: Linha[] = []
    for (let i = 0; i < linhas.length; i += 500) {
      const r = await this.f(`${this.url}/rest/v1/${tabela}?on_conflict=${conflito}`, {
        method: 'POST', body: JSON.stringify(linhas.slice(i, i + 500)),
        headers: this.h({ prefer: `resolution=${ignorar ? 'ignore' : 'merge'}-duplicates,return=representation` }),
      })
      out.push(...((await this.ok(r)) as Linha[]))
    }
    return out
  }
  async select(tabela: string, filtro: string) {
    return (await this.ok(await this.f(`${this.url}/rest/v1/${tabela}?${filtro}`, { headers: this.h() }))) as Linha[]
  }
  async rpc<T>(funcao: string, args: Linha) {
    return (await this.ok(await this.f(`${this.url}/rest/v1/rpc/${funcao}`, { method: 'POST', body: JSON.stringify(args), headers: this.h() }))) as T
  }
  async update(tabela: string, filtro: string, valores: Linha) {
    await this.ok(await this.f(`${this.url}/rest/v1/${tabela}?${filtro}`, { method: 'PATCH', body: JSON.stringify(valores), headers: this.h({ prefer: 'return=minimal' }) }))
  }
}
