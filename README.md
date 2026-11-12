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
supabase/INSTALACAO_COMPLETA_SUPABASE.sql  as 8 migrações num arquivo só, para o SQL Editor
wrangler.jsonc              Worker "radar-om": interface (public/) + /api/* + Cron Triggers
public/index.html           interface (13 módulos); sem backend abre em modo demonstração
public/demo-snapshot.json   coleta real de 12/11/2026 usada no modo demonstração
collector/                  código do Worker em TypeScript, sem dependências de runtime
  src/http.ts               limitação de taxa, Retry-After, retentativas, janelas de 365 dias, SHA-256
  src/fontes.ts             endpoints verificados em 12/11/2026
  src/mapeamento.ts         resposta da API → linhas do banco (nada inventado)
  src/armazenamento.ts      PostgREST/Supabase via fetch
  src/sincronizacao.ts      orquestração do ciclo diário (fila retomável, incremental)
  src/worker.ts             serve a interface, /api/config, /api/snapshot (login), /api/sincronizar-agora (ADMINISTRADOR), cron
  test/sincronizacao.test.ts  teste ponta a ponta do coletor com respostas reais gravadas
  test/api.test.ts          teste da API contra PostgreSQL (perfis, paginação, chave secreta não exposta)
data/raw/                   primeiro conjunto real coletado (12/11/2026)
scripts/carga_amostra.py    carga da amostra real no PostgreSQL
scripts/stub_auth.sql       auth.uid() para testar RLS fora do Supabase
```

## Implantar (Cloudflare + Supabase)

1. **Cloudflare:** Workers & Pages → Create → *Import a repository* → `RADAR-OM`. Build command vazio; deploy command `npx wrangler deploy`. O primeiro deploy já publica a interface em **modo demonstração**.
2. **Supabase:** com a integração GitHub ativa, as migrações de `supabase/migrations/` são aplicadas automaticamente. Sem a integração, cole `supabase/INSTALACAO_COMPLETA_SUPABASE.sql` no SQL Editor. Depois confira em *Settings → API → Exposed schemas* que `radar` aparece (a migração 008 o inclui).
3. **Variáveis do Worker** (Cloudflare → radar-om → Settings → Variables and Secrets):
   - `SUPABASE_URL` e `SUPABASE_ANON_KEY` (texto)
   - `SUPABASE_SERVICE_ROLE_KEY` (**Secret**)
4. **Primeiro usuário:** crie em Supabase → Authentication → Users e depois:
   `insert into radar.perfis(usuario_id,nome,email,perfil) values ('<uuid>','Nome','email','ADMINISTRADOR');`
5. **Carga inicial:** entre como ADMINISTRADOR e clique em *Atualizar dados agora*; o cron continua a fila a cada 10 minutos (02h–08h50 BRT). A carga nacional completa leva de 2 a 4 dias por causa do limite de ~100 req/min da API.

## Rodar localmente

```bash
npm install
npm run test        # coletor + API (a API usa um PostgreSQL local com supabase/migrations e scripts/carga_amostra.py)
npm run dev         # wrangler dev; crie .dev.vars a partir de .dev.vars.example para usar o Supabase
```

## Regras de confiabilidade aplicadas no código

- Exército = UASG do órgão SIASG 52121 (coluna gerada `pertence_exercito`), nunca pelo nome.
- Adesão em `adesoes` é sempre estágio AUTORIZADA; "contratada" só com contrato PNCP `frutoAdesao` da mesma OM e ata.
- Empenho só entra no saldo com `vinculo_item_confirmado`.
- Saldos são views calculadas, comparadas ao saldo informado pela fonte, com o aviso "Saldo estimado — sujeito à confirmação pelo órgão gerenciador."
- Toda linha tem fonte, payload (hash SHA-256) e data de coleta.
