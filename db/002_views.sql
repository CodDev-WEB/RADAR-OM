set search_path = radar, public;

-- =====================================================================
-- Situação da ata (vigência da ATA, nunca do pregão)
-- =====================================================================
create or replace view v_atas_situacao as
select a.*,
       g.nome                       as nome_gerenciadora,
       g.pertence_exercito          as gerenciadora_exercito,
       (a.vigencia_fim - current_date) as dias_restantes,
       case
         when a.excluida_fonte                         then 'EXCLUIDA_NA_FONTE'
         when a.cancelada                              then 'CANCELADA'
         when a.vigencia_fim is null                   then 'SEM_VIGENCIA_INFORMADA'
         when a.vigencia_inicio > current_date         then 'A_INICIAR'
         when a.vigencia_fim < current_date            then 'VENCIDA'
         when a.vigencia_fim - current_date <= 90      then 'PROXIMA_DO_VENCIMENTO'
         else 'VIGENTE'
       end as situacao,
       case
         when a.vigencia_fim < current_date then 'VENCIDA'
         when a.vigencia_fim - current_date <= 7  then 'D7'
         when a.vigencia_fim - current_date <= 15 then 'D15'
         when a.vigencia_fim - current_date <= 30 then 'D30'
         when a.vigencia_fim - current_date <= 60 then 'D60'
         when a.vigencia_fim - current_date <= 90 then 'D90'
       end as marco_alerta
from atas_registro_precos a
join uasgs g on g.codigo_uasg = a.codigo_uasg_gerenciadora;

-- =====================================================================
-- Saldos por item — memória de cálculo explícita
--   (1) quantidade registrada originalmente (gerenciadora + participantes)
--   (2) limite para adesões (fonte) e verificação 2x (art. 86 §5º L14.133)
--   (3) quantidade AUTORIZADA a aderentes (soma das aprovações)
--   (4) saldo de adesões CALCULADO = (2) − (3)
--   (5) saldo de adesões INFORMADO pela fonte → confere / diverge
--   (6) empenhado: só quando há empenho vinculado ao item
-- =====================================================================
create or replace view v_saldos_itens as
with u as (
  select item_id,
         sum(quantidade_registrada)                                   as qtd_registrada_unidades,
         sum(quantidade_registrada) filter (where tipo_unidade ilike 'GERENC%') as qtd_gerenciadora,
         sum(quantidade_registrada) filter (where tipo_unidade ilike 'PARTIC%') as qtd_participantes,
         count(*) filter (where tipo_unidade ilike 'PARTIC%')         as n_participantes,
         max(qtd_limite_adesao)                                       as limite_adesao_fonte,
         max(saldo_adesoes_fonte)                                     as saldo_adesoes_fonte,
         bool_or(aceita_adesao)                                       as aceita_adesao,
         max(coletado_em)                                             as unidades_coletado_em
  from unidades_itens_ata group by item_id
), ad as (
  select item_id, sum(quantidade_aprovada) as qtd_autorizada_adesoes,
         count(*) as n_autorizacoes, count(distinct codigo_uasg_aderente) as n_aderentes,
         max(quantidade_aprovada) as maior_autorizacao
  from adesoes group by item_id
), emp as (
  select item_id, sum(quantidade_empenhada) as qtd_empenhada, sum(valor_empenhado) as valor_empenhado
  from empenhos where vinculo_item_confirmado group by item_id
)
select i.id as item_id, i.chave_ata, i.numero_item, i.descricao,
       i.codigo_item_catalogo, i.tipo_item, i.ni_fornecedor, i.valor_unitario,
       coalesce(u.qtd_registrada_unidades, i.quantidade_registrada) as qtd_registrada,
       u.qtd_gerenciadora, u.qtd_participantes, u.n_participantes,
       u.aceita_adesao,
       u.limite_adesao_fonte,
       (u.limite_adesao_fonte = 2 * u.qtd_registrada_unidades)      as limite_confere_dobro,
       coalesce(ad.qtd_autorizada_adesoes, 0)                        as qtd_autorizada_adesoes,
       coalesce(ad.n_autorizacoes, 0)                                as n_autorizacoes,
       coalesce(ad.n_aderentes, 0)                                   as n_aderentes,
       u.limite_adesao_fonte - coalesce(ad.qtd_autorizada_adesoes,0) as saldo_adesoes_calculado,
       u.saldo_adesoes_fonte,
       case
         when u.item_id is null                    then 'SEM_DADOS_DE_UNIDADES'
         when not coalesce(u.aceita_adesao,false)  then 'NAO_ACEITA_ADESAO'
         when u.saldo_adesoes_fonte = u.limite_adesao_fonte - coalesce(ad.qtd_autorizada_adesoes,0)
                                                   then 'CONFERE_COM_A_FONTE'
         else 'DIVERGENTE_DA_FONTE'
       end as status_saldo_adesoes,
       emp.qtd_empenhada, emp.valor_empenhado,
       case when emp.qtd_empenhada is null then null
            else coalesce(u.qtd_registrada_unidades, i.quantidade_registrada) - emp.qtd_empenhada end
         as qtd_disponivel_estimada,
       i.valor_unitario * coalesce(u.qtd_registrada_unidades, i.quantidade_registrada) as valor_registrado,
       i.valor_unitario * coalesce(ad.qtd_autorizada_adesoes,0)      as valor_autorizado_adesoes_estimado,
       i.valor_unitario * (u.limite_adesao_fonte - coalesce(ad.qtd_autorizada_adesoes,0)) as valor_saldo_adesoes_estimado,
       'Saldo estimado — sujeito à confirmação pelo órgão gerenciador.'::text as aviso,
       format('Limite adesão (fonte) %s − autorizado %s = %s; fonte informa %s',
              u.limite_adesao_fonte, coalesce(ad.qtd_autorizada_adesoes,0),
              u.limite_adesao_fonte - coalesce(ad.qtd_autorizada_adesoes,0), u.saldo_adesoes_fonte) as memoria_calculo
from itens_atas i
left join u   on u.item_id = i.id
left join ad  on ad.item_id = i.id
left join emp on emp.item_id = i.id;

-- =====================================================================
-- Adesões detalhadas (ficha da adesão)
--   valor = qtd autorizada × valor unitário registrado → ESTIMADO
--   contrato vinculado = contrato PNCP fruto de adesão, mesma ata, mesma UASG
-- =====================================================================
create or replace view v_adesoes_detalhe as
select ad.id as adesao_id,
       ad.estagio,
       ad.data_aprovacao,
       ad.quantidade_aprovada,
       ad.codigo_uasg_aderente,
       ua.nome                          as nome_aderente,
       ua.pertence_exercito             as aderente_exercito,
       ua.uf                            as uf_aderente,
       oma.regiao_militar               as rm_aderente,
       oma.cma_sigla                    as cma_aderente,
       a.codigo_uasg_gerenciadora,
       ug.nome                          as nome_gerenciadora,
       ug.pertence_exercito             as gerenciadora_exercito,
       omg.regiao_militar               as rm_gerenciadora,
       a.chave_ata, a.numero_controle_pncp_ata, a.numero_ata, a.numero_compra, a.ano_compra,
       a.numero_controle_pncp_compra, a.objeto, a.vigencia_inicio, a.vigencia_fim,
       a.link_ata_pncp,
       i.id as item_id, i.numero_item, i.codigo_item_catalogo, i.tipo_item, i.descricao,
       i.unidade_fornecimento,
       i.quantidade_registrada,
       i.valor_unitario,
       round(i.valor_unitario * ad.quantidade_aprovada, 2) as valor_adesao_estimado,
       i.ni_fornecedor, f.razao_social as fornecedor,
       c.numero_controle_pncp           as contrato_pncp,
       c.data_assinatura                as data_contratacao,
       c.valor_global                   as valor_contrato,
       case when c.numero_controle_pncp is not null then 'CONTRATADA (PNCP)'
            else 'AUTORIZADA — contratação não localizada' end as situacao_adesao,
       ad.fonte_id, ad.coletado_em
from adesoes ad
join itens_atas i            on i.id = ad.item_id
join atas_registro_precos a  on a.chave_ata = i.chave_ata
join uasgs ua                on ua.codigo_uasg = ad.codigo_uasg_aderente
join uasgs ug                on ug.codigo_uasg = a.codigo_uasg_gerenciadora
left join organizacoes_militares oma on oma.codigo_uasg = ad.codigo_uasg_aderente
left join organizacoes_militares omg on omg.codigo_uasg = a.codigo_uasg_gerenciadora
left join fornecedores f     on f.ni = i.ni_fornecedor
left join lateral (
  select * from contratos c
  where c.numero_controle_pncp_ata = a.numero_controle_pncp_ata
    and c.codigo_uasg = ad.codigo_uasg_aderente
    and c.fruto_adesao
  order by c.data_assinatura limit 1
) c on true;

-- verificação do limite individual (art. 86 §4º: cada adesão ≤ 50% do registrado)
create or replace view v_adesoes_limite_individual as
select d.item_id, d.codigo_uasg_aderente, d.nome_aderente,
       sum(d.quantidade_aprovada) as total_aderente,
       s.qtd_registrada,
       round(100.0 * sum(d.quantidade_aprovada) / nullif(s.qtd_registrada,0), 1) as pct_do_registrado,
       sum(d.quantidade_aprovada) > 0.5 * s.qtd_registrada as acima_50pct
from v_adesoes_detalhe d join v_saldos_itens s using (item_id)
group by d.item_id, d.codigo_uasg_aderente, d.nome_aderente, s.qtd_registrada;

-- =====================================================================
-- Rankings
-- =====================================================================
create or replace view v_ranking_aderentes as
select codigo_uasg_aderente as codigo_uasg, nome_aderente as om,
       count(*)                                 as qtd_adesoes,
       sum(valor_adesao_estimado)               as valor_total_aderido_estimado,
       count(distinct chave_ata) as qtd_atas,
       count(distinct ni_fornecedor)            as fornecedores_envolvidos
from v_adesoes_detalhe where aderente_exercito
group by 1,2 order by qtd_adesoes desc;

create or replace view v_ranking_gerenciadoras as
select codigo_uasg_gerenciadora as codigo_uasg, nome_gerenciadora as om,
       count(distinct chave_ata)   as qtd_atas_com_adesao,
       count(distinct codigo_uasg_aderente)       as qtd_om_aderentes,
       count(*)                                   as qtd_adesoes_recebidas,
       sum(valor_adesao_estimado)                 as valor_total_identificado
from v_adesoes_detalhe where gerenciadora_exercito
group by 1,2 order by qtd_adesoes_recebidas desc;

-- =====================================================================
-- Oportunidades: ata vigente + item aceita adesão + saldo informado > 0
-- NUNCA afirma que a adesão é possível: exige validação jurídica e
-- autorização do gerenciador.
-- =====================================================================
create or replace view v_oportunidades_adesao as
select s.*, a.codigo_uasg_gerenciadora, a.nome_gerenciadora, a.numero_ata, a.objeto,
       a.vigencia_fim, a.dias_restantes, a.situacao, a.link_ata_pncp,
       'Aparenta saldo para adesão segundo a fonte. Requer análise jurídica (art. 86 L14.133) e autorização do órgão gerenciador.'::text as ressalva
from v_saldos_itens s
join v_atas_situacao a using (chave_ata)
where a.situacao in ('VIGENTE','PROXIMA_DO_VENCIMENTO')
  and s.aceita_adesao
  and coalesce(s.saldo_adesoes_fonte,0) > 0;

-- =====================================================================
-- Possíveis duplicidades (regra 12)
-- =====================================================================
create or replace view v_possiveis_duplicidades as
select 'ATA_MESMO_NUMERO_UASG' as tipo, codigo_uasg_gerenciadora || ' ' || numero_ata as chave,
       count(*) as ocorrencias, array_agg(chave_ata) as registros
from atas_registro_precos group by codigo_uasg_gerenciadora, numero_ata having count(*) > 1;

-- =====================================================================
-- Indicadores do dashboard
-- =====================================================================
create or replace view v_dashboard as
select
  (select count(*) from organizacoes_militares)                                         as om_monitoradas,
  (select count(*) from processos_compra p join uasgs u using (codigo_uasg) where u.pertence_exercito) as pregoes_identificados,
  (select count(*) from v_atas_situacao where gerenciadora_exercito and situacao in ('VIGENTE','PROXIMA_DO_VENCIMENTO')) as atas_vigentes,
  (select count(*) from v_atas_situacao where gerenciadora_exercito and situacao = 'VENCIDA') as atas_vencidas,
  (select count(*) from adesoes)                                                        as adesoes_identificadas,
  (select count(distinct codigo_uasg_aderente) from v_adesoes_detalhe where aderente_exercito) as om_que_aderiram,
  (select sum(valor_total) from v_atas_situacao where gerenciadora_exercito)            as valor_total_registrado,
  (select sum(valor_adesao_estimado) from v_adesoes_detalhe)                            as valor_adesoes_estimado,
  (select sum(valor_empenhado) from empenhos where vinculo_item_confirmado)              as valor_empenhado_identificado,
  (select max(finalizada_em) from sincronizacoes where status in ('SUCESSO','SUCESSO_PARCIAL')) as ultima_sync_ok;
