// Testes das rotas HTTP do Worker (/api/config, /api/sincronizar-agora, interface) — sem rede.
import worker, { tratarApi, cabecalhosChave } from '../src/worker.js'

let falhas = 0
const ok = (c: boolean, m: string) => { console.log(`${c ? '✔' : '✘'} ${m}`); if (!c) falhas++ }
const ASSETS = { fetch: async () => new Response('<html>RADAR OM</html>') }
const env: any = { ASSETS, SUPABASE_URL: 'https://x.supabase.co', SUPABASE_ANON_KEY: 'sb_publishable_p', SUPABASE_SERVICE_ROLE_KEY: 'sb_secret_s' }
const USERS: Record<string, [string, string]> = { 'tok-admin': ['u1', 'ADMINISTRADOR'], 'tok-consulta': ['u2', 'CONSULTA'] }
const rpcs: string[] = []; let chaveNoAuthorization = 0
const fake = (async (input: any, init: any = {}) => {
  const u = new URL(String(input)), h = new Headers(init.headers)
  if (u.pathname === '/auth/v1/user') { const x = USERS[(h.get('authorization') || '').replace('Bearer ', '')]; return x ? Response.json({ id: x[0] }) : new Response('{}', { status: 401 }) }
  if (h.get('apikey') !== 'sb_secret_s') return new Response('{}', { status: 401 })
  if ((h.get('authorization') || '').includes('sb_')) { chaveNoAuthorization++; return new Response('{"message":"Invalid JWT"}', { status: 401 }) }
  if (u.pathname === '/rest/v1/perfis') { const id = u.searchParams.get('usuario_id')!.replace('eq.', ''); const p = Object.values(USERS).find((x) => x[0] === id); return Response.json(p ? [{ perfil: p[1] }] : []) }
  if (u.pathname.startsWith('/rest/v1/rpc/')) { const fn = u.pathname.split('/').pop()!; rpcs.push(fn); return new Response(fn === 'iniciar_ciclo' ? '7' : fn === 'reservar_tarefas' ? '[]' : 'null') }
  return new Response('{}', { status: 404 })
}) as typeof fetch
const req = (p: string, tok?: string, method = 'GET') => new Request('https://radar-om.workers.dev' + p, { method, headers: tok ? { authorization: 'Bearer ' + tok } : {} })
const esperas: Promise<unknown>[] = []; const ctx = { waitUntil: (p: Promise<unknown>) => { esperas.push(p) } }

const demo = await (await tratarApi(req('/api/config'), { ASSETS } as any)).json()
ok(demo.modo === 'demonstracao' && demo.faltando.length === 3, 'sem variáveis → modo demonstração, lista o que falta (só nomes)')
const alias = await (await tratarApi(req('/api/config'), { ASSETS, SUPABASE_URL: 'https://x.supabase.co/', SUPABASE_PUBLISHABLE_KEY: 'p', SUPABASE_SECRET_KEY: 'sb_secret_z' } as any)).json()
ok(alias.modo === 'producao' && alias.supabaseUrl === 'https://x.supabase.co', 'aceita nomes alternativos e remove barra final da URL')
const cfg = await (await tratarApi(req('/api/config'), env)).json()
ok(cfg.modo === 'producao' && !JSON.stringify(cfg).includes('sb_secret_s'), '/api/config não expõe a chave secret')
ok((await tratarApi(req('/api/sincronizar-agora', undefined, 'POST'), env, ctx, fake)).status === 401, 'sincronizar sem login → 401')
ok((await tratarApi(req('/api/sincronizar-agora', 'tok-consulta', 'POST'), env, ctx, fake)).status === 403, 'CONSULTA não pode sincronizar → 403')
const r = await tratarApi(req('/api/sincronizar-agora', 'tok-admin', 'POST'), env, ctx, fake); const b: any = await r.json()
await Promise.all(esperas)
ok(r.status === 200 && b.sincronizacao === 7 && rpcs.join() === 'iniciar_ciclo', 'ADMINISTRADOR abre o ciclo; o processamento fica com o cron (sem tarefas presas)')
ok(chaveNoAuthorization === 0, 'chave sb_secret_ enviada só em apikey (nunca em Authorization)')
ok(!!cabecalhosChave('eyJhbGciOi.x.y').authorization && !cabecalhosChave('sb_secret_x').authorization, 'chave legada (JWT) mantém Authorization; chave nova não')
ok((await tratarApi(req('/api/snapshot', 'tok-admin'), env, ctx, fake)).status === 404, 'leitura de dados não passa pelo Worker (vai direto ao Supabase com RLS)')
ok((await (await worker.fetch(req('/'), env, ctx)).text()).includes('RADAR OM'), 'rotas fora de /api servem a interface')
console.log(falhas ? `\n${falhas} FALHA(S)` : '\nTODOS OS TESTES PASSARAM'); process.exit(falhas ? 1 : 0)
