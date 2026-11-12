// RADAR OM — Cloudflare Worker único:
//   • serve a interface (static assets em ./public)
//   • /api/*  (configuração pública, dados autenticados, sincronização manual)
//   • Cron Triggers: ciclo diário 02h00 BRT + fatias a cada 10 min
import { ClienteApi } from './http.js'
import { SupabaseRest, cabecalhosChave } from './armazenamento.js'
import { Sincronizador, type Contexto } from './sincronizacao.js'

interface Fetcher { fetch(req: Request): Promise<Response> }
export interface Env {
  ASSETS: Fetcher
  SUPABASE_URL?: string               // var
  SUPABASE_ANON_KEY?: string          // var: chave publishable (sb_publishable_…) ou anon legada — pública, só login
  SUPABASE_SERVICE_ROLE_KEY?: string  // SECRET: chave secret (sb_secret_…) ou service_role legada — nunca sai do Worker
  SUPABASE_SECRET_KEY?: string        // nome alternativo aceito para a chave secret
  SUPABASE_PUBLISHABLE_KEY?: string   // nome alternativo aceito para a chave publishable
}

/** normaliza nomes alternativos de variáveis (o painel do Supabase usa "publishable" e "secret") */
function normalizar(env: Env): Env {
  return { ...env,
    SUPABASE_URL: env.SUPABASE_URL?.trim().replace(/\/+$/, ''),
    SUPABASE_ANON_KEY: (env.SUPABASE_ANON_KEY || env.SUPABASE_PUBLISHABLE_KEY)?.trim(),
    SUPABASE_SERVICE_ROLE_KEY: (env.SUPABASE_SERVICE_ROLE_KEY || env.SUPABASE_SECRET_KEY)?.trim() }
}
const faltando = (env: Env) => [
  !env.SUPABASE_URL && 'SUPABASE_URL',
  !env.SUPABASE_ANON_KEY && 'SUPABASE_ANON_KEY (chave publishable)',
  !env.SUPABASE_SERVICE_ROLE_KEY && 'SUPABASE_SERVICE_ROLE_KEY (chave secret, tipo Secret)',
].filter(Boolean) as string[]
const configurado = (env: Env) => faltando(env).length === 0

function contexto(env: Env): Contexto {
  const db = new SupabaseRest(env.SUPABASE_URL!, env.SUPABASE_SERVICE_ROLE_KEY!)
  const log: Contexto['log'] = (nivel, msg, extra) => console.log(JSON.stringify({ nivel, msg, ...extra }))
  return {
    db, log,
    compras: new ClienteApi({ baseUrl: 'https://dadosabertos.compras.gov.br', intervaloMinMs: 650, log }),
    pncp: new ClienteApi({ baseUrl: 'https://pncp.gov.br/api/consulta', intervaloMinMs: 300, timeoutMs: 90_000, log }),
  }
}

/** valida o JWT do Supabase Auth e devolve o perfil ativo (ou null) */
export async function perfilDoUsuario(env: Env, req: Request, f: typeof fetch = fetch): Promise<string | null> {
  const jwt = req.headers.get('authorization')?.replace(/^Bearer\s+/i, '')
  if (!jwt) return null
  const u = await f(`${env.SUPABASE_URL}/auth/v1/user`, { headers: { apikey: env.SUPABASE_ANON_KEY!, authorization: `Bearer ${jwt}` } })
  if (!u.ok) return null
  const { id } = (await u.json()) as { id: string }
  const r = await f(`${env.SUPABASE_URL}/rest/v1/perfis?select=perfil&ativo=is.true&usuario_id=eq.${id}`, {
    headers: { ...cabecalhosChave(env.SUPABASE_SERVICE_ROLE_KEY!), 'accept-profile': 'radar' },
  })
  const p = r.ok ? ((await r.json()) as Array<{ perfil: string }>) : []
  return p[0]?.perfil ?? null
}

/** lê uma view inteira paginando (PostgREST limita linhas por resposta) */
async function lerTudo(env: Env, view: string, f: typeof fetch): Promise<unknown[]> {
  const out: unknown[] = []
  for (let ini = 0; ; ini += 1000) {
    const r = await f(`${env.SUPABASE_URL}/rest/v1/${view}?select=*`, {
      headers: { ...cabecalhosChave(env.SUPABASE_SERVICE_ROLE_KEY!),
                 'accept-profile': 'radar', range: `${ini}-${ini + 999}`, 'range-unit': 'items' },
    })
    if (!r.ok) throw new Error(`falha ao ler ${view}: HTTP ${r.status}`)
    const lote = (await r.json()) as unknown[]
    out.push(...lote)
    if (lote.length < 1000) return out
  }
}

/** monta o snapshot no formato que a interface consome */
export async function montarSnapshot(env: Env, f: typeof fetch = fetch) {
  const [oms, uasgsExt, atas, itens, forn, saldos, unidades, adesoes, contratos, sync, dash] = await Promise.all(
    ['api_oms', 'api_uasgs_ext', 'api_atas', 'api_itens', 'api_fornecedores', 'api_saldos', 'api_unidades', 'api_adesoes', 'api_contratos', 'api_sync', 'api_dashboard']
      .map((v) => lerTudo(env, v, f)))
  return {
    geradoEm: new Date().toISOString(), modo: 'producao',
    oms, uasgsExt, atas, itens, saldos, unidades, adesoes, contratos, sync, dash: dash[0] ?? {},
    fornecedores: Object.fromEntries((forn as Array<{ ni: string; razao_social: string }>).map((x) => [x.ni, x.razao_social])),
  }
}

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
})

export async function tratarApi(req: Request, envBruto: Env, f: typeof fetch = fetch): Promise<Response> {
  const env = normalizar(envBruto)
  const url = new URL(req.url)
  if (url.pathname === '/api/config') {
    // anon key do Supabase é pública por desenho (só permite login); service key nunca é exposta
    // só NOMES das variáveis ausentes — nunca valores
    return json(configurado(env) ? { modo: 'producao', supabaseUrl: env.SUPABASE_URL, supabaseAnonKey: env.SUPABASE_ANON_KEY } : { modo: 'demonstracao', faltando: faltando(env) })
  }
  if (!configurado(env)) return json({ erro: `Backend não configurado. Falta: ${faltando(env).join(', ')}.` }, 503)

  const perfil = await perfilDoUsuario(env, req, f)
  if (!perfil) return json({ erro: 'Faça login com um usuário ativo no RADAR OM.' }, 401)

  if (req.method === 'GET' && url.pathname === '/api/snapshot') return json({ ...(await montarSnapshot(env, f)), perfil })

  if (req.method === 'POST' && url.pathname === '/api/sincronizar-agora') {
    if (perfil !== 'ADMINISTRADOR') return json({ erro: 'Apenas o perfil ADMINISTRADOR pode iniciar a sincronização.' }, 403)
    const x = contexto(env)
    const s = await Sincronizador.iniciar(x, 'MANUAL')
    const r = await s.processarFatia(40)
    return json({ iniciado: true, restantes: r.restantes, aviso: 'As tarefas restantes serão processadas pelo cron a cada 10 minutos.' })
  }
  return json({ erro: 'rota não encontrada' }, 404)
}

async function syncAtual(x: Contexto): Promise<number | null> {
  const r = await x.db.select('sincronizacoes', 'select=id&status=eq.EM_ANDAMENTO&order=id.desc&limit=1')
  return r.length ? Number(r[0].id) : null
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url)
    if (url.pathname.startsWith('/api/')) {
      try { return await tratarApi(req, env) }
      catch (e) { console.log(JSON.stringify({ nivel: 'ERRO', msg: String(e) })); return json({ erro: 'Erro interno ao consultar o banco.' }, 500) }
    }
    return env.ASSETS.fetch(req)
  },

  async scheduled(evento: { cron: string }, envBruto: Env, ctx: { waitUntil(p: Promise<unknown>): void }) {
    const env = normalizar(envBruto)
    if (!configurado(env)) { console.log('cron ignorado: backend não configurado'); return }
    const x = contexto(env)
    ctx.waitUntil((async () => {
      const id = await syncAtual(x)
      // só o cron das 05:00 UTC abre ciclo; os de 10 em 10 min apenas continuam um ciclo aberto
      if (evento.cron === '0 5 * * *') {
        if (id !== null) await x.db.update('sincronizacoes', `id=eq.${id}`, { status: 'SUCESSO_PARCIAL', finalizada_em: new Date().toISOString(), observacoes: 'encerrada pelo início do ciclo seguinte' })
        await (await Sincronizador.iniciar(x, 'DIARIA')).processarFatia(120)
      } else if (id !== null) {
        await new Sincronizador(x, id).processarFatia(120)
      }
    })())
  },
}
