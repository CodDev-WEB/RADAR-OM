// Regressão: no Cloudflare Workers, chamar fetch com `this` diferente de globalThis lança "Illegal invocation".
import { ClienteApi } from '../src/http.js'
import { SupabaseRest } from '../src/armazenamento.js'
const original = globalThis.fetch
globalThis.fetch = function (this: unknown, ..._a: unknown[]) {
  if (this !== undefined && this !== globalThis) throw new TypeError('Illegal invocation: function called with incorrect `this` reference.')
  return Promise.resolve(new Response('[{"id":1}]', { status: 200 }))
} as typeof fetch
let falhas = 0
const ok = (c: boolean, m: string) => { console.log(`${c ? '✔' : '✘'} ${m}`); if (!c) falhas++ }
try { await new SupabaseRest('https://x', 'sb_secret_x').select('t', 'select=*'); ok(true, 'SupabaseRest chama fetch sem Illegal invocation') }
catch (e) { ok(false, 'SupabaseRest: ' + e) }
try { await new ClienteApi({ baseUrl: 'https://x', intervaloMinMs: 0 }).getJson('/a', {}); ok(true, 'ClienteApi chama fetch sem Illegal invocation') }
catch (e) { ok(false, 'ClienteApi: ' + e) }
globalThis.fetch = original
console.log(falhas ? `\n${falhas} FALHA(S)` : '\nTODOS OS TESTES PASSARAM'); process.exit(falhas ? 1 : 0)
