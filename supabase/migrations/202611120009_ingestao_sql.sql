-- =====================================================================
-- RADAR OM — ingestão no banco (compatível com o plano gratuito do Cloudflare Workers)
-- O Worker só busca a página na API oficial e entrega o texto bruto a radar.ingerir().
-- Toda a interpretação, gravação, detecção de mudanças e enfileiramento acontece aqui.
-- Cada tarefa = 1 requisição à fonte + 1 chamada RPC.
-- =====================================================================
set search_path = radar, public;

-- ---------- fila genérica: cada tarefa sabe qual endpoint chamar ----------
delete from fila_coleta;                                   -- tarefas no formato antigo
update sincronizacoes set status = 'FALHA', finalizada_em = now(),
       observacoes = coalesce(observacoes || ' · ', '') || 'encerrada na migração 009'
 where status = 'EM_ANDAMENTO';

alter table fila_coleta drop constraint if exists fila_coleta_tarefa_check;
alter table fila_coleta add constraint fila_coleta_tarefa_check check (tarefa in (
  'ORGAO','UASGS','UASG_CADASTRO','ATAS_UASG','ATA_EXTERNA','ITENS_ATA','UNIDADES_ITEM',
  'ADESOES_ITEM','EMPENHOS_ATA','PNCP_CONTRATOS_ATUALIZACAO','PNCP_ATAS_ATUALIZACAO'));
alter table fila_coleta add column if not exists fonte_id smallint references fontes(id);
alter table fila_coleta add column if not exists endpoint text;
alter table fila_coleta add column if not exists params jsonb;
alter table fila_coleta add column if not exists ctx jsonb not null default '{}'::jsonb;

-- ---------- utilitários ----------
create or replace function _d(t text) returns date language sql immutable set search_path = radar, public as
$$ select case when coalesce(t,'') = '' then null else left(t, 10)::date end $$;
create or replace function _ts(t text) returns timestamptz language sql immutable set search_path = radar, public as
$$ select case when coalesce(t,'') = '' then null else t::timestamptz end $$;
create or replace function _n(t text) returns numeric language sql immutable set search_path = radar, public as
$$ select case when coalesce(t,'') = '' then null else t::numeric end $$;

-- enfileira (idempotente): mesma tarefa + mesmos parâmetros = mesma linha
create or replace function enfileirar(p_tarefa text, p_fonte smallint, p_endpoint text, p_params jsonb,
                                      p_ctx jsonb, p_prio smallint, p_sync bigint, p_reabrir boolean default false)
returns void language plpgsql set search_path = radar, public as $$
begin
  insert into fila_coleta(tarefa, chave, fonte_id, endpoint, params, ctx, prioridade, sincronizacao_id)
  values (p_tarefa, p_params, p_fonte, p_endpoint, p_params, coalesce(p_ctx, '{}'), p_prio, p_sync)
  on conflict (tarefa, chave) do update
     set status = 'PENDENTE', tentativas = 0, proxima_em = now(), ultimo_erro = null,
         ctx = excluded.ctx, sincronizacao_id = excluded.sincronizacao_id, atualizado_em = now()
   where p_reabrir and fila_coleta.status <> 'EXECUTANDO';
end $$;

-- órgão desconhecido: cria registro provisório (FK) e agenda a consulta ao cadastro oficial
create or replace function garantir_orgao(p_codigo int, p_sync bigint) returns void language plpgsql set search_path = radar, public as $$
begin
  if p_codigo is null then return; end if;
  insert into orgaos_publicos(codigo_orgao, nome, forca, fonte_id)
  values (p_codigo, 'Órgão ' || p_codigo || ' (aguardando cadastro oficial)', 'OUTRO', 1)
  on conflict (codigo_orgao) do nothing;
  if found then
    perform enfileirar('ORGAO', 1::smallint, '/modulo-uasg/2_consultarOrgao',
      jsonb_build_object('statusOrgao', true, 'codigoOrgao', p_codigo), '{}', 1::smallint, p_sync);
  end if;
end $$;

-- UASG desconhecida (aderente, participante, contratante, gerenciadora externa)
create or replace function garantir_uasg(p_codigo text, p_nome text, p_sync bigint) returns void language plpgsql set search_path = radar, public as $$
begin
  if coalesce(p_codigo, '') = '' then return; end if;
  insert into uasgs(codigo_uasg, nome, codigo_orgao, fonte_id)
  values (p_codigo, coalesce(nullif(p_nome, ''), p_codigo), null, 1)
  on conflict (codigo_uasg) do nothing;
  if found then
    perform enfileirar('UASG_CADASTRO', 1::smallint, '/modulo-uasg/1_consultarUasg',
      jsonb_build_object('statusUasg', true, 'codigoUasg', p_codigo), '{}', 3::smallint, p_sync);
  end if;
end $$;

-- ---------- reserva com trava (substitui a da migração 004) ----------
create or replace function reservar_tarefas(p_limite int, p_sync bigint default null)
returns setof fila_coleta language sql set search_path = radar, public as $$
  update fila_coleta f set status = 'EXECUTANDO', tentativas = f.tentativas + 1, atualizado_em = now()
  where f.id in (
    select id from fila_coleta
    where status in ('PENDENTE','ERRO') and proxima_em <= now() and tentativas < 6 and endpoint is not null
    order by prioridade, proxima_em, id
    limit p_limite for update skip locked)
  returning f.*;
$$;

create or replace function devolver_tarefas(p_ids bigint[], p_segundos int default 30) returns void language sql set search_path = radar, public as $$
  update fila_coleta set status = 'PENDENTE', tentativas = greatest(tentativas - 1, 0),
         proxima_em = now() + make_interval(secs => p_segundos), atualizado_em = now()
  where id = any(p_ids) and status = 'EXECUTANDO';
$$;

-- ---------- início de ciclo ----------
create or replace function iniciar_ciclo(p_tipo text default 'DIARIA') returns bigint language plpgsql set search_path = radar, public as $$
declare v_sync bigint; v_hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  update sincronizacoes set status = 'SUCESSO_PARCIAL', finalizada_em = now(),
         observacoes = coalesce(observacoes || ' · ', '') || 'encerrada pelo início de novo ciclo'
   where status = 'EM_ANDAMENTO';
  delete from fila_coleta where status = 'OK' and atualizado_em < now() - interval '7 days';
  perform liberar_tarefas_presas();
  insert into sincronizacoes(tipo, status, janela_inicio, janela_fim) values (p_tipo, 'EM_ANDAMENTO', v_hoje - 1, v_hoje)
  returning id into v_sync;
  perform garantir_orgao(52121, v_sync);
  -- cadastro oficial de UASGs do Comando do Exército (a ingestão enfileira as atas de cada UASG)
  perform enfileirar('UASGS', 1::smallint, '/modulo-uasg/1_consultarUasg',
    jsonb_build_object('statusUasg', true, 'cnpjCpfOrgao', '00394452000103', 'pagina', 1), '{}', 2::smallint, v_sync, true);
  perform enfileirar('PNCP_CONTRATOS_ATUALIZACAO', 2::smallint, '/v1/contratos/atualizacao',
    jsonb_build_object('dataInicial', to_char(v_hoje - 1, 'YYYYMMDD'), 'dataFinal', to_char(v_hoje, 'YYYYMMDD'),
                       'cnpjOrgao', '00394452000103', 'pagina', 1, 'tamanhoPagina', 100), '{}', 5::smallint, v_sync, true);
  perform enfileirar('PNCP_ATAS_ATUALIZACAO', 2::smallint, '/v1/atas/atualizacao',
    jsonb_build_object('dataInicial', to_char(v_hoje - 1, 'YYYYMMDD'), 'dataFinal', to_char(v_hoje, 'YYYYMMDD'),
                       'cnpj', '00394452000103', 'pagina', 1, 'tamanhoPagina', 100), '{}', 5::smallint, v_sync, true);
  return v_sync;
end $$;

-- enfileira as janelas de fim de vigência (ontem → +3 anos, até 365 dias cada) de uma UASG
create or replace function enfileirar_atas_uasg(p_uasg text, p_sync bigint) returns void language plpgsql set search_path = radar, public as $$
declare v_ini date := (now() at time zone 'America/Sao_Paulo')::date - 1; v_fim date := v_ini + 3 * 365; a date;
begin
  a := v_ini;
  while a <= v_fim loop
    perform enfileirar('ATAS_UASG', 1::smallint, '/modulo-arp/1.2_consultarARP_FimVigencia',
      jsonb_build_object('codigoUnidadeGerenciadora', p_uasg, 'dataVigenciaFinalMin', a,
                         'dataVigenciaFinalMax', least(a + 364, v_fim), 'pagina', 1, 'tamanhoPagina', 500),
      '{}', 10::smallint, p_sync, true);
    a := a + 365;
  end loop;
end $$;

-- ---------- INGESTÃO ----------
create or replace function ingerir(p_id bigint, p_http int, p_resposta jsonb) returns jsonb
language plpgsql set search_path = radar, public as $$
declare
  t fila_coleta; v_pid bigint; regs jsonb; r jsonb; n int := 0; v_chave text; v_ant timestamptz;
  v_item bigint; v_saldo_ant numeric; v_aceita boolean; v_saldo_novo numeric; v_uasg text; v_nome text;
  v_mais boolean := false; v_prox jsonb;
begin
  select * into t from fila_coleta where id = p_id for update;
  if not found then return jsonb_build_object('erro', 'tarefa inexistente'); end if;

  -- limite de taxa: devolve sem contar tentativa
  if p_http = 429 then
    update fila_coleta set status = 'PENDENTE', tentativas = greatest(tentativas - 1, 0),
           proxima_em = now() + interval '15 seconds', atualizado_em = now() where id = p_id;
    update sincronizacoes set respostas_429 = respostas_429 + 1, requisicoes = requisicoes + 1 where id = t.sincronizacao_id;
    return jsonb_build_object('status', 'RATE_LIMIT');
  end if;
  if p_http >= 400 or p_http = 0 then
    update fila_coleta set status = 'ERRO', ultimo_erro = left('HTTP ' || p_http || ' ' || coalesce(p_resposta::text, ''), 500),
           proxima_em = now() + make_interval(mins => least(power(2, tentativas)::int * 5, 240)), atualizado_em = now() where id = p_id;
    insert into logs_integracao(sincronizacao_id, fonte_id, nivel, endpoint, parametros, http_status, mensagem, tentativa)
    values (t.sincronizacao_id, t.fonte_id, 'ERRO', t.endpoint, t.params, p_http, left(coalesce(p_resposta::text, 'sem corpo'), 1000), t.tentativas);
    update sincronizacoes set reg_erros = reg_erros + 1, requisicoes = requisicoes + 1 where id = t.sincronizacao_id;
    return jsonb_build_object('status', 'ERRO');
  end if;

  -- rastreabilidade: hash do corpo + endpoint + parâmetros (corpo não é guardado para caber no plano gratuito)
  insert into payloads(fonte_id, endpoint, parametros, http_status, hash_sha256, corpo, sincronizacao_id)
  values (t.fonte_id, t.endpoint, t.params, p_http,
          encode(sha256(convert_to(coalesce(p_resposta::text, ''), 'UTF8')), 'hex'), null, t.sincronizacao_id)
  on conflict (hash_sha256, endpoint) do update set coletado_em = now()
  returning id into v_pid;

  regs := coalesce(case when t.fonte_id = 1 then p_resposta -> 'resultado' else p_resposta -> 'data' end, '[]'::jsonb);
  if jsonb_typeof(regs) <> 'array' then regs := '[]'::jsonb; end if;

  case t.tarefa
  -- ------------------------------------------------------------------
  when 'ORGAO' then
    for r in select * from jsonb_array_elements(regs) loop
      insert into orgaos_publicos(codigo_orgao, nome, sigla, cnpj, codigo_orgao_vinculado, nome_orgao_vinculado, forca, fonte_id, coletado_em)
      values ((r->>'codigoOrgao')::int, r->>'nomeOrgao', r->>'nomeMnemonicoOrgao', r->>'cnpjCpfOrgao',
              (r->>'codigoOrgaoVinculado')::int, r->>'nomeOrgaoVinculado',
              case (r->>'codigoOrgao')::int when 52121 then 'EXERCITO' when 52131 then 'MARINHA' when 52111 then 'AERONAUTICA' when 52000 then 'MD' else 'OUTRO' end, 1, now())
      on conflict (codigo_orgao) do update set nome = excluded.nome, sigla = excluded.sigla, cnpj = excluded.cnpj,
        codigo_orgao_vinculado = excluded.codigo_orgao_vinculado, nome_orgao_vinculado = excluded.nome_orgao_vinculado,
        forca = excluded.forca, coletado_em = now();
      n := n + 1;
    end loop;

  -- ------------------------------------------------------------------
  when 'UASGS', 'UASG_CADASTRO' then
    for r in select * from jsonb_array_elements(regs) loop
      perform garantir_orgao((r->>'codigoOrgao')::int, t.sincronizacao_id);
      insert into uasgs(codigo_uasg, nome, codigo_orgao, cnpj_orgao, uf, municipio, codigo_ibge, codigo_siorg,
                        codigo_unidade_polo, nome_unidade_polo, uso_sisg, ativa, fonte_id, payload_id, coletado_em, atualizado_fonte_em)
      values (r->>'codigoUasg', r->>'nomeUasg', (r->>'codigoOrgao')::int, nullif(r->>'cnpjCpfOrgao', ''), nullif(r->>'siglaUf', ''),
              nullif(r->>'nomeMunicipioIbge', ''), (r->>'codigoMunicipioIbge')::int, nullif(r->>'codigoSiorg', ''),
              nullif(nullif(r->>'codigoUnidadePolo', ''), '0'), nullif(r->>'nomeUnidadePolo', ''), (r->>'usoSisg')::boolean,
              (r->>'statusUasg')::boolean, 1, v_pid, now(), _ts(r->>'dataHoraMovimento'))
      on conflict (codigo_uasg) do update set nome = excluded.nome, codigo_orgao = excluded.codigo_orgao, cnpj_orgao = excluded.cnpj_orgao,
        uf = excluded.uf, municipio = excluded.municipio, codigo_ibge = excluded.codigo_ibge, codigo_siorg = excluded.codigo_siorg,
        codigo_unidade_polo = excluded.codigo_unidade_polo, nome_unidade_polo = excluded.nome_unidade_polo, uso_sisg = excluded.uso_sisg,
        ativa = excluded.ativa, payload_id = excluded.payload_id, coletado_em = now(), atualizado_fonte_em = excluded.atualizado_fonte_em;
      if (r->>'codigoOrgao')::int = 52121 then
        -- RM inferida do CGCFEx informado como polo (nº do CGCFEx = nº da RM; pendente de validação)
        insert into organizacoes_militares(codigo_uasg, nome_completo, regiao_militar, cma_sigla, uf, municipio, situacao_cadastral, metodo_vinculo_rm)
        select r->>'codigoUasg', r->>'nomeUasg', rm, (array['CML','CMSE','CMS','CML','CMS','CMNE','CMNE','CMN','CMO','CMNE','CMP','CMA'])[rm],
               nullif(r->>'siglaUf', ''), nullif(r->>'nomeMunicipioIbge', ''),
               case when (r->>'statusUasg')::boolean then 'ATIVA' else 'INATIVA' end,
               case when rm is null then 'PENDENTE' else 'INFERIDO_POLO_CGCFEX' end
        from (select case when m.num between 1 and 12 then m.num end as rm
              from (select substring(coalesce(r->>'nomeUnidadePolo', '') from '^(\d{1,2})\D*\s*CENTRO DE GEST')::int as num) m) x
        on conflict (codigo_uasg) do update set nome_completo = excluded.nome_completo, uf = excluded.uf, municipio = excluded.municipio,
          situacao_cadastral = excluded.situacao_cadastral,
          regiao_militar = case when organizacoes_militares.metodo_vinculo_rm = 'VALIDADO_MANUAL' then organizacoes_militares.regiao_militar else excluded.regiao_militar end,
          cma_sigla = case when organizacoes_militares.metodo_vinculo_rm = 'VALIDADO_MANUAL' then organizacoes_militares.cma_sigla else excluded.cma_sigla end,
          metodo_vinculo_rm = case when organizacoes_militares.metodo_vinculo_rm = 'VALIDADO_MANUAL' then 'VALIDADO_MANUAL' else excluded.metodo_vinculo_rm end;
        insert into om_aliases(om_id, alias, origem) select id, r->>'nomeUasg', 'NOME_UASG_COMPRAS'
          from organizacoes_militares where codigo_uasg = r->>'codigoUasg' on conflict do nothing;
        if t.tarefa = 'UASGS' and (r->>'statusUasg')::boolean then perform enfileirar_atas_uasg(r->>'codigoUasg', t.sincronizacao_id); end if;
      end if;
      n := n + 1;
    end loop;
    v_mais := t.tarefa = 'UASGS' and coalesce((p_resposta->>'paginasRestantes')::int, 0) > 0;

  -- ------------------------------------------------------------------
  when 'ATAS_UASG', 'ATA_EXTERNA' then
    for r in select * from jsonb_array_elements(regs) loop
      v_chave := coalesce(nullif(r->>'numeroControlePncpAta', ''),
        'SIASG:' || (r->>'codigoUnidadeGerenciadora') || ':' || (r->>'numeroAtaRegistroPreco') || ':' || (r->>'numeroCompra') || '/' || (r->>'anoCompra'));
      perform garantir_uasg(r->>'codigoUnidadeGerenciadora', r->>'nomeUnidadeGerenciadora', t.sincronizacao_id);
      select atualizado_fonte_em into v_ant from atas_registro_precos where chave_ata = v_chave;
      insert into atas_registro_precos(chave_ata, numero_controle_pncp_ata, numero_ata, codigo_uasg_gerenciadora, numero_controle_pncp_compra,
        numero_compra, ano_compra, modalidade_codigo, modalidade_nome, objeto, data_assinatura, vigencia_inicio, vigencia_fim, valor_total,
        quantidade_itens, status_fonte, excluida_fonte, link_ata_pncp, link_compra_pncp, fonte_id, payload_id, coletado_em, atualizado_fonte_em)
      values (v_chave, nullif(r->>'numeroControlePncpAta', ''), r->>'numeroAtaRegistroPreco', r->>'codigoUnidadeGerenciadora',
        nullif(r->>'numeroControlePncpCompra', ''), nullif(r->>'numeroCompra', ''), nullif(r->>'anoCompra', '')::smallint,
        nullif(r->>'codigoModalidadeCompra', ''), nullif(r->>'nomeModalidadeCompra', ''), nullif(r->>'objeto', ''), _d(r->>'dataAssinatura'),
        _d(r->>'dataVigenciaInicial'), _d(r->>'dataVigenciaFinal'), _n(r->>'valorTotal'), (r->>'quantidadeItens')::int, nullif(r->>'statusAta', ''),
        coalesce((r->>'ataExcluido')::boolean, false), nullif(r->>'linkAtaPNCP', ''), nullif(r->>'linkCompraPNCP', ''), 1, v_pid, now(),
        _ts(r->>'dataHoraAtualizacao'))
      on conflict (chave_ata) do update set vigencia_inicio = excluded.vigencia_inicio, vigencia_fim = excluded.vigencia_fim,
        valor_total = excluded.valor_total, quantidade_itens = excluded.quantidade_itens, status_fonte = excluded.status_fonte,
        excluida_fonte = excluded.excluida_fonte, objeto = excluded.objeto, link_ata_pncp = excluded.link_ata_pncp,
        payload_id = excluded.payload_id, coletado_em = now(), atualizado_fonte_em = excluded.atualizado_fonte_em;
      -- nova ou alterada na fonte → coleta itens e empenhos
      if (v_ant is null or v_ant is distinct from _ts(r->>'dataHoraAtualizacao')) and coalesce(r->>'numeroControlePncpAta', '') <> '' then
        perform enfileirar('ITENS_ATA', 1::smallint, '/modulo-arp/2.1_consultarARPItem_Id',
          jsonb_build_object('numeroControlePncpAta', r->>'numeroControlePncpAta'), jsonb_build_object('chave_ata', v_chave), 20::smallint, t.sincronizacao_id, true);
        perform enfileirar('EMPENHOS_ATA', 1::smallint, '/modulo-arp/4_consultarEmpenhosSaldoItem',
          jsonb_build_object('numeroAta', r->>'numeroAtaRegistroPreco', 'unidadeGerenciadora', r->>'codigoUnidadeGerenciadora'),
          jsonb_build_object('chave_ata', v_chave), 60::smallint, t.sincronizacao_id, true);
      end if;
      n := n + 1;
    end loop;
    v_mais := coalesce((p_resposta->>'paginasRestantes')::int, 0) > 0;

  -- ------------------------------------------------------------------
  when 'ITENS_ATA' then
    for r in select * from jsonb_array_elements(regs) loop
      if coalesce(r->>'niFornecedor', '') <> '' then
        insert into fornecedores(ni, razao_social, fonte_id) values (r->>'niFornecedor', coalesce(r->>'nomeRazaoSocialFornecedor', r->>'niFornecedor'), 1)
        on conflict (ni) do nothing;
      end if;
      insert into itens_atas(chave_ata, numero_item, tipo_item, codigo_item_catalogo, codigo_pdm, nome_pdm, descricao, ni_fornecedor,
        classificacao_fornecedor, quantidade_homologada_item, quantidade_registrada, valor_unitario, valor_total, maximo_adesao_fonte,
        quantidade_empenhada_fonte, excluido_fonte, fonte_id, payload_id, coletado_em, atualizado_fonte_em)
      values (t.ctx->>'chave_ata', r->>'numeroItem', nullif(r->>'tipoItem', ''), (r->>'codigoItem')::bigint, (r->>'codigoPdm')::int,
        nullif(r->>'nomePdm', ''), nullif(r->>'descricaoItem', ''), nullif(r->>'niFornecedor', ''), nullif(r->>'classificacaoFornecedor', ''),
        _n(r->>'quantidadeHomologadaItem'), _n(r->>'quantidadeHomologadaVencedor'), _n(r->>'valorUnitario'), _n(r->>'valorTotal'),
        _n(r->>'maximoAdesao'), _n(r->>'quantidadeEmpenhada'), coalesce((r->>'itemExcluido')::boolean, false), 1, v_pid, now(),
        _ts(r->>'dataHoraAtualizacao'))
      on conflict (chave_ata, numero_item) do update set descricao = excluded.descricao, quantidade_registrada = excluded.quantidade_registrada,
        valor_unitario = excluded.valor_unitario, valor_total = excluded.valor_total, excluido_fonte = excluded.excluido_fonte,
        payload_id = excluded.payload_id, coletado_em = now(), atualizado_fonte_em = excluded.atualizado_fonte_em
      returning id into v_item;
      perform enfileirar('UNIDADES_ITEM', 1::smallint, '/modulo-arp/3_consultarUnidadesItem',
        jsonb_build_object('numeroAta', r->>'numeroAtaRegistroPreco', 'unidadeGerenciadora', r->>'codigoUnidadeGerenciadora', 'numeroItem', r->>'numeroItem'),
        jsonb_build_object('item_id', v_item), 30::smallint, t.sincronizacao_id, true);
      n := n + 1;
    end loop;
    v_mais := coalesce((p_resposta->>'paginasRestantes')::int, 0) > 0;

  -- ------------------------------------------------------------------
  when 'UNIDADES_ITEM' then
    v_item := (t.ctx->>'item_id')::bigint;
    select saldo_adesoes_fonte into v_saldo_ant from unidades_itens_ata where item_id = v_item limit 1;
    v_aceita := false;
    for r in select * from jsonb_array_elements(regs) loop
      perform garantir_uasg(r->>'codigoUnidade', r->>'nomeUnidade', t.sincronizacao_id);
      insert into unidades_itens_ata(item_id, codigo_uasg, tipo_unidade, quantidade_registrada, aceita_adesao, qtd_limite_adesao,
        qtd_limite_informado_compra, saldo_adesoes_fonte, saldo_remanejamento_empenho_fonte, fonte_id, payload_id, coletado_em, atualizado_fonte_em)
      values (v_item, r->>'codigoUnidade', r->>'tipoUnidade', _n(r->>'quantidadeRegistrada'), (r->>'aceitaAdesao')::boolean,
        _n(r->>'qtdLimiteAdesao'), _n(r->>'qtdLimiteInformadoCompra'), _n(r->>'saldoAdesoes'), _n(r->>'saldoRemanejamentoEmpenho'),
        1, v_pid, now(), _ts(r->>'dataHoraAtualizacao'))
      on conflict (item_id, codigo_uasg) do update set tipo_unidade = excluded.tipo_unidade, quantidade_registrada = excluded.quantidade_registrada,
        aceita_adesao = excluded.aceita_adesao, qtd_limite_adesao = excluded.qtd_limite_adesao, saldo_adesoes_fonte = excluded.saldo_adesoes_fonte,
        saldo_remanejamento_empenho_fonte = excluded.saldo_remanejamento_empenho_fonte, payload_id = excluded.payload_id, coletado_em = now(),
        atualizado_fonte_em = excluded.atualizado_fonte_em;
      v_aceita := v_aceita or coalesce((r->>'aceitaAdesao')::boolean, false);
      v_saldo_novo := coalesce(v_saldo_novo, _n(r->>'saldoAdesoes'));
      n := n + 1;
    end loop;
    -- só consulta adesões se o item aceita adesão E (primeira coleta OU o saldo mudou)
    if v_aceita and (v_saldo_ant is null or v_saldo_ant is distinct from v_saldo_novo) then
      perform enfileirar('ADESOES_ITEM', 1::smallint, '/modulo-arp/5_consultarAdesoesItem', t.params, t.ctx, 40::smallint, t.sincronizacao_id, true);
    end if;

  -- ------------------------------------------------------------------
  when 'ADESOES_ITEM' then
    for r in select * from jsonb_array_elements(regs) loop
      v_uasg := trim(split_part(r->>'unidadeNaoParticipante', ' - ', 1));
      v_nome := trim(substr(r->>'unidadeNaoParticipante', length(split_part(r->>'unidadeNaoParticipante', ' - ', 1)) + 4));
      perform garantir_uasg(v_uasg, v_nome, t.sincronizacao_id);
      insert into adesoes(item_id, codigo_uasg_aderente, data_aprovacao, quantidade_aprovada, fonte_id, payload_id)
      values ((t.ctx->>'item_id')::bigint, v_uasg, _ts(r->>'dataAprovacaoAnalise'), _n(r->>'quantidadeAprovadaAdesao'), 1, v_pid)
      on conflict do nothing;
      if found then n := n + 1; end if;
    end loop;
    v_mais := coalesce((p_resposta->>'paginasRestantes')::int, 0) > 0;

  -- ------------------------------------------------------------------
  when 'EMPENHOS_ATA' then
    -- estrutura ainda não observada com dados: guarda bruto, sem vínculo com saldo
    for r in select * from jsonb_array_elements(regs) loop
      insert into empenhos(chave_ata, bruto, vinculo_item_confirmado, fonte_id, payload_id) values (t.ctx->>'chave_ata', r, false, 1, v_pid);
      n := n + 1;
    end loop;

  -- ------------------------------------------------------------------
  when 'PNCP_CONTRATOS_ATUALIZACAO' then
    for r in select * from jsonb_array_elements(regs) loop
      perform garantir_uasg(r->'unidadeOrgao'->>'codigoUnidade', r->'unidadeOrgao'->>'nomeUnidade', t.sincronizacao_id);
      if coalesce(r->>'niFornecedor', '') <> '' then
        insert into fornecedores(ni, razao_social, fonte_id) values (r->>'niFornecedor', coalesce(r->>'nomeRazaoSocialFornecedor', r->>'niFornecedor'), 2)
        on conflict (ni) do nothing;
      end if;
      insert into contratos(numero_controle_pncp, numero_controle_pncp_ata, numero_controle_pncp_compra, fruto_adesao, codigo_uasg, ni_fornecedor,
        numero_contrato_empenho, tipo_contrato, categoria, objeto, processo, valor_inicial, valor_global, valor_acumulado, data_assinatura,
        vigencia_inicio, vigencia_fim, fonte_id, payload_id, coletado_em, atualizado_fonte_em)
      values (r->>'numeroControlePNCP', nullif(r->>'numeroControlePncpAta', ''), nullif(r->>'numeroControlePncpCompra', ''), (r->>'frutoAdesao')::boolean,
        r->'unidadeOrgao'->>'codigoUnidade', nullif(r->>'niFornecedor', ''), nullif(r->>'numeroContratoEmpenho', ''), r->'tipoContrato'->>'nome',
        r->'categoriaProcesso'->>'nome', nullif(r->>'objetoContrato', ''), nullif(r->>'processo', ''), _n(r->>'valorInicial'), _n(r->>'valorGlobal'),
        _n(r->>'valorAcumulado'), _d(r->>'dataAssinatura'), _d(r->>'dataVigenciaInicio'), _d(r->>'dataVigenciaFim'), 2, v_pid, now(),
        _ts(r->>'dataAtualizacaoGlobal'))
      on conflict (numero_controle_pncp) do update set fruto_adesao = excluded.fruto_adesao, valor_global = excluded.valor_global,
        valor_acumulado = excluded.valor_acumulado, vigencia_fim = excluded.vigencia_fim, payload_id = excluded.payload_id, coletado_em = now(),
        atualizado_fonte_em = excluded.atualizado_fonte_em;
      -- contrato fruto de adesão a ata ainda desconhecida (ex.: ata da Marinha) → coleta a ata
      if coalesce((r->>'frutoAdesao')::boolean, false) and coalesce(r->>'numeroControlePncpAta', '') <> ''
         and not exists (select 1 from atas_registro_precos where numero_controle_pncp_ata = r->>'numeroControlePncpAta') then
        perform enfileirar('ATA_EXTERNA', 1::smallint, '/modulo-arp/1.1_consultarARP_Id',
          jsonb_build_object('numeroControlePncpAta', r->>'numeroControlePncpAta'), '{}', 15::smallint, t.sincronizacao_id);
      end if;
      n := n + 1;
    end loop;
    v_mais := coalesce((p_resposta->>'numeroPagina')::int, 1) < coalesce((p_resposta->>'totalPaginas')::int, 0);

  -- ------------------------------------------------------------------
  when 'PNCP_ATAS_ATUALIZACAO' then
    for r in select * from jsonb_array_elements(regs) loop
      update atas_registro_precos set cancelada = coalesce((r->>'cancelado')::boolean, false), data_cancelamento = _d(r->>'dataCancelamento'),
             possibilidade_adesao_pncp = (r->>'possibilidadeAdesao')::boolean, data_publicacao_pncp = _d(r->>'dataPublicacaoPncp')
       where numero_controle_pncp_ata = r->>'numeroControlePNCPAta';
      if found then n := n + 1; end if;
    end loop;
    v_mais := coalesce((p_resposta->>'numeroPagina')::int, 1) < coalesce((p_resposta->>'totalPaginas')::int, 0);
  end case;

  -- próxima página = nova tarefa
  if v_mais then
    v_prox := t.params || jsonb_build_object('pagina', coalesce((t.params->>'pagina')::int, 1) + 1);
    perform enfileirar(t.tarefa, t.fonte_id, t.endpoint, v_prox, t.ctx, t.prioridade, t.sincronizacao_id, true);
  end if;

  update fila_coleta set status = 'OK', ultimo_erro = null, atualizado_em = now() where id = p_id;
  update sincronizacoes set reg_novos = reg_novos + n, requisicoes = requisicoes + 1 where id = t.sincronizacao_id;
  -- encerra o ciclo quando não há mais nada a fazer
  if t.sincronizacao_id is not null and not exists (
       select 1 from fila_coleta where status in ('PENDENTE','EXECUTANDO','ERRO') and tentativas < 6) then
    update sincronizacoes set status = case when reg_erros > 0 then 'SUCESSO_PARCIAL' else 'SUCESSO' end, finalizada_em = now()
     where id = t.sincronizacao_id and status = 'EM_ANDAMENTO';
  end if;
  return jsonb_build_object('status', 'OK', 'registros', n, 'proxima_pagina', v_mais);
end $$;

-- painel da fila (visível ao ADMINISTRADOR pela interface)
create or replace view api_fila as
select tarefa, status, count(*) as qtd, min(proxima_em) as proxima, max(atualizado_em) as ultima_atividade
from fila_coleta group by tarefa, status;
alter view api_fila set (security_invoker = true);

-- ---------- segurança ----------
-- funções de coleta: somente o Worker (service_role)
revoke execute on function ingerir(bigint, int, jsonb), iniciar_ciclo(text), reservar_tarefas(int, bigint),
  devolver_tarefas(bigint[], int), enfileirar(text, smallint, text, jsonb, jsonb, smallint, bigint, boolean),
  enfileirar_atas_uasg(text, bigint), garantir_uasg(text, text, bigint), garantir_orgao(int, bigint),
  liberar_tarefas_presas() from public, anon, authenticated;
grant execute on function ingerir(bigint, int, jsonb), iniciar_ciclo(text), reservar_tarefas(int, bigint),
  devolver_tarefas(bigint[], int) to service_role;
grant all on all tables in schema radar to service_role;
grant all on all sequences in schema radar to service_role;

-- leitura direta pela interface com o login do usuário: as views api_* passam a respeitar o RLS
alter view api_oms set (security_invoker = true);
alter view api_uasgs_ext set (security_invoker = true);
alter view api_atas set (security_invoker = true);
alter view api_itens set (security_invoker = true);
alter view api_fornecedores set (security_invoker = true);
alter view api_saldos set (security_invoker = true);
alter view api_unidades set (security_invoker = true);
alter view api_adesoes set (security_invoker = true);
alter view api_contratos set (security_invoker = true);
alter view api_sync set (security_invoker = true);
alter view api_dashboard set (security_invoker = true);
-- fila: leitura só para ADMINISTRADOR
create policy admin_le_fila on fila_coleta for select using (meu_perfil() = 'ADMINISTRADOR');
grant select on fila_coleta to authenticated;

notify pgrst, 'reload schema';
