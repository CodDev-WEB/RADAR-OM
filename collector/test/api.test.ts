// Teste da API do Worker contra o PostgreSQL local (simulando o PostgREST/Auth do Supabase).
import { execFileSync } from 'node:child_process'
import worker, { tratarApi } from '../src/worker.js'

const psql = (sql: string) => execFileSync('su', ['postgres', '-c', `psql -h /tmp -d radar_om -At -c "${sql.replace(/"/g, '\\"')}"`]).toString().trim()
const USERS: Record<string, string> = { 'tok-admin': '22222222-2222-2222-2222-222222222222', 'tok-consulta': '11111111-1111-1111-1111-111111111111' }
let leituras = 0, authComChaveNova = 0
const fakeSupabase = (async (input: any, init: any = {}) => {
  const u = new URL(String(input)); const h = new Headers(init.headers)
  if (u.pathname === '/auth/v1/user') {
    const id = USERS[(h.get('authorization') || '').replace('Bearer ', '')]
    return id ? Response.json({ id }) : new Response('{}', { status: 401 })
  }
  if (h.get('apikey') !== env.SUPABASE_SERVICE_ROLE_KEY) return new Response('{}', { status: 401 })
  if (h.get('authorization')) { authComChaveNova++; return new Response('{"message":"Invalid JWT"}', { status: 401 }) }
  const view = u.pathname.replace('/rest/v1/', '')
  if (view === 'perfis') {
    const id = u.searchParams.get('usuario_id')!.replace('eq.', '')
    return new Response(psql(`select coalesce(json_agg(json_build_object('perfil',perfil)),'[]') from radar.perfis where ativo and usuario_id='${id}'`))
  }
  leituras++
  const [a, b] = (h.get('range') || '0-999').split('-').map(Number)
  return new Response(psql(`select coalesce(json_agg(t),'[]') from (select * from radar.${view} offset ${a} limit ${b - a + 1}) t`))
}) as typeof fetch

const env: any = { SUPABASE_URL: 'https://x.supabase.co', SUPABASE_ANON_KEY: 'anon', SUPABASE_SERVICE_ROLE_KEY: 'sb_secret_teste123',
  ASSETS: { fetch: async () => new Response('<html>RADAR OM</html>') } }
let falhas = 0
const ok = (c: boolean, m: string) => { console.log(`${c ? '✔' : '✘'} ${m}`); if (!c) falhas++ }
const req = (p: string, tok?: string, method = 'GET') => new Request('https://radar-om.workers.dev' + p, { method, headers: tok ? { authorization: 'Bearer ' + tok } : {} })

const cfgDemo = await (await tratarApi(req('/api/config'), { ASSETS: env.ASSETS } as any)).json()
ok(cfgDemo.modo === 'demonstracao', 'sem variáveis → modo demonstração')
const cfg = await (await tratarApi(req('/api/config'), env, fakeSupabase)).json()
ok(cfg.modo === 'producao' && cfg.supabaseAnonKey === 'anon' && !JSON.stringify(cfg).includes('sb_secret_teste123'), '/api/config não expõe a chave service_role')
ok((await tratarApi(req('/api/snapshot'), env, fakeSupabase)).status === 401, 'snapshot sem login → 401')
ok((await tratarApi(req('/api/snapshot', 'tok-invalido'), env, fakeSupabase)).status === 401, 'token inválido → 401')
const r = await tratarApi(req('/api/snapshot', 'tok-consulta'), env, fakeSupabase)
const S: any = await r.json()
ok(r.status === 200 && S.perfil === 'CONSULTA', 'perfil CONSULTA lê o snapshot')
ok(S.oms.length === 509 && S.atas.length === 602 && S.itens.length === 2795 && S.adesoes.length === 11, `contagens: ${S.oms.length} OM, ${S.atas.length} atas, ${S.itens.length} itens (paginado), ${S.adesoes.length} adesões`)
ok(leituras >= 13, `paginação de 1000 em 1000 (${leituras} leituras)`)
ok(S.fornecedores['10285037000167'] === 'IVM TELECOMUNICACOES LTDA', 'mapa de fornecedores montado')
ok(typeof S.dash.om_monitoradas === 'number' && S.dash.om_monitoradas === 509, 'indicadores do dashboard')
ok((await tratarApi(req('/api/sincronizar-agora', 'tok-consulta', 'POST'), env, fakeSupabase)).status === 403, 'CONSULTA não pode sincronizar → 403')
ok(authComChaveNova === 0, 'chave sb_secret_ enviada só em apikey (nunca em Authorization)')
const { cabecalhosChave } = await import('../src/armazenamento.js')
ok(!!cabecalhosChave('eyJhbGciOi.x.y').authorization && !cabecalhosChave('sb_secret_x').authorization, 'chave legada (JWT) mantém Authorization; chave nova não')
const html = await (await worker.fetch(req('/'), env)).text()
ok(html.includes('RADAR OM'), 'rotas fora de /api servem a interface')
console.log(falhas ? `\n${falhas} FALHA(S)` : '\nTODOS OS TESTES PASSARAM'); process.exit(falhas ? 1 : 0)
