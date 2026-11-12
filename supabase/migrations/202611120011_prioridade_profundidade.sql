-- RADAR OM — coleta "em profundidade": adesões aparecem em minutos, não depois de varrer o país inteiro.
-- Antes: atas de todas as UASGs (prio 10) → itens (20) → unidades (30) → adesões (40).
-- Agora cada ata encontrada desce até as adesões antes de a varredura seguir para a próxima.
--   ORGAO 1 · UASGS 2 · UASG_CADASTRO 3 · ADESOES_ITEM 4 · PNCP_* 5 · UNIDADES_ITEM 6 · ATA_EXTERNA 7
--   ITENS_ATA 8 · ATAS_UASG 10 · EMPENHOS_ATA 60
set search_path = radar, public;

do $$
declare def text; antes text;
begin
  select pg_get_functiondef('radar.ingerir(bigint,integer,jsonb)'::regprocedure) into def;
  antes := def;
  def := replace(def, '40::smallint', '4::smallint');    -- ADESOES_ITEM
  def := replace(def, '30::smallint', '6::smallint');    -- UNIDADES_ITEM
  def := replace(def, '15::smallint', '7::smallint');    -- ATA_EXTERNA
  def := replace(def, '20::smallint', '8::smallint');    -- ITENS_ATA
  if def = antes or position('40::smallint' in def) > 0 or position('30::smallint' in def) > 0 then
    raise exception 'prioridades não aplicadas em ingerir()';
  end if;
  execute def;
end $$;

-- tarefas já na fila
update fila_coleta set prioridade = case tarefa
  when 'ADESOES_ITEM' then 4 when 'UNIDADES_ITEM' then 6 when 'ATA_EXTERNA' then 7 when 'ITENS_ATA' then 8 else prioridade end
where tarefa in ('ADESOES_ITEM','UNIDADES_ITEM','ATA_EXTERNA','ITENS_ATA');

notify pgrst, 'reload schema';
