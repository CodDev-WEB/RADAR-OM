# RADAR OM

Monitoramento de pregões, atas de registro de preços e adesões (caronas) das Organizações Militares do Exército Brasileiro, alimentado somente por APIs oficiais (Compras.gov.br — Dados Abertos e PNCP).

## Estrutura

```
supabase/migrations/  (aplicadas em ordem pela integração Supabase ↔ GitHub)
  202611120001_schema.sql         tabelas, índices, triggers de histórico (schema "radar")
  202611120002_views.sql         situação das atas, saldos com memória de cálculo, adesões, rankings, oportunidades, dashboard
  202611120003_seed_referencia.sql   RM, CMA, 41 categorias de despesa, regras de classificação
  202611120004_fila_coleta.sql       fila persistente do coletor + RPCs reservar_tarefas / liberar_tarefas_presas
  202611120005_seguranca.sql         RLS por perfil (ADMINISTRADOR, GESTOR, CONSULTA), auditoria
  202611120006_classificacao.sql     classificar_itens() e v_itens_classificados
  202611120007_api_views.sql         views api_* lidas pelo Worker
  202611120008_supabase_permissoes.sql  grants do schema radar e exposição na API REST
  202611120009_ingestao_sql.sql      radar.ingerir(): interpreta e grava as respostas das APIs (coleta no plano gratuito)
  202611120010_coleta_ajustes.sql    UASGs por UF, recuperação de tarefas presas, nova tentativa rápida após falha de rede
supabase/INSTALACAO_COMPLETA_SUPABASE.sql  as 10 migrações num arquivo só, para banco VAZIO
supabase/REPARO_VIEWS_E_PERMISSOES.sql     recria views e permissões (pode rodar várias vezes; não apaga dados)
wrangler.jsonc              Worker "radar-om": interface (public/) + /api/* + Cron Triggers
public/index.html           interface (13 módulos); sem backend abre em modo demonstração
public/demo-snapshot.json   coleta real de 12/11/2026 usada no modo demonstração
collector/                  Worker em TypeScript, sem dependências de runtime (ponte API oficial → radar.ingerir)
  src/worker.ts             interface, /api/config, /api/sincronizar-agora (ADMINISTRADOR) e cron a cada minuto
  test/coleta.test.ts       ciclo completo com respostas reais gravadas + PostgreSQL (≤ 48 subrequisições por execução)
  test/api.test.ts          rotas HTTP, perfis e chaves
data/raw/                   primeiro conjunto real coletado (12/11/2026)
scripts/carga_amostra.py    carga da amostra real no PostgreSQL
scripts/stub_auth.sql       auth.uid() para testar RLS fora do Supabase
```

## Implantar (Cloudflare + Supabase)

1. **Cloudflare:** Workers & Pages → Create → *Import a repository* → `RADAR-OM`. Build command vazio; deploy command `npx wrangler deploy`. O primeiro deploy já publica a interface em **modo demonstração**.
2. **Supabase:** com a integração GitHub ativa, as migrações de `supabase/migrations/` são aplicadas automaticamente. Sem a integração, cole `supabase/INSTALACAO_COMPLETA_SUPABASE.sql` no SQL Editor. Depois confira em *Settings → API → Exposed schemas* que `radar` aparece (a migração 008 o inclui).
3. **Variáveis do Worker** (Cloudflare → radar-om → Settings → Variables and Secrets):
   - `SUPABASE_URL` e `SUPABASE_ANON_KEY` (chave publishable) — já definidas em `wrangler.jsonc`
   - `SUPABASE_SERVICE_ROLE_KEY` (**Secret**) — a chave secret do Supabase (`sb_secret_…`), em *Project Settings → API Keys*
4. **Primeiro usuário:** crie em Supabase → Authentication → Users e depois:
   `insert into radar.perfis(usuario_id,nome,email,perfil) values ('<uuid>','Nome','email','ADMINISTRADOR');`
5. **Carga inicial:** entre como ADMINISTRADOR e clique em *Atualizar dados agora*; o cron continua a fila a cada minuto. A carga nacional completa leva de 2 a 4 dias por causa do limite de ~100 req/min da API.

## Rodar localmente

```bash
npm install
npm run test        # API + ciclo completo de coleta (requer PostgreSQL local com supabase/migrations no banco RADAR_DB)
npm run dev         # wrangler dev; crie .dev.vars a partir de .dev.vars.example para usar o Supabase
```

## Como a coleta cabe no plano gratuito do Cloudflare

O plano gratuito permite 50 subrequisições e 10 ms de CPU por execução. Por isso o Worker é só uma ponte:
cada tarefa da fila faz 1 consulta à API oficial e entrega o texto bruto a `radar.ingerir()` (1 RPC), que
interpreta, grava, detecta mudanças e enfileira os próximos passos no próprio Postgres. O cron roda a cada
minuto e processa até 23 tarefas. A interface lê os dados direto do Supabase com o login do usuário (RLS).

## Regras de confiabilidade aplicadas no código

- Exército = UASG do órgão SIASG 52121 (coluna gerada `pertence_exercito`), nunca pelo nome.
- Adesão em `adesoes` é sempre estágio AUTORIZADA; "contratada" só com contrato PNCP `frutoAdesao` da mesma OM e ata.
- Empenho só entra no saldo com `vinculo_item_confirmado`.
- Saldos são views calculadas, comparadas ao saldo informado pela fonte, com o aviso "Saldo estimado — sujeito à confirmação pelo órgão gerenciador."
- Toda linha tem fonte, payload (hash SHA-256) e data de coleta.
