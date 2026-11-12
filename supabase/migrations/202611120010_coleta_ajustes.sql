-- RADAR OM — ajustes da coleta após o primeiro ciclo real (12/11/2026)
--  • cadastro de UASGs consultado por UF (a consulta única de 509 UASGs estourava o tempo a partir do Cloudflare)
--  • tarefas presas em EXECUTANDO são recuperadas pela própria reserva
--  • falha de rede/tempo esgotado tenta de novo em 1–5 min (antes: 10 min a 4 h)
set search_path = radar, public;

-- reserva: também recupera tarefas EXECUTANDO abandonadas (execução encerrada no meio) há mais de 16 min
create or replace function reservar_tarefas(p_limite int, p_sync bigint default null)
returns setof fila_coleta language sql set search_path = radar, public as $$
  update fila_coleta f set status = 'EXECUTANDO', tentativas = f.tentativas + 1, atualizado_em = now()
  where f.id in (
    select id from fila_coleta
    where endpoint is not null and tentativas < 6 and (
            (status in ('PENDENTE','ERRO') and proxima_em <= now())
         or (status = 'EXECUTANDO' and atualizado_em < now() - interval '16 minutes'))
    order by prioridade, proxima_em, id
    limit p_limite for update skip locked)
  returning f.*;
$$;

-- espera após erro: rede/tempo esgotado (HTTP 0) e 5xx tentam logo; 4xx (parâmetro) espera mais
create or replace function _espera_erro(p_http int, p_tentativas int) returns interval language sql immutable as $$
  select case when p_http = 0 or p_http >= 500 then make_interval(mins => least(p_tentativas, 5))
              else make_interval(mins => least(power(2, p_tentativas)::int * 5, 240)) end
$$;

-- início de ciclo: UASGs do Exército por UF
create or replace function iniciar_ciclo(p_tipo text default 'DIARIA') returns bigint
language plpgsql set search_path = radar, public as $$
declare v_sync bigint; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date; uf text;
begin
  update sincronizacoes set status = 'SUCESSO_PARCIAL', finalizada_em = now(),
         observacoes = coalesce(observacoes || ' · ', '') || 'encerrada pelo início de novo ciclo'
   where status = 'EM_ANDAMENTO';
  delete from fila_coleta where status = 'OK' and atualizado_em < now() - interval '7 days';
  delete from fila_coleta where tarefa = 'UASGS' and not (params ? 'siglaUf');      -- formato antigo (consulta única)
  update fila_coleta set status = 'PENDENTE', proxima_em = now() where status = 'EXECUTANDO';
  insert into sincronizacoes(tipo, status, janela_inicio, janela_fim) values (p_tipo, 'EM_ANDAMENTO', v_hoje - 1, v_hoje)
  returning id into v_sync;
  perform garantir_orgao(52121, v_sync);
  foreach uf in array array['AC','AL','AM','AP','BA','CE','DF','ES','GO','MA','MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN','RO','RR','RS','SC','SE','SP','TO'] loop
    perform enfileirar('UASGS', 1::smallint, '/modulo-uasg/1_consultarUasg',
      jsonb_build_object('statusUasg', true, 'cnpjCpfOrgao', '00394452000103', 'siglaUf', uf, 'pagina', 1), '{}', 2::smallint, v_sync, true);
  end loop;
  perform enfileirar('PNCP_CONTRATOS_ATUALIZACAO', 2::smallint, '/v1/contratos/atualizacao',
    jsonb_build_object('dataInicial', to_char(v_hoje - 1, 'YYYYMMDD'), 'dataFinal', to_char(v_hoje, 'YYYYMMDD'),
                       'cnpjOrgao', '00394452000103', 'pagina', 1, 'tamanhoPagina', 50), '{}', 5::smallint, v_sync, true);
  perform enfileirar('PNCP_ATAS_ATUALIZACAO', 2::smallint, '/v1/atas/atualizacao',
    jsonb_build_object('dataInicial', to_char(v_hoje - 1, 'YYYYMMDD'), 'dataFinal', to_char(v_hoje, 'YYYYMMDD'),
                       'cnpj', '00394452000103', 'pagina', 1, 'tamanhoPagina', 50), '{}', 5::smallint, v_sync, true);
  return v_sync;
end $$;

-- aplica a nova espera de erro dentro de ingerir() (troca só a expressão de backoff)
do $$
declare def text;
begin
  select pg_get_functiondef('radar.ingerir(bigint,integer,jsonb)'::regprocedure) into def;
  def := replace(def, 'proxima_em = now() + make_interval(mins => least(power(2, tentativas)::int * 5, 240))',
                      'proxima_em = now() + _espera_erro(p_http, tentativas)');
  if position('_espera_erro' in def) = 0 then raise exception 'ajuste de backoff não aplicado em ingerir()'; end if;
  execute def;
end $$;

revoke execute on function iniciar_ciclo(text), reservar_tarefas(int, bigint) from public, anon, authenticated;
grant execute on function iniciar_ciclo(text), reservar_tarefas(int, bigint) to service_role;

-- destrava a fila atual: troca a consulta única de UASGs pelas consultas por UF no ciclo aberto,
-- libera tarefas presas e antecipa as que esperavam
do $$
declare v_sync bigint; uf text;
begin
  select id into v_sync from sincronizacoes where status = 'EM_ANDAMENTO' order by id desc limit 1;
  if exists (select 1 from fila_coleta where tarefa = 'UASGS' and not (params ? 'siglaUf')) then
    delete from fila_coleta where tarefa = 'UASGS' and not (params ? 'siglaUf');
    foreach uf in array array['AC','AL','AM','AP','BA','CE','DF','ES','GO','MA','MG','MS','MT','PA','PB','PE','PI','PR','RJ','RN','RO','RR','RS','SC','SE','SP','TO'] loop
      perform enfileirar('UASGS', 1::smallint, '/modulo-uasg/1_consultarUasg',
        jsonb_build_object('statusUasg', true, 'cnpjCpfOrgao', '00394452000103', 'siglaUf', uf, 'pagina', 1), '{}', 2::smallint, v_sync, true);
    end loop;
  end if;
end $$;
update fila_coleta set status = 'PENDENTE', proxima_em = now(), tentativas = 0 where status in ('EXECUTANDO', 'ERRO');

notify pgrst, 'reload schema';
