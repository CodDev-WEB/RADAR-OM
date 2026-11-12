// Teste ponta a ponta do coletor com RESPOSTAS REAIS gravadas em 12/11/2026.
// Executa: npx tsx test/sincronizacao.test.ts
import { readFileSync } from 'node:fs'
import { ClienteApi, janelas } from '../src/http.js'
import { Sincronizador } from '../src/sincronizacao.js'
import type { Armazenamento } from '../src/armazenamento.js'

const RAW = new URL('../../data/raw/', import.meta.url)
const ler = (f: string) => JSON.parse(readFileSync(new URL(f, RAW), 'utf8'))
const uasgs: any[] = ler('compras_uasgs_exercito.json')
const valid: Record<string, any> = ler('compras_validacao_adesoes.json')
const ctrSlim = ler('pncp_contratos_exercito_2026_vinculados_ata.json')
// reconstrói o formato original do PNCP a partir da amostra compactada
const contratosPncp = ctrSlim.rows.map((r: any[]) => {
  const o: any = Object.fromEntries(ctrSlim.K.map((k: string, i: number) => [k, r[i]]))
  return { numeroControlePNCP: o.numeroControlePNCP, numeroControlePncpAta: o.numeroControlePncpAta, numeroControlePncpCompra: o.numeroControlePncpCompra,
    frutoAdesao: o.frutoAdesao, unidadeOrgao: { codigoUnidade: o.codigoUnidade, nomeUnidade: o.nomeUnidade, ufSigla: o.uf },
    niFornecedor: o.niFornecedor, nomeRazaoSocialFornecedor: o.nomeFornecedor, valorInicial: o.valorInicial, valorGlobal: o.valorGlobal,
    dataAssinatura: o.dataAssinatura, dataVigenciaInicio: o.vigenciaInicio, dataVigenciaFim: o.vigenciaFim, tipoContrato: { nome: o.tipoContrato },
    categoriaProcesso: { nome: o.categoria }, objetoContrato: o.objeto, processo: o.processo, numeroContratoEmpenho: o.numeroContratoEmpenho, dataAtualizacaoGlobal: o.dataAtualizacaoGlobal }
})

// ---------------- fetch simulado ----------------
let forcar429 = 1
const chamadas: string[] = []
const env = (resultado: unknown[]) => ({ resultado, totalRegistros: resultado.length, totalPaginas: 1, paginasRestantes: 0 })
const fakeFetch = (async (input: any) => {
  const u = new URL(String(input)); const p = Object.fromEntries(u.searchParams); chamadas.push(u.pathname)
  const json = (b: unknown, s = 200, h: Record<string, string> = {}) => new Response(JSON.stringify(b), { status: s, headers: h })
  if (u.pathname.endsWith('5_consultarAdesoesItem') && forcar429-- > 0) return json({ statusCode: 429 }, 429, { 'retry-after': '0' })
  if (u.pathname.endsWith('2_consultarOrgao')) return json(env(p.codigoOrgao === '52121' ? [{ codigoOrgao: 52121, nomeOrgao: 'COMANDO DO EXERCITO', nomeMnemonicoOrgao: 'CMDO EX', cnpjCpfOrgao: '00394452000103', codigoOrgaoVinculado: 52000, nomeOrgaoVinculado: 'MINISTERIO DEFESA' }] : []))
  if (u.pathname.endsWith('1_consultarUasg')) return json(env(p.codigoUasg ? uasgs.filter((x) => x.codigoUasg === p.codigoUasg) : uasgs))
  if (u.pathname.endsWith('1.2_consultarARP_FimVigencia')) {
    const dias = (Date.parse(p.dataVigenciaFinalMax) - Date.parse(p.dataVigenciaFinalMin)) / 864e5
    if (dias > 365) return json({ title: 'Período inicial e final maior que 365 dias.' }, 400)
    return json(env([]))
  }
  const v = valid[p.numeroControlePncpAta] ?? (p.numeroAta ? Object.values(valid).find((x: any) => x?.ata?.resultado?.[0]?.numeroAtaRegistroPreco === p.numeroAta) : undefined)
  if (u.pathname.endsWith('1.1_consultarARP_Id')) return json(v ? v.ata : env([]))
  if (u.pathname.endsWith('2.1_consultarARPItem_Id')) return json(v ? v.itens : env([]))
  if (u.pathname.endsWith('3_consultarUnidadesItem')) return json(env(v ? v.unid.filter((x: any) => x.numeroItem === p.numeroItem) : []))
  if (u.pathname.endsWith('5_consultarAdesoesItem')) return json(env(v ? v.ades.filter((x: any) => x._item === p.numeroItem).map(({ _item, ...r }: any) => r) : []))
  if (u.pathname.endsWith('4_consultarEmpenhosSaldoItem')) return json(env([]))
  if (u.pathname.endsWith('/v1/contratos/atualizacao')) return json({ data: contratosPncp, totalRegistros: contratosPncp.length, totalPaginas: 1, numeroPagina: 1 })
  if (u.pathname.endsWith('/v1/atas/atualizacao')) return new Response(null, { status: 204 })
  return json({ erro: 'rota não simulada ' + u.pathname }, 404)
}) as typeof fetch

// ---------------- armazenamento em memória (simula PostgREST + RPCs) ----------------
class Memoria implements Armazenamento {
  t: Record<string, any[]> = {}
  seq = 1
  private tab(n: string) { return (this.t[n] ??= []) }
  private calc(n: string, r: any) { return n === 'uasgs' ? { ...r, pertence_exercito: r.codigo_orgao === 52121 } : r }
  async upsert(n: string, linhas: any[], conflito: string, ignorar = false) {
    const ks = conflito.split(','); const T = this.tab(n); const out: any[] = []
    // simula a FK uasgs.codigo_orgao → orgaos_publicos (erro 23503 que ocorreu no Supabase)
    if (n === 'uasgs') for (const l of linhas) if (l.codigo_orgao != null && !this.tab('orgaos_publicos').some((o) => o.codigo_orgao === l.codigo_orgao))
      throw new Error(`PostgREST 409: 23503 Key (codigo_orgao)=(${l.codigo_orgao}) is not present in table "orgaos_publicos"`)
    for (const l of linhas) {
      const ex = ks[0] === 'id' ? undefined : T.find((r) => ks.every((k) => JSON.stringify(r[k]) === JSON.stringify(l[k])))
      if (ex) { if (!ignorar) Object.assign(ex, l); if (!ignorar) out.push(ex) } else { const r = { id: this.seq++, ...l }; T.push(r); out.push(r) }
    }
    return out.map((r) => this.calc(n, r))
  }
  private filtrar(n: string, filtro: string) {
    let rows = this.tab(n).map((r) => this.calc(n, r)); let limit = Infinity
    for (const par of filtro.split('&')) {
      const [k, v] = [par.slice(0, par.indexOf('=')), decodeURIComponent(par.slice(par.indexOf('=') + 1))]
      if (k === 'select' || k === 'order') continue
      if (k === 'limit') { limit = +v; continue }
      const [op, ...resto] = v.split('.'); const val = resto.join('.')
      rows = rows.filter((r) => {
        const x = r[k]
        if (op === 'eq') return String(x) === val
        if (op === 'is') return String(x) === val
        if (op === 'lt') return Number(x) < Number(val)
        if (op === 'in') return val.slice(1, -1).split(',').map((s) => s.replace(/^"|"$/g, '')).includes(String(x))
        throw new Error('op ' + op)
      })
    }
    return rows.slice(0, limit)
  }
  async select(n: string, f: string) { return this.filtrar(n, f) }
  async update(n: string, f: string, v: any) { for (const r of this.filtrar(n, f)) Object.assign(this.tab(n).find((x) => x.id === r.id || x === r) ?? r, v) }
  async rpc(fn: string, a: any): Promise<any> {
    if (fn === 'liberar_tarefas_presas') return 0
    if (fn === 'reservar_tarefas') {
      const lote = this.tab('fila_coleta').filter((t) => ['PENDENTE', 'ERRO'].includes(t.status) && t.tentativas < 6 && Date.parse(t.proxima_em) <= Date.now())
        .sort((x, y) => x.prioridade - y.prioridade).slice(0, a.p_limite)
      for (const t of lote) { t.status = 'EXECUTANDO'; t.tentativas++ }
      return lote
    }
    throw new Error('rpc ' + fn)
  }
}

// ---------------- execução ----------------
const db = new Memoria()
const semEspera = async () => {}
const log = () => {}
const x = { db, log, hoje: '2026-11-12',
  compras: new ClienteApi({ baseUrl: 'https://dadosabertos.compras.gov.br', intervaloMinMs: 0, fetchImpl: fakeFetch, sleep: semEspera }),
  pncp: new ClienteApi({ baseUrl: 'https://pncp.gov.br/api/consulta', intervaloMinMs: 0, fetchImpl: fakeFetch, sleep: semEspera }) }

let falhas = 0
const ok = (cond: boolean, msg: string) => { console.log(`${cond ? '✔' : '✘'} ${msg}`); if (!cond) falhas++ }

ok(JSON.stringify(janelas('2026-11-11', '2029-11-11')) === JSON.stringify([['2026-11-11','2027-11-10'],['2027-11-11','2028-11-09'],['2028-11-10','2029-11-09'],['2029-11-10','2029-11-11']]), 'janelas ≤ 365 dias')

const s = await Sincronizador.iniciar(x as any, 'DIARIA')
let r = { restantes: 1 }, voltas = 0
while (r.restantes > 0 && voltas++ < 50) r = await s.processarFatia(150)

const T = db.t
ok(T.uasgs.filter((u) => u.codigo_orgao === 52121).length === 509, '509 UASGs do Exército a partir do cadastro oficial')
ok(T.orgaos_publicos?.[0]?.nome === 'COMANDO DO EXERCITO' && T.orgaos_publicos[0].forca === 'EXERCITO', 'órgão 52121 cadastrado a partir do cadastro oficial antes das UASGs')
ok(T.fila_coleta.filter((f) => f.tarefa === 'ATAS_UASG').length === 509, '509 tarefas ATAS_UASG enfileiradas')
ok(T.fila_coleta.every((f) => f.status === 'OK'), `fila concluída sem erros (${T.fila_coleta.length} tarefas)`)
ok(!!T.atas_registro_precos?.find((a) => a.numero_ata === '00032/2025' && a.codigo_uasg_gerenciadora === '160047'), 'ata 00032/2025 do Cmdo 10ª RM descoberta a partir do contrato PNCP fruto de adesão')
ok(T.adesoes?.length === 11, `11 adesões coletadas (obtido: ${T.adesoes?.length})`)
const marinha = T.uasgs.find((u) => u.codigo_uasg === '767200')
ok(!!marinha && marinha.codigo_orgao !== 52121, 'UASG 767200 (Casa do Marinheiro) registrada SEM ser classificada como Exército')
ok(x.compras.metricas.respostas429 === 1, 'HTTP 429 tratado com retentativa')
ok(T.unidades_itens_ata?.length === 11, `11 linhas de unidades por item (obtido: ${T.unidades_itens_ata?.length})`)
const sync = T.sincronizacoes[0]
ok(sync.status === 'SUCESSO' && !!sync.finalizada_em, `sincronização finalizada: ${sync.status}, ${sync.requisicoes} requisições`)
ok(T.payloads.every((p) => /^[0-9a-f]{64}$/.test(p.hash_sha256)), `${T.payloads.length} payloads com hash SHA-256 (rastreabilidade)`)
const adesoesPorUasg = T.adesoes.reduce((m: any, a: any) => (m[a.codigo_uasg_aderente] = (m[a.codigo_uasg_aderente] ?? 0) + 1, m), {})
ok(adesoesPorUasg['160149'] === 3 && adesoesPorUasg['160056'] === 2, 'contagem por aderente confere (4ª Bda C Mec: 3; 2º CGEO: 2)')

// segunda execução no dia seguinte: saldo inalterado → não deve reconsultar adesões
const antes = chamadas.filter((c) => c.endsWith('5_consultarAdesoesItem')).length
const s2 = await Sincronizador.iniciar({ ...x, hoje: '2026-11-13' } as any, 'DIARIA')
for (const f of T.fila_coleta.filter((f) => f.tarefa === 'ITENS_ATA')) Object.assign(f, { status: 'PENDENTE', tentativas: 0 })
r = { restantes: 1 }; voltas = 0
while (r.restantes > 0 && voltas++ < 50) r = await s2.processarFatia(150)
const depois = chamadas.filter((c) => c.endsWith('5_consultarAdesoesItem')).length
ok(depois === antes, `incremental: saldo de adesões inalterado ⇒ 0 novas consultas de adesões (${depois - antes})`)
ok(T.adesoes.length === 11, 'sem duplicidade de adesões após 2ª execução')

for (const f of T.fila_coleta.filter((f:any)=>f.status!=="OK").slice(0,5)) console.log("  pendente:", f.tarefa, JSON.stringify(f.chave), f.status, f.ultimo_erro)
console.log(falhas ? `\n${falhas} FALHA(S)` : '\nTODOS OS TESTES PASSARAM')
process.exit(falhas ? 1 : 0)
