// Cliente HTTP com limitação de taxa, respeito a Retry-After, retentativas e métricas.
export interface Metricas { requisicoes: number; respostas429: number; erros: number }

export interface LogFn {
  (nivel: 'INFO' | 'AVISO' | 'ERRO', msg: string, extra?: Record<string, unknown>): void
}

export interface OpcoesCliente {
  baseUrl: string
  /** intervalo mínimo entre requisições (ms). Compras: ~600 ms ≈ 100 req/min */
  intervaloMinMs: number
  maxTentativas?: number
  timeoutMs?: number
  log?: LogFn
  fetchImpl?: typeof fetch
  sleep?: (ms: number) => Promise<void>
}

export class HttpErro extends Error {
  constructor(public status: number, public corpo: string, public url: string) {
    super(`HTTP ${status} em ${url}: ${corpo.slice(0, 200)}`)
  }
}

export class ClienteApi {
  readonly metricas: Metricas = { requisicoes: 0, respostas429: 0, erros: 0 }
  private ultimo = 0
  private fila: Promise<void> = Promise.resolve()
  private readonly f: typeof fetch
  private readonly sleep: (ms: number) => Promise<void>

  constructor(private o: OpcoesCliente) {
    this.f = o.fetchImpl ?? fetch
    this.sleep = o.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)))
  }

  /** serializa o espaçamento entre chamadas mesmo com concorrência */
  private async aguardarVez(): Promise<void> {
    const vez = this.fila.then(async () => {
      const espera = this.ultimo + this.o.intervaloMinMs - Date.now()
      if (espera > 0) await this.sleep(espera)
      this.ultimo = Date.now()
    })
    this.fila = vez.catch(() => undefined)
    return vez
  }

  async getJson<T>(caminho: string, params: Record<string, string | number | boolean | undefined>): Promise<{ status: number; corpo: T | null; url: string }> {
    const qs = new URLSearchParams()
    for (const [k, v] of Object.entries(params)) if (v !== undefined && v !== '') qs.set(k, String(v))
    const url = `${this.o.baseUrl}${caminho}?${qs}`
    const max = this.o.maxTentativas ?? 6
    for (let tentativa = 1; tentativa <= max; tentativa++) {
      await this.aguardarVez()
      this.metricas.requisicoes++
      let resp: Response
      try {
        const ctrl = new AbortController()
        const t = setTimeout(() => ctrl.abort(), this.o.timeoutMs ?? 60_000)
        resp = await this.f(url, { headers: { accept: 'application/json' }, signal: ctrl.signal })
        clearTimeout(t)
      } catch (e) {
        this.metricas.erros++
        this.o.log?.('AVISO', `falha de rede (tentativa ${tentativa})`, { url, erro: String(e) })
        await this.sleep(Math.min(2 ** tentativa * 1000, 30_000))
        continue
      }
      if (resp.status === 429) {
        this.metricas.respostas429++
        const ra = Number(resp.headers.get('retry-after')) || 10
        await this.sleep(ra * 1000)
        continue
      }
      if (resp.status === 204) return { status: 204, corpo: null, url }   // PNCP: sem conteúdo
      const texto = await resp.text()
      if (resp.status >= 500) {
        this.metricas.erros++
        this.o.log?.('AVISO', `HTTP ${resp.status} (tentativa ${tentativa})`, { url })
        await this.sleep(Math.min(2 ** tentativa * 1000, 30_000))
        continue
      }
      if (!resp.ok) { this.metricas.erros++; throw new HttpErro(resp.status, texto, url) }  // 4xx = erro de parâmetro: não repetir
      return { status: resp.status, corpo: (texto.trim() ? JSON.parse(texto) : null) as T | null, url }
    }
    throw new HttpErro(0, 'tentativas esgotadas', url)
  }
}

/** Divide [ini, fim] em janelas de no máximo `dias` (a API do Compras recusa > 365 dias). */
export function janelas(ini: string, fim: string, dias = 365): Array<[string, string]> {
  const out: Array<[string, string]> = []
  const d0 = new Date(ini + 'T00:00:00Z'), d1 = new Date(fim + 'T00:00:00Z')
  let a = d0
  while (a <= d1) {
    const b = new Date(Math.min(a.getTime() + (dias - 1) * 86_400_000, d1.getTime()))
    out.push([a.toISOString().slice(0, 10), b.toISOString().slice(0, 10)])
    a = new Date(b.getTime() + 86_400_000)
  }
  return out
}

export async function sha256(texto: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(texto))
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, '0')).join('')
}
