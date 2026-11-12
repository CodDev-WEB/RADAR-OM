// Endpoints VERIFICADOS em 12/11/2026 (ver docs/mapa-apis.md). Nada aqui é suposto.
import { ClienteApi, janelas } from './http.js'

export const CNPJ_EXERCITO = '00394452000103'
export const ORGAO_SIASG_EXERCITO = 52121

interface EnvelopeCompras<T> { resultado: T[]; totalRegistros: number; totalPaginas: number; paginasRestantes: number }
interface EnvelopePncp<T> { data: T[]; totalRegistros: number; totalPaginas: number; numeroPagina: number; paginasRestantes: number; empty: boolean }

export interface PaginaColetada<T> { endpoint: string; params: Record<string, unknown>; registros: T[]; corpoBruto: unknown }

/** percorre todas as páginas de um endpoint do Compras (tamanhoPagina máx. 500) */
export async function* paginarCompras<T>(c: ClienteApi, endpoint: string, params: Record<string, string | number | undefined>, tamanho = 500): AsyncGenerator<PaginaColetada<T>> {
  for (let pagina = 1; ; pagina++) {
    const p = { ...params, pagina, tamanhoPagina: endpoint.includes('modulo-uasg') ? undefined : tamanho }
    const { corpo } = await c.getJson<EnvelopeCompras<T>>(endpoint, p)
    const regs = corpo?.resultado ?? []
    yield { endpoint, params: p, registros: regs, corpoBruto: corpo }
    if (!corpo || corpo.paginasRestantes <= 0 || regs.length === 0) return
  }
}

/** PNCP: tamanhoPagina máx. 500 em atas/contratos, 50 em contratações; 204 = vazio */
export async function* paginarPncp<T>(c: ClienteApi, endpoint: string, params: Record<string, string | number | undefined>, tamanho: number): AsyncGenerator<PaginaColetada<T>> {
  for (let pagina = 1; ; pagina++) {
    const p = { ...params, pagina, tamanhoPagina: tamanho }
    const { corpo } = await c.getJson<EnvelopePncp<T>>(endpoint, p)
    const regs = corpo?.data ?? []
    yield { endpoint, params: p, registros: regs, corpoBruto: corpo }
    if (!corpo || pagina >= corpo.totalPaginas || regs.length === 0) return
  }
}

// ---------------- Compras.gov.br ----------------
export const compras = {
  uasgsExercito: (c: ClienteApi) =>
    paginarCompras<Record<string, any>>(c, '/modulo-uasg/1_consultarUasg', { statusUasg: 'true', cnpjCpfOrgao: CNPJ_EXERCITO }),

  /** atas cuja vigência termina na janela — base do monitoramento de vigentes/vencimentos.
   *  ATENÇÃO: filtrar por codigoOrgao NÃO funciona (ignorado em silêncio); filtrar por UASG. */
  atasPorFimVigencia: async function* (c: ClienteApi, uasg: string, ini: string, fim: string) {
    for (const [a, b] of janelas(ini, fim))
      yield* paginarCompras<Record<string, any>>(c, '/modulo-arp/1.2_consultarARP_FimVigencia',
        { codigoUnidadeGerenciadora: uasg, dataVigenciaFinalMin: a, dataVigenciaFinalMax: b })
  },
  atasPorInicioVigencia: async function* (c: ClienteApi, uasg: string, ini: string, fim: string) {
    for (const [a, b] of janelas(ini, fim))
      yield* paginarCompras<Record<string, any>>(c, '/modulo-arp/1_consultarARP',
        { codigoUnidadeGerenciadora: uasg, dataVigenciaInicialMin: a, dataVigenciaInicialMax: b })
  },
  ataPorId: (c: ClienteApi, numeroControlePncpAta: string) =>
    paginarCompras<Record<string, any>>(c, '/modulo-arp/1.1_consultarARP_Id', { numeroControlePncpAta }),
  itensPorAta: (c: ClienteApi, numeroControlePncpAta: string) =>
    paginarCompras<Record<string, any>>(c, '/modulo-arp/2.1_consultarARPItem_Id', { numeroControlePncpAta }),
  unidadesItem: (c: ClienteApi, numeroAta: string, unidadeGerenciadora: string, numeroItem: string) =>
    paginarCompras<Record<string, any>>(c, '/modulo-arp/3_consultarUnidadesItem', { numeroAta, unidadeGerenciadora, numeroItem }),
  empenhosSaldo: (c: ClienteApi, numeroAta: string, unidadeGerenciadora: string) =>
    paginarCompras<Record<string, any>>(c, '/modulo-arp/4_consultarEmpenhosSaldoItem', { numeroAta, unidadeGerenciadora }),
  adesoesItem: (c: ClienteApi, numeroAta: string, unidadeGerenciadora: string, numeroItem: string) =>
    paginarCompras<Record<string, any>>(c, '/modulo-arp/5_consultarAdesoesItem', { numeroAta, unidadeGerenciadora, numeroItem }),
}

// ---------------- PNCP ----------------
const ymd = (iso: string) => iso.replaceAll('-', '')
export const pncp = {
  atasAtualizadas: (c: ClienteApi, ini: string, fim: string) =>
    paginarPncp<Record<string, any>>(c, '/v1/atas/atualizacao', { dataInicial: ymd(ini), dataFinal: ymd(fim), cnpj: CNPJ_EXERCITO }, 500),
  contratosAtualizados: (c: ClienteApi, ini: string, fim: string) =>
    paginarPncp<Record<string, any>>(c, '/v1/contratos/atualizacao', { dataInicial: ymd(ini), dataFinal: ymd(fim), cnpjOrgao: CNPJ_EXERCITO }, 500),
}
