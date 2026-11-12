set search_path = radar, public;
-- Classificação automática: aplica a regra de menor prioridade que casar com a descrição do item
-- (ou o objeto da ata). Nunca sobrescreve classificação MANUAL.
create or replace function classificar_itens() returns int language plpgsql as $$
declare n int;
begin
  with alvo as (
    select distinct on (i.id) i.id as item_id, r.categoria_id, r.id as regra_id
    from itens_atas i
    join atas_registro_precos a using (chave_ata)
    join regras_classificacao r on
         (r.tipo = 'REGEX_DESCRICAO' and upper(coalesce(i.descricao,'')) ~ r.valor)
      or (r.tipo = 'REGEX_OBJETO'    and upper(coalesce(a.objeto,''))    ~ r.valor)
      or (r.tipo = 'PDM'             and i.codigo_pdm::text = r.valor)
    order by i.id, r.prioridade
  )
  insert into classificacao_itens(item_id, categoria_id, metodo, regra_id, definido_por)
  select item_id, categoria_id, 'AUTOMATICO', regra_id, 'regras_v1' from alvo
  on conflict (item_id) do update set categoria_id = excluded.categoria_id, regra_id = excluded.regra_id, definido_em = now()
    where classificacao_itens.metodo = 'AUTOMATICO' and classificacao_itens.categoria_id <> excluded.categoria_id;
  get diagnostics n = row_count; return n;
end $$;

create or replace view v_itens_classificados as
select i.id as item_id, i.chave_ata, i.descricao, c.grupo, c.nome as categoria, ci.metodo,
       coalesce(c.grupo, case when i.tipo_item ilike 'Servi%' then 'SERVICOS' else 'AQUISICAO' end) as grupo_efetivo
from itens_atas i
left join classificacao_itens ci on ci.item_id = i.id
left join categorias c on c.id = ci.categoria_id;
alter view v_itens_classificados set (security_invoker = true);
