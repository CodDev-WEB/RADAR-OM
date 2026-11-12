// Teste ponta a ponta do coletor (plano gratuito): Worker real + radar.ingerir() no PostgreSQL local
// + respostas REAIS das APIs gravadas em 12/11/2026 (data/raw).
// Requer: PostgreSQL local com as migrações aplicadas no banco indicado em RADAR_DB (padrão radar_ing).
import { execFileSync } from 'node:child_process'
import { readFileSync, writeFileSync, chmodSync } from 'node:fs'
import { processarFila, rpc } from '../src/worker.js'

const DB = process.env.RADAR_DB || 'radar_ing'
const RAW = new URL('../../data/raw/', import.meta.url)
const ler = (f: string) => JSON.parse(readFileSync(new URL(f, RAW), 'utf8'))
const sql = (q: string) => execFileSync('su', ['postgres', '-c', `psql -h /tmp -d ${DB} -At -c "${q.replace(/"/g, '\\"')}"`]).toString().trim()

// ---------- fixtures reais ----------
const uasgs: any[] = ler('compras_uasgs_exercito.json')
const valid: Record<string, any> = ler('compras_validacao_adesoes.json'); delete valid.fin
const bec = ler('compras_8bec_160171.json')
const atasBec = bec.atas.map((r: any[]) => Object.fromEntries(bec.AK.map((k: string, i: number) => [k, r[i]])))
const itensBec = bec.itens.map((r: any[]) => ({ ...Object.fromEntries(bec.IK.map((k: string, i: number) => [k, r[i]])), codigoUnidadeGerenciadora: '160171' }))
const atasValid = Object.values(valid).map((v: any) => v.ata.resultado[0])
const ctr = ler('pncp_contratos_exercito_2026_vinculados_ata.json')
const contratos = ctr.rows.map((r: any[]) => { const o: any = Object.fromEntries(ctr.K.map((k: string, i: number) => [k, r[i]]))
  return { numeroControlePNCP: o.numeroControlePNCP, numeroControlePncpAta: o.numeroControlePncpAta, numeroControlePncpCompra: o.numeroControlePncpCompra,
    frutoAdesao: o.frutoAdesao, unidadeOrgao: { codigoUnidade: o.codigoUnidade, nomeUnidade: o.nomeUnidade }, niFornecedor: o.niFornecedor,
    nomeRazaoSocialFornecedor: o.nomeFornecedor, valorInicial: o.valorInicial, valorGlobal: o.valorGlobal, dataAssinatura: o.dataAssinatura,
    dataVigenciaInicio: o.vigenciaInicio, dataVigenciaFim: o.vigenciaFim, tipoContrato: { nome: o.tipoContrato }, categoriaProcesso: { nome: o.categoria },
    objetoContrato: o.objeto, processo: o.processo, numeroContratoEmpenho: o.numeroContratoEmpenho, dataAtualizacaoGlobal: o.dataAtualizacaoGlobal } })

// ---------- fetch simulado: APIs oficiais + PostgREST (rpc → SQL real) ----------
const chamadasGov: string[] = []
let forcar429 = 1, maxSubreqVisto = 0, subreqFatia = 0
const env = { SUPABASE_URL: 'https://teste.supabase.co', SUPABASE_ANON_KEY: 'sb_publishable_x', SUPABASE_SERVICE_ROLE_KEY: 'sb_secret_x' } as any
const env_ = (resultado: unknown[]) => ({ resultado, totalRegistros: resultado.length, totalPaginas: 1, paginasRestantes: 0 })
const resp = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s })
let nRpc = 0
const fakeFetch = (async (input: any, init: any = {}) => {
  subreqFatia++
  const u = new URL(String(input)), p = Object.fromEntries(u.searchParams)
  if (u.hostname === 'teste.supabase.co') {
    const h = new Headers(init.headers)
    if (h.get('authorization')) throw new Error('chave sb_ enviada no Authorization')
    const fn = u.pathname.split('/').pop()!, arq = `/tmp/rpc_${process.pid}_${nRpc++ % 4}.json`
    writeFileSync(arq, init.body); chmodSync(arq, 0o644)
    const j = `(select pg_read_file('${arq}')::jsonb j) s`
    const q: Record<string, string> = {
      reservar_tarefas: `select coalesce(json_agg(t),'[]') from ${j}, radar.reservar_tarefas((j->>'p_limite')::int) t`,
      ingerir: `select radar.ingerir((j->>'p_id')::bigint, (j->>'p_http')::int, j->'p_resposta') from ${j}`,
      devolver_tarefas: `select radar.devolver_tarefas(array(select jsonb_array_elements_text(j->'p_ids'))::bigint[], (j->>'p_segundos')::int) from ${j}`,
      iniciar_ciclo: `select radar.iniciar_ciclo(j->>'p_tipo') from ${j}`,
    }
    return new Response(sql(q[fn]) || 'null', { status: 200 })
  }
  chamadasGov.push(u.pathname)
  if (u.pathname.endsWith('5_consultarAdesoesItem') && forcar429-- > 0) return resp({ statusCode: 429 }, 429)
  if (u.pathname.endsWith('2_consultarOrgao')) return resp(env_(p.codigoOrgao === '52121' ? [{ codigoOrgao: 52121, nomeOrgao: 'COMANDO DO EXERCITO', nomeMnemonicoOrgao: 'CMDO EX', cnpjCpfOrgao: '00394452000103', codigoOrgaoVinculado: 52000, nomeOrgaoVinculado: 'MINISTERIO DEFESA' }] : []))
  if (u.pathname.endsWith('1_consultarUasg')) return resp(env_(p.codigoUasg ? uasgs.filter((x) => x.codigoUasg === p.codigoUasg) : p.siglaUf ? uasgs.filter((x) => x.siglaUf === p.siglaUf) : uasgs))
  if (u.pathname.endsWith('1.2_consultarARP_FimVigencia')) {
    if ((Date.parse(p.dataVigenciaFinalMax) - Date.parse(p.dataVigenciaFinalMin)) / 864e5 > 365) return resp({ title: 'Período maior que 365 dias' }, 400)
    const todas = [...atasBec, ...atasValid].filter((a) => a.codigoUnidadeGerenciadora === p.codigoUnidadeGerenciadora
      && a.dataVigenciaFinal.slice(0, 10) >= p.dataVigenciaFinalMin && a.dataVigenciaFinal.slice(0, 10) <= p.dataVigenciaFinalMax)
    return resp(env_(todas))
  }
  const v = valid[p.numeroControlePncpAta] ?? (p.numeroAta ? Object.values(valid).find((x: any) => x.ata.resultado[0].numeroAtaRegistroPreco === p.numeroAta && x.ata.resultado[0].codigoUnidadeGerenciadora === p.unidadeGerenciadora) : undefined)
  if (u.pathname.endsWith('1.1_consultarARP_Id')) return resp(v ? v.ata : env_([]))
  if (u.pathname.endsWith('2.1_consultarARPItem_Id')) return resp(v ? v.itens : env_(itensBec.filter((i: any) => i.numeroControlePncpAta === p.numeroControlePncpAta)))
  if (u.pathname.endsWith('3_consultarUnidadesItem')) return resp(env_(v ? v.unid.filter((x: any) => x.numeroItem === p.numeroItem) : []))
  if (u.pathname.endsWith('5_consultarAdesoesItem')) return resp(env_(v ? v.ades.filter((x: any) => x._item === p.numeroItem).map(({ _item, ...r }: any) => r) : []))
  if (u.pathname.endsWith('4_consultarEmpenhosSaldoItem')) return resp(env_([]))
  if (u.pathname.endsWith('/v1/contratos/atualizacao')) return resp({ data: contratos, totalRegistros: contratos.length, totalPaginas: 1, numeroPagina: 1 })
  if (u.pathname.endsWith('/v1/atas/atualizacao')) return new Response(null, { status: 204 })
  return resp({ erro: 'rota não simulada ' + u.pathname }, 404)
}) as typeof fetch

let falhas = 0
const ok = (c: boolean, m: string) => { console.log(`${c ? '✔' : '✘'} ${m}`); if (!c) falhas++ }
const ciclo = async () => {
  let fatias = 0, r
  do {
    subreqFatia = 0
    r = await processarFila(env, { f: fakeFetch, intervaloMs: 0, prazoMs: 1e9, sleep: async () => {} })
    maxSubreqVisto = Math.max(maxSubreqVisto, subreqFatia)
    if (r.subrequisicoes !== subreqFatia) throw new Error(`contagem de subrequisições divergente: ${r.subrequisicoes} x ${subreqFatia}`)
    fatias++
    // fila "dormindo" (tarefas devolvidas após 429 ou com espera): simula a passagem do tempo até o próximo cron
    if (r.reservadas === 0 && sql("select count(*) from radar.fila_coleta where status in ('PENDENTE','ERRO') and tentativas < 6") !== '0') {
      sql("update radar.fila_coleta set proxima_em = now() where status in ('PENDENTE','ERRO') and tentativas < 6"); r = { ...r, reservadas: 1 }
    }
  } while ((r.reservadas > 0 || r.devolvidas > 0) && fatias < 2000)
  return fatias
}

const t0 = Date.now()
await rpc(env, 'iniciar_ciclo', { p_tipo: 'MANUAL' }, fakeFetch)
const fatias1 = await ciclo()
const S = (q: string) => sql(`set search_path=radar; ${q}`).split('\n').pop()!

ok(maxSubreqVisto <= 48, `nenhuma execução passou de 48 subrequisições (máximo observado: ${maxSubreqVisto}; ${fatias1} execuções)`)
ok(S("select nome||'/'||forca from orgaos_publicos where codigo_orgao=52121") === 'COMANDO DO EXERCITO/EXERCITO', 'órgão 52121 vindo do cadastro oficial')
ok(S('select count(*) from uasgs where pertence_exercito') === '509', '509 UASGs do Exército (consultadas por UF)')
ok(chamadasGov.filter((c) => c.endsWith('1_consultarUasg')).length >= 27, 'cadastro consultado em 27 chamadas pequenas (uma por UF)')
ok(+S("select count(*) from organizacoes_militares where metodo_vinculo_rm='INFERIDO_POLO_CGCFEX'") === 470, 'RM inferida pelo CGCFEx em 470 OM (igual à carga anterior)')
const vig8 = S("select count(*) from atas_registro_precos where codigo_uasg_gerenciadora='160171'")
ok(+vig8 >= 230, `atas do 8º BEC com vigência a partir de ontem carregadas: ${vig8}`)
ok(S("select count(*) from atas_registro_precos where numero_ata='00032/2025' and codigo_uasg_gerenciadora='160047'") === '1', 'ata 00032/2025 (Cmdo 10ª RM) carregada pela varredura da UASG')
ok(S("select count(*) from atas_registro_precos where numero_controle_pncp_ata='00394452000103-1-012882/2025-000001'") === '1', 'ata do 1º CGEO (já vencida) trazida como ATA_EXTERNA a partir do contrato PNCP fruto de adesão')
ok(S('select count(*) from adesoes') === '11', `11 adesões (obtido ${S('select count(*) from adesoes')})`)
ok(S("select count(*) from v_saldos_itens where status_saldo_adesoes='CONFERE_COM_A_FONTE'") === '3', 'saldo calculado confere com a fonte nos 3 itens com adesão')
ok(S("select coalesce(pertence_exercito,false)::text from uasgs where codigo_uasg='767200'") === 'false', 'Casa do Marinheiro (767200) registrada fora do Exército')
ok(S("select count(*) from contratos where fruto_adesao") === '3', '3 contratos PNCP fruto de adesão')
ok(S("select status from sincronizacoes order by id desc limit 1") === 'SUCESSO', `ciclo encerrado como SUCESSO (${S('select reg_novos from sincronizacoes order by id desc limit 1')} registros, ${S('select respostas_429 from sincronizacoes order by id desc limit 1')} resposta 429)`)
ok(S("select count(*) from fila_coleta where status<>'OK'") === '0', `fila zerada (${S('select count(*) from fila_coleta')} tarefas)`)
ok(+S('select count(*) from payloads') > 0 && S("select count(*) from payloads where hash_sha256 !~ '^[0-9a-f]{64}$'") === '0', `${S('select count(*) from payloads')} respostas registradas com hash SHA-256`)

// segundo ciclo: nada mudou na fonte → não reconsulta itens nem adesões, sem duplicar
const ades1 = chamadasGov.filter((c) => c.endsWith('5_consultarAdesoesItem')).length
const itens1 = chamadasGov.filter((c) => c.endsWith('2.1_consultarARPItem_Id')).length
await rpc(env, 'iniciar_ciclo', { p_tipo: 'DIARIA' }, fakeFetch)
await ciclo()
ok(chamadasGov.filter((c) => c.endsWith('5_consultarAdesoesItem')).length === ades1, 'incremental: saldo inalterado ⇒ nenhuma nova consulta de adesões')
ok(chamadasGov.filter((c) => c.endsWith('2.1_consultarARPItem_Id')).length === itens1, 'incremental: atas sem alteração na fonte ⇒ itens não são recoletados')
ok(S('select count(*) from adesoes') === '11', 'sem duplicidade após o 2º ciclo')
console.log(`(${((Date.now() - t0) / 1000).toFixed(0)} s, ${chamadasGov.length} chamadas simuladas às APIs)`)
console.log(falhas ? `\n${falhas} FALHA(S)` : '\nTODOS OS TESTES PASSARAM'); process.exit(falhas ? 1 : 0)
