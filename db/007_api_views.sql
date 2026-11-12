set search_path = radar, public;
-- Views no formato compacto consumido pela interface (/api/snapshot).
-- Lidas pelo Worker com a chave service_role (somente no backend), após validar o usuário.

create or replace view api_oms as
select o.codigo_uasg as u, o.nome_completo as n, o.regiao_militar as rm, o.cma_sigla as cma,
       o.uf, o.municipio as mun, o.metodo_vinculo_rm as met, g.nome_unidade_polo as polo
from organizacoes_militares o join uasgs g using (codigo_uasg);

create or replace view api_uasgs_ext as
select codigo_uasg as u, nome as n, codigo_orgao as orgao from uasgs where not coalesce(pertence_exercito, false);

create or replace view api_atas as
select chave_ata as k, numero_controle_pncp_ata as pncp, numero_ata as num, codigo_uasg_gerenciadora as ger,
       nome_gerenciadora as "gerN", numero_compra || '/' || ano_compra as compra, numero_controle_pncp_compra as "pncpCompra",
       modalidade_nome as mod, objeto as obj, data_assinatura as ass, vigencia_inicio as vi, vigencia_fim as vf,
       valor_total as valor, quantidade_itens as nit, situacao as sit, dias_restantes as dias, marco_alerta as marco,
       link_ata_pncp as link, link_compra_pncp as "linkC", atualizado_fonte_em as atu, coletado_em as col
from v_atas_situacao;

create or replace view api_itens as
select i.id, i.chave_ata as k, i.numero_item as n, i.codigo_item_catalogo as cat, i.tipo_item as t, i.descricao as d,
       i.ni_fornecedor as f, i.quantidade_homologada_item as qh, i.quantidade_registrada as qr, i.valor_unitario as vu,
       i.valor_total as vt, c.grupo_efetivo as g, c.categoria as c, c.metodo as cm
from itens_atas i join v_itens_classificados c on c.item_id = i.id;

create or replace view api_fornecedores as select ni, razao_social from fornecedores;

create or replace view api_saldos as
select * from v_saldos_itens where status_saldo_adesoes <> 'SEM_DADOS_DE_UNIDADES';

create or replace view api_unidades as
select u.item_id as item, u.codigo_uasg as u, g.nome as n, u.tipo_unidade as tipo, u.quantidade_registrada as qr,
       u.aceita_adesao as aceita, u.qtd_limite_adesao as lim, u.saldo_adesoes_fonte as saldo
from unidades_itens_ata u join uasgs g using (codigo_uasg);

create or replace view api_adesoes as select * from v_adesoes_detalhe;

create or replace view api_contratos as
select c.numero_controle_pncp as k, c.numero_controle_pncp_ata as ata, c.fruto_adesao as fa, c.codigo_uasg as u,
       g.nome as un, c.ni_fornecedor as f, f.razao_social as fn, c.valor_global as v, c.data_assinatura as ass,
       c.vigencia_fim as vf, c.objeto as obj, c.tipo_contrato as tipo, c.categoria as cat, c.processo as proc
from contratos c join uasgs g using (codigo_uasg) left join fornecedores f on f.ni = c.ni_fornecedor;

create or replace view api_sync as
select id, tipo, iniciada_em, finalizada_em, status, reg_novos, reg_atualizados, reg_erros, requisicoes, respostas_429, observacoes
from sincronizacoes order by id desc limit 30;

create or replace view api_dashboard as select * from v_dashboard;
