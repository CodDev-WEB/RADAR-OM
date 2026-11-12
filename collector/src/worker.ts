// RADAR OM — Cloudflare Worker (compatível com o plano GRATUITO: 50 subrequisições e 10 ms de CPU por execução)
//
//   • serve a interface (public/)
//   • /api/config            → configuração pública (modo, URL e chave publishable do Supabase)
//   • /api/sincronizar-agora → ADMINISTRADOR inicia um ciclo de coleta
//   • cron a cada minuto     → processa uma fatia da fila de coleta
//
// O Worker é uma ponte: busca a página na API oficial e entrega o TEXTO BRUTO a radar.ingerir() no Postgres,
// que interpreta, grava e enfileira os próximos passos. Cada tarefa custa 2 subrequisições e quase nada de CPU.
// A interface lê os dados direto do Supabase com o login do usuário (RLS), sem passar pelo Worker.

interface Fetcher { fetch(req: Request): Promise<Response> }
export interface Env {
  ASSETS: Fetcher
  SUPABASE_URL?: string
  SUPABASE_ANON_KEY?: string           // chave publishable (sb_publishable_…) — pública, só login
  SUPABASE_PUBLISHABLE_KEY?: string    // nome alternativo
  SUPABASE_SERVICE_ROLE_KEY?: string   // SECRET: chave secret (sb_secret_…) — nunca sai do Worker
  SUPABASE_SECRET_KEY?: string         // nome alternativo
  COLETA_MAX_SUBREQ?: string           // padrão 48 (plano gratuito: 50)
}
type F = typeof fetch
// fetch nunca é guardado como propriedade: no Workers isso gera "Illegal invocation"
const fetchPadrao: F = (input, init) => fetch(input, init)

/** chaves novas (sb_…) não são JWT: vão só em `apikey`; chaves legadas (JWT) também em Authorization */
export function cabecalhosChave(chave: string): Record<string, string> {
  return chave.startsWith('eyJ') ? { apikey: chave, authorization: `Bearer ${chave}` } : { apikey: chave }
}

export function normalizar(env: Env): Env {
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

/** chama uma função do schema radar com a chave de serviço; `corpo` pode ser texto JSON já montado */
export async function rpc<T = unknown>(env: Env, fn: string, corpo: string | object, f: F = fetchPadrao): Promise<T> {
  const r = await f(`${env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: { ...cabecalhosChave(env.SUPABASE_SERVICE_ROLE_KEY!), 'content-type': 'application/json', 'content-profile': 'radar', 'accept-profile': 'radar' },
    body: typeof corpo === 'string' ? corpo : JSON.stringify(corpo),
  })
  const txt = await r.text()
  if (!r.ok) throw new Error(`radar.${fn}: HTTP ${r.status} — ${txt.slice(0, 300)}`)
  return (txt ? JSON.parse(txt) : null) as T
}

const BASE: Record<number, string> = { 1: 'https://dadosabertos.compras.gov.br', 2: 'https://pncp.gov.br/api/consulta' }
interface Tarefa { id: number; tarefa: string; fonte_id: number; endpoint: string; params: Record<string, unknown> }

export interface OpcoesFila { maxSubreq?: number; prazoMs?: number; intervaloMs?: number; timeoutMs?: number; f?: F; sleep?: (ms: number) => Promise<void>; agora?: () => number }

/** processa uma fatia da fila dentro do orçamento de subrequisições e de tempo */
export async function processarFila(env: Env, o: OpcoesFila = {}) {
  const f = o.f ?? fetchPadrao, agora = o.agora ?? Date.now
  const sleep = o.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)))
  const maxSubreq = o.maxSubreq ?? (Number(env.COLETA_MAX_SUBREQ) || 48)
  // cron pode durar até 15 min de tempo real; esperar fetch não conta CPU. Para de iniciar tarefas após ~55 s
  const prazoMs = o.prazoMs ?? 55_000, intervaloMs = o.intervaloMs ?? 650, timeoutMs = o.timeoutMs ?? 90_000
  const inicio = agora()
  let sub = 0
  // 1 (reserva) + 2 por tarefa + 1 (devolução eventual)
  const tarefas = await rpc<Tarefa[]>(env, 'reservar_tarefas', { p_limite: Math.max(1, Math.floor((maxSubreq - 2) / 2)) }, f); sub++
  const res = { reservadas: tarefas.length, processadas: 0, limiteTaxa: 0, erros: 0, devolvidas: 0, subrequisicoes: 0 }
  let i = 0
  for (; i < tarefas.length; i++) {
    if (agora() - inicio > prazoMs) break
    const t = tarefas[i]
    if (i > 0) await sleep(intervaloMs)
    const qs = new URLSearchParams(Object.entries(t.params).map(([k, v]) => [k, String(v)]))
    let status = 0, texto = ''
    try {
      const ctl = new AbortController(); const tm = setTimeout(() => ctl.abort(), timeoutMs)
      const r = await f(`${BASE[t.fonte_id]}${t.endpoint}?${qs}`, { headers: { accept: 'application/json' }, signal: ctl.signal })
      clearTimeout(tm); status = r.status; texto = await r.text()
    } catch (e) { status = 0; texto = `falha de rede: ${String(e)}` }
    sub++
    // texto bruto vai direto ao banco (sem JSON.parse aqui → CPU mínima)
    const limpo = texto.trim(), ehJson = limpo.startsWith('{') || limpo.startsWith('[')
    const ok = status >= 200 && status < 300
    const http = ok && limpo && !ehJson ? 502 : status
    const resposta = ok && ehJson ? limpo : ok && !limpo ? 'null' : JSON.stringify(texto.slice(0, 1000))
    await rpc(env, 'ingerir', `{"p_id":${t.id},"p_http":${http},"p_resposta":${resposta}}`, f); sub++
    res.processadas++
    if (!ok && status !== 429) res.erros++
    if (status === 429) { res.limiteTaxa++; i++; break }   // a API pediu pausa: devolve o resto
  }
  const resto = tarefas.slice(i).map((t) => t.id)
  if (resto.length) { await rpc(env, 'devolver_tarefas', { p_ids: resto, p_segundos: res.limiteTaxa ? 20 : 0 }, f); sub++ }
  res.devolvidas = resto.length; res.subrequisicoes = sub
  return res
}

/** valida o JWT do Supabase Auth e devolve o perfil ativo (ou null) */
export async function perfilDoUsuario(env: Env, req: Request, f: F = fetchPadrao): Promise<string | null> {
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

const json = (b: unknown, status = 200) => new Response(JSON.stringify(b), {
  status, headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store' },
})

export async function tratarApi(req: Request, envBruto: Env, ctx?: { waitUntil(p: Promise<unknown>): void }, f: F = fetchPadrao): Promise<Response> {
  const env = normalizar(envBruto)
  const url = new URL(req.url)
  if (url.pathname === '/api/config') {
    // só NOMES das variáveis ausentes — nunca valores; a chave publishable é pública por desenho
    return json(configurado(env) ? { modo: 'producao', supabaseUrl: env.SUPABASE_URL, supabaseAnonKey: env.SUPABASE_ANON_KEY } : { modo: 'demonstracao', faltando: faltando(env) })
  }
  if (!configurado(env)) return json({ erro: `Backend não configurado. Falta: ${faltando(env).join(', ')}.` }, 503)

  if (req.method === 'POST' && url.pathname === '/api/sincronizar-agora') {
    const perfil = await perfilDoUsuario(env, req, f)                       // 2 subrequisições
    if (!perfil) return json({ erro: 'Faça login com um usuário ativo no RADAR OM.' }, 401)
    if (perfil !== 'ADMINISTRADOR') return json({ erro: 'Apenas o perfil ADMINISTRADOR pode iniciar a sincronização.' }, 403)
    try {
      const id = await rpc<number>(env, 'iniciar_ciclo', { p_tipo: 'MANUAL' }, f)  // 1 subrequisição
      // o processamento fica com o cron (a cada minuto): uma requisição HTTP só tem 30 s de waitUntil
      // e encerrá-la no meio deixava tarefas presas
      return json({ iniciado: true, sincronizacao: id, aviso: 'Coleta iniciada. O processamento começa em até 1 minuto e continua automaticamente.' })
    } catch (e) {
      return json({ erro: `Falha ao iniciar a sincronização: ${String(e).replace(/^Error:\s*/, '').slice(0, 500)}` }, 500)
    }
  }
  return json({ erro: 'rota não encontrada' }, 404)
}

export default {
  async fetch(req: Request, env: Env, ctx: { waitUntil(p: Promise<unknown>): void }): Promise<Response> {
    const url = new URL(req.url)
    if (url.pathname.startsWith('/api/')) {
      try { return await tratarApi(req, env, ctx) }
      catch (e) { console.log(JSON.stringify({ nivel: 'ERRO', msg: String(e) })); return json({ erro: 'Erro interno no Worker.' }, 500) }
    }
    return env.ASSETS.fetch(req)
  },

  // cron "* * * * *": às 05:00 UTC (02:00 BRT) abre o ciclo diário; em todos os minutos processa uma fatia
  async scheduled(evento: { scheduledTime: number }, envBruto: Env, _ctx: { waitUntil(p: Promise<unknown>): void }) {
    const env = normalizar(envBruto)
    if (!configurado(env)) return
    // o runtime aguarda a promessa do scheduled() por até 15 min de tempo real
    try {
      const d = new Date(evento.scheduledTime)
      let orcamento = Number(env.COLETA_MAX_SUBREQ) || 48
      if (d.getUTCHours() === 5 && d.getUTCMinutes() === 0) { await rpc(env, 'iniciar_ciclo', { p_tipo: 'DIARIA' }); orcamento -= 1 }
      const r = await processarFila(env, { maxSubreq: orcamento })
      if (r.reservadas) console.log(JSON.stringify({ nivel: 'INFO', msg: 'fatia processada', ...r }))
    } catch (e) { console.log(JSON.stringify({ nivel: 'ERRO', msg: String(e) })) }
  },
}
