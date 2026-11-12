set search_path = radar, public;
-- Supabase: auth.uid() existe nativamente. Fora do Supabase, crie o stub (ver scripts/stub_auth.sql).

create or replace function meu_perfil() returns text language sql stable security definer
set search_path = radar, public as $$
  select perfil from radar.perfis where usuario_id = auth.uid() and ativo
$$;

create or replace function tem_permissao(p_recurso text) returns boolean language sql stable security definer
set search_path = radar, public as $$
  select coalesce(meu_perfil() = 'ADMINISTRADOR', false)
      or exists (select 1 from radar.permissoes where usuario_id = auth.uid() and recurso = p_recurso)
$$;

-- RLS: leitura para qualquer perfil ativo; escrita só pelo coletor (service_role ignora RLS) ou ADMINISTRADOR.
do $$
declare t text;
begin
  foreach t in array array['uasgs','organizacoes_militares','om_aliases','orgaos_publicos','fornecedores','processos_compra',
    'atas_registro_precos','itens_atas','unidades_itens_ata','adesoes','contratos','itens_contratos','empenhos','documentos',
    'categorias','regras_classificacao','classificacao_itens','historico_classificacao','historico_vigencia','historico_saldos',
    'alertas','sincronizacoes','status_fontes','regioes_militares','comandos_militares_area','fontes']
  loop
    execute format('alter table radar.%I enable row level security', t);
    execute format('create policy leitura on radar.%I for select using (radar.meu_perfil() is not null)', t);
    execute format('create policy escrita_admin on radar.%I for all using (radar.meu_perfil() = ''ADMINISTRADOR'') with check (radar.meu_perfil() = ''ADMINISTRADOR'')', t);
  end loop;
end $$;

-- classificação manual: ADMINISTRADOR ou quem tiver a permissão CLASSIFICACAO
create policy classificacao_gestor on classificacao_itens for all
  using (tem_permissao('CLASSIFICACAO')) with check (tem_permissao('CLASSIFICACAO'));

-- dados internos do coletor: invisíveis a usuários (só service_role)
alter table payloads enable row level security;
alter table logs_integracao enable row level security;
alter table fila_coleta enable row level security;
create policy admin_le_logs on logs_integracao for select using (meu_perfil() = 'ADMINISTRADOR');

-- perfis: cada um vê o próprio; admin gerencia todos
alter table perfis enable row level security;
create policy proprio on perfis for select using (usuario_id = auth.uid());
create policy admin_perfis on perfis for all using (meu_perfil() = 'ADMINISTRADOR') with check (meu_perfil() = 'ADMINISTRADOR');
alter table permissoes enable row level security;
create policy admin_permissoes on permissoes for all using (meu_perfil() = 'ADMINISTRADOR');
alter table auditoria enable row level security;
create policy admin_auditoria on auditoria for select using (meu_perfil() = 'ADMINISTRADOR');

-- trilha de auditoria de alterações manuais
create or replace function trg_auditoria() returns trigger language plpgsql security definer
set search_path = radar, public as $$
begin
  insert into radar.auditoria(usuario_id, acao, entidade, chave, detalhes)
  values (auth.uid(), tg_op, tg_table_name,
          coalesce(to_jsonb(new)->>'item_id', to_jsonb(new)->>'codigo_uasg', to_jsonb(new)->>'id'),
          jsonb_build_object('antes', case when tg_op <> 'INSERT' then to_jsonb(old) end, 'depois', to_jsonb(new)));
  return new;
end $$;
create trigger audit_classif after insert or update on classificacao_itens for each row execute function trg_auditoria();
create trigger audit_om after update on organizacoes_militares for each row execute function trg_auditoria();
create trigger audit_perfis after insert or update on perfis for each row execute function trg_auditoria();

-- views executam com permissões de quem consulta (respeitam RLS)
alter view v_atas_situacao set (security_invoker = true);
alter view v_saldos_itens set (security_invoker = true);
alter view v_adesoes_detalhe set (security_invoker = true);
alter view v_adesoes_limite_individual set (security_invoker = true);
alter view v_ranking_aderentes set (security_invoker = true);
alter view v_ranking_gerenciadoras set (security_invoker = true);
alter view v_oportunidades_adesao set (security_invoker = true);
alter view v_possiveis_duplicidades set (security_invoker = true);
alter view v_dashboard set (security_invoker = true);
