set search_path = radar, public;

-- Fila persistente: a API do Compras limita ~100 req/min (HTTP 429, Retry-After: 10).
-- O coletor processa fatias da fila a cada disparo do cron, retomando de onde parou.
create table fila_coleta (
  id            bigserial primary key,
  tarefa        text not null check (tarefa in (
                  'ATAS_UASG',          -- 1.2_consultarARP_FimVigencia por UASG do Exército
                  'ITENS_ATA',          -- 2.1_consultarARPItem_Id por ata
                  'UNIDADES_ITEM',      -- 3_consultarUnidadesItem por item
                  'ADESOES_ITEM',       -- 5_consultarAdesoesItem por item (só se aceita adesão)
                  'EMPENHOS_ATA',       -- 4_consultarEmpenhosSaldoItem por ata
                  'ATA_EXTERNA',        -- 1.1_consultarARP_Id de ata de outro órgão citada em contrato
                  'PNCP_ATAS_ATUALIZACAO','PNCP_CONTRATOS_ATUALIZACAO')),
  chave         jsonb not null,
  prioridade    smallint not null default 50,      -- menor = antes
  status        text not null default 'PENDENTE' check (status in ('PENDENTE','EXECUTANDO','OK','ERRO')),
  tentativas    smallint not null default 0,
  proxima_em    timestamptz not null default now(),
  ultimo_erro   text,
  sincronizacao_id bigint references sincronizacoes(id),
  criado_em     timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  unique (tarefa, chave)
);
create index on fila_coleta (status, prioridade, proxima_em);

-- RPC usada pelo coletor para pegar uma fatia com trava (evita dupla execução)
create or replace function reservar_tarefas(p_limite int, p_sync bigint)
returns setof fila_coleta language sql as $$
  update fila_coleta f set status='EXECUTANDO', tentativas=f.tentativas+1, atualizado_em=now(), sincronizacao_id=p_sync
  where f.id in (
    select id from fila_coleta
    where status in ('PENDENTE','ERRO') and proxima_em <= now() and tentativas < 6
    order by prioridade, proxima_em
    limit p_limite for update skip locked)
  returning f.*;
$$;

-- tarefas presas (worker interrompido) voltam para a fila
create or replace function liberar_tarefas_presas() returns int language sql as $$
  with u as (update fila_coleta set status='PENDENTE'
             where status='EXECUTANDO' and atualizado_em < now() - interval '30 minutes' returning 1)
  select count(*)::int from u;
$$;
