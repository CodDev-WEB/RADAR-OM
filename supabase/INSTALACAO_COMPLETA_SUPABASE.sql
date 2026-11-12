-- RADAR OM — instalação completa (cole no SQL Editor do Supabase e execute uma vez).
-- Equivale às migrações de supabase/migrations em ordem. Gerado em 2026-11-12.

-- ===== 202611120001_schema.sql =====
-- =====================================================================
-- RADAR OM — Schema PostgreSQL (compatível com Supabase)
-- Princípios:
--   * todo registro carrega fonte_id + coletado_em + payload_id (rastreabilidade)
--   * autorização de adesão  ≠  contratação  ≠  empenho  ≠  entrega
--   * saldos são sempre CALCULADOS em views, com memória de cálculo,
--     e comparados ao saldo informado pela fonte quando existir
--   * pertencimento ao Exército vem do cadastro oficial de UASG
--     (órgão SIASG 52121 / CNPJ 00394452000103), nunca do nome
-- =====================================================================
create schema if not exists radar;
set search_path = radar, public;

-- ---------------------------------------------------------------------
-- 0. Fontes, sincronização, payload bruto
-- ---------------------------------------------------------------------
create table fontes (
  id            smallint primary key,
  codigo        text unique not null,          -- 'COMPRAS_DADOS_ABERTOS', 'PNCP_CONSULTA'
  nome          text not null,
  url_base      text not null,
  documentacao  text
);
insert into fontes values
 (1,'COMPRAS_DADOS_ABERTOS','API de Dados Abertos Compras.gov.br','https://dadosabertos.compras.gov.br','https://dadosabertos.compras.gov.br/swagger-ui/index.html'),
 (2,'PNCP_CONSULTA','PNCP — API de Consultas','https://pncp.gov.br/api/consulta','https://pncp.gov.br/api/consulta/swagger-ui/index.html'),
 (3,'MANUAL','Lançamento manual auditado (administrador)','-',null);

create table sincronizacoes (
  id              bigserial primary key,
  tipo            text not null check (tipo in ('DIARIA','MANUAL','BACKFILL','REPROCESSAMENTO')),
  iniciada_em     timestamptz not null default now(),
  finalizada_em   timestamptz,
  status          text not null default 'EM_ANDAMENTO'
                  check (status in ('EM_ANDAMENTO','SUCESSO','SUCESSO_PARCIAL','FALHA')),
  janela_inicio   date,
  janela_fim      date,
  reg_novos       int not null default 0,
  reg_atualizados int not null default 0,
  reg_erros       int not null default 0,
  requisicoes     int not null default 0,
  respostas_429   int not null default 0,
  observacoes     text
);

-- cada resposta de API persistida (ou seu hash) — permite reprocessar e auditar
create table payloads (
  id            bigserial primary key,
  fonte_id      smallint not null references fontes(id),
  endpoint      text not null,
  parametros    jsonb not null,
  http_status   int not null,
  hash_sha256   text not null,
  corpo         jsonb,                          -- pode ser podado após N dias (mantém hash)
  coletado_em   timestamptz not null default now(),
  sincronizacao_id bigint references sincronizacoes(id)
);
create index on payloads (fonte_id, endpoint, coletado_em desc);
create unique index on payloads (hash_sha256, endpoint);

create table logs_integracao (
  id            bigserial primary key,
  sincronizacao_id bigint references sincronizacoes(id),
  fonte_id      smallint references fontes(id),
  nivel         text not null check (nivel in ('INFO','AVISO','ERRO')),
  endpoint      text,
  parametros    jsonb,
  http_status   int,
  mensagem      text not null,
  tentativa     int default 1,
  criado_em     timestamptz not null default now()
);
create index on logs_integracao (sincronizacao_id, nivel);

create table status_fontes (               -- monitoramento de disponibilidade
  fonte_id      smallint references fontes(id),
  endpoint      text,
  verificado_em timestamptz not null default now(),
  disponivel    boolean not null,
  latencia_ms   int,
  http_status   int,
  primary key (fonte_id, endpoint, verificado_em)
);

-- colunas de proveniência reutilizadas
-- (fonte_id, payload_id, coletado_em, atualizado_fonte_em)

-- ---------------------------------------------------------------------
-- 1. Estrutura organizacional
-- ---------------------------------------------------------------------
create table comandos_militares_area (
  sigla text primary key,              -- CML, CMSE, CMS, CMNE, CMN, CMO, CMP, CMA
  nome  text not null
);
create table regioes_militares (
  numero     smallint primary key,     -- 1..12
  nome       text not null,
  cma_sigla  text references comandos_militares_area(sigla),
  sede       text
);

create table orgaos_publicos (
  codigo_orgao        int primary key,         -- código SIASG
  nome                text not null,
  sigla               text,
  cnpj                text,
  codigo_orgao_vinculado int,
  nome_orgao_vinculado text,
  forca               text check (forca in ('EXERCITO','MARINHA','AERONAUTICA','MD','OUTRO')),
  fonte_id            smallint not null references fontes(id),
  coletado_em         timestamptz not null default now()
);

-- toda UASG vista em qualquer fonte (Exército ou não)
create table uasgs (
  codigo_uasg       text primary key,
  nome              text not null,
  codigo_orgao      int references orgaos_publicos(codigo_orgao),
  cnpj_orgao        text,
  uf                char(2),
  municipio         text,
  codigo_ibge       int,
  codigo_siorg      text,
  codigo_unidade_polo text,
  nome_unidade_polo text,                       -- ex.: "7º CENTRO DE GESTÃO CONT E FIN DO EXÉRCITO"
  uso_sisg          boolean,
  ativa             boolean,
  pertence_exercito boolean generated always as (codigo_orgao = 52121) stored,
  fonte_id          smallint not null references fontes(id),
  payload_id        bigint references payloads(id),
  coletado_em       timestamptz not null default now(),
  atualizado_fonte_em timestamptz
);
create index on uasgs (pertence_exercito, uf);

create table organizacoes_militares (
  id                 bigserial primary key,
  codigo_uasg        text unique not null references uasgs(codigo_uasg),
  nome_completo      text not null,
  sigla              text,
  regiao_militar     smallint references regioes_militares(numero),
  cma_sigla          text references comandos_militares_area(sigla),
  guarnicao          text,
  uf                 char(2),
  municipio          text,
  situacao_cadastral text,
  -- como RM/CMA foi atribuída (a fonte oficial de UASG não informa RM)
  metodo_vinculo_rm  text not null default 'PENDENTE'
                     check (metodo_vinculo_rm in ('VALIDADO_MANUAL','INFERIDO_UF','INFERIDO_POLO_CGCFEX','PENDENTE')),
  validado_por       text,
  validado_em        timestamptz,
  criado_em          timestamptz not null default now()
);

-- tabela de correspondência auditável (nomenclaturas, siglas, aliases)
create table om_aliases (
  id          bigserial primary key,
  om_id       bigint not null references organizacoes_militares(id) on delete cascade,
  alias       text not null,
  origem      text not null,          -- 'NOME_UASG_COMPRAS','NOME_UNIDADE_PNCP','MANUAL'
  criado_em   timestamptz not null default now(),
  unique (om_id, alias)
);

-- ---------------------------------------------------------------------
-- 2. Fornecedores
-- ---------------------------------------------------------------------
create table fornecedores (
  ni            text primary key,        -- CNPJ/CPF (somente dígitos)
  razao_social  text not null,
  tipo_pessoa   char(2),
  fonte_id      smallint not null references fontes(id),
  coletado_em   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 3. Processos de compra (pregões / contratações)
-- ---------------------------------------------------------------------
create table processos_compra (
  id_compra                 text primary key,     -- id Compras.gov.br (ex.: 16017105900432024)
  numero_controle_pncp      text unique,          -- 00394452000103-1-020181/2024
  codigo_uasg               text not null references uasgs(codigo_uasg),
  numero_compra             text not null,
  ano_compra                smallint not null,
  modalidade_codigo         text,
  modalidade_nome           text,
  srp                       boolean,
  criterio_julgamento       text,
  amparo_legal              text,
  processo_administrativo   text,
  objeto                    text,
  situacao                  text,
  valor_estimado            numeric(18,2),
  valor_homologado          numeric(18,2),
  data_publicacao           date,
  data_abertura_propostas   timestamptz,
  data_encerramento_propostas timestamptz,
  link_oficial              text,
  fonte_id                  smallint not null references fontes(id),
  payload_id                bigint references payloads(id),
  coletado_em               timestamptz not null default now(),
  atualizado_fonte_em       timestamptz
);
create index on processos_compra (codigo_uasg, ano_compra);

-- ---------------------------------------------------------------------
-- 4. Atas de Registro de Preços
-- ---------------------------------------------------------------------
create table atas_registro_precos (
  -- chave própria: número de controle PNCP quando existe; senão
  -- 'SIASG:<uasg>:<numero_ata>:<compra>/<ano>' (atas ainda não publicadas no PNCP)
  chave_ata                 text primary key,
  numero_controle_pncp_ata  text unique,          -- 00394452000103-1-020829/2025-000001 (pode faltar)
  publicada_pncp            boolean generated always as (numero_controle_pncp_ata is not null) stored,
  numero_ata                text not null,        -- formato Compras: 00032/2025 (PNCP usa "32")
  codigo_uasg_gerenciadora  text not null references uasgs(codigo_uasg),
  id_compra                 text references processos_compra(id_compra),
  numero_controle_pncp_compra text,
  numero_compra             text,
  ano_compra                smallint,
  modalidade_codigo         text,
  modalidade_nome           text,
  objeto                    text,
  data_assinatura           date,
  data_publicacao_pncp      date,
  vigencia_inicio           date,
  vigencia_fim              date,
  valor_total               numeric(18,2),
  quantidade_itens          int,
  status_fonte              text,                 -- texto cru da fonte
  cancelada                 boolean not null default false,
  data_cancelamento         date,
  excluida_fonte            boolean not null default false,
  possibilidade_adesao_pncp boolean,              -- PNCP 'possibilidadeAdesao' (pode ser nulo)
  link_ata_pncp             text,
  link_compra_pncp          text,
  fonte_id                  smallint not null references fontes(id),
  payload_id                bigint references payloads(id),
  coletado_em               timestamptz not null default now(),
  atualizado_fonte_em       timestamptz
);
create index on atas_registro_precos (codigo_uasg_gerenciadora);
create index on atas_registro_precos (vigencia_fim);
create index on atas_registro_precos (numero_controle_pncp_compra);
create index on atas_registro_precos (ano_compra, numero_compra);

create table itens_atas (
  id                         bigserial primary key,
  chave_ata                  text not null references atas_registro_precos(chave_ata) on delete cascade,
  numero_item                text not null,       -- '00001'
  tipo_item                  text,                -- Material / Serviço
  codigo_item_catalogo       bigint,              -- CATMAT/CATSER
  codigo_pdm                 int,
  nome_pdm                   text,
  descricao                  text,
  unidade_fornecimento       text,
  marca                      text,
  modelo                     text,
  ni_fornecedor              text references fornecedores(ni),
  classificacao_fornecedor   text,
  quantidade_homologada_item numeric(18,4),       -- total do item na compra
  quantidade_registrada      numeric(18,4),       -- qtd homologada para este fornecedor (vencedor)
  valor_unitario             numeric(18,4),
  valor_total                numeric(18,2),
  maximo_adesao_fonte        numeric(18,4),       -- campo 'maximoAdesao' (frequentemente 0 = não informado)
  quantidade_empenhada_fonte numeric(18,4),       -- campo 'quantidadeEmpenhada' (idem)
  excluido_fonte             boolean not null default false,
  fonte_id                   smallint not null references fontes(id),
  payload_id                 bigint references payloads(id),
  coletado_em                timestamptz not null default now(),
  atualizado_fonte_em        timestamptz,
  unique (chave_ata, numero_item)
);
create index on itens_atas (codigo_item_catalogo);
create index on itens_atas (ni_fornecedor);

-- 3_consultarUnidadesItem — gerenciadora e participantes por item,
-- com limites e saldo de adesões INFORMADOS PELA FONTE
create table unidades_itens_ata (
  item_id                      bigint not null references itens_atas(id) on delete cascade,
  codigo_uasg                  text not null references uasgs(codigo_uasg),
  tipo_unidade                 text not null,    -- GERENCIADORA / PARTICIPANTE (texto da fonte)
  quantidade_registrada        numeric(18,4),
  aceita_adesao                boolean,
  qtd_limite_adesao            numeric(18,4),
  qtd_limite_informado_compra  numeric(18,4),
  saldo_adesoes_fonte          numeric(18,4),
  saldo_remanejamento_empenho_fonte numeric(18,4),
  fonte_id                     smallint not null references fontes(id),
  payload_id                   bigint references payloads(id),
  coletado_em                  timestamptz not null default now(),
  atualizado_fonte_em          timestamptz,
  primary key (item_id, codigo_uasg)
);

-- ---------------------------------------------------------------------
-- 5. Adesões (caronas) — estágio AUTORIZAÇÃO (5_consultarAdesoesItem)
-- ---------------------------------------------------------------------
create table adesoes (
  id                        bigserial primary key,
  item_id                   bigint not null references itens_atas(id) on delete cascade,
  codigo_uasg_aderente      text not null references uasgs(codigo_uasg),
  data_aprovacao            timestamptz not null,
  quantidade_aprovada       numeric(18,4) not null,
  -- estágio declarado: esta tabela só contém AUTORIZAÇÕES aprovadas pelo gerenciador
  estagio                   text not null default 'AUTORIZADA' check (estagio = 'AUTORIZADA'),
  -- campos que a fonte NÃO fornece hoje (mantidos nulos, nunca inventados)
  data_solicitacao          timestamptz,
  quantidade_solicitada     numeric(18,4),
  fonte_id                  smallint not null references fontes(id),
  payload_id                bigint references payloads(id),
  coletado_em               timestamptz not null default now(),
  unique (item_id, codigo_uasg_aderente, data_aprovacao, quantidade_aprovada)
);
create index on adesoes (codigo_uasg_aderente);
create index on adesoes (data_aprovacao);

-- ---------------------------------------------------------------------
-- 6. Contratos (PNCP) — estágio CONTRATAÇÃO
-- ---------------------------------------------------------------------
create table contratos (
  numero_controle_pncp      text primary key,     -- 00394452000103-2-000201/2026
  numero_controle_pncp_ata  text,                 -- sem FK: a ata pode ser de outro órgão ainda não coletado
  numero_controle_pncp_compra text,
  fruto_adesao              boolean,
  codigo_uasg               text not null references uasgs(codigo_uasg),
  ni_fornecedor             text references fornecedores(ni),
  numero_contrato_empenho   text,
  tipo_contrato             text,
  categoria                 text,
  objeto                    text,
  processo                  text,
  valor_inicial             numeric(18,2),
  valor_global              numeric(18,2),
  valor_acumulado           numeric(18,2),
  data_assinatura           date,
  vigencia_inicio           date,
  vigencia_fim              date,
  fonte_id                  smallint not null references fontes(id),
  payload_id                bigint references payloads(id),
  coletado_em               timestamptz not null default now(),
  atualizado_fonte_em       timestamptz
);
create index on contratos (numero_controle_pncp_ata);
create index on contratos (codigo_uasg);
create index on contratos (ni_fornecedor);

create table itens_contratos (
  id                     bigserial primary key,
  numero_controle_pncp   text not null references contratos(numero_controle_pncp) on delete cascade,
  numero_item            text,
  codigo_item_catalogo   bigint,
  descricao              text,
  quantidade             numeric(18,4),
  valor_unitario         numeric(18,4),
  valor_total            numeric(18,2),
  fonte_id               smallint not null references fontes(id),
  payload_id             bigint references payloads(id),
  coletado_em            timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 7. Empenhos — 4_consultarEmpenhosSaldoItem (estrutura a confirmar)
--    Guarda-se o registro bruto + campos normalizados quando identificáveis.
--    Só entra no saldo se vinculado a ata+item (regra nº 6 do prompt).
-- ---------------------------------------------------------------------
create table empenhos (
  id                       bigserial primary key,
  chave_ata                text references atas_registro_precos(chave_ata),
  item_id                  bigint references itens_atas(id),
  codigo_uasg              text references uasgs(codigo_uasg),
  numero_empenho           text,
  data_empenho             date,
  quantidade_empenhada     numeric(18,4),
  valor_empenhado          numeric(18,2),
  vinculo_item_confirmado  boolean not null default false,
  bruto                    jsonb not null,
  fonte_id                 smallint not null references fontes(id),
  payload_id               bigint references payloads(id),
  coletado_em              timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 8. Documentos (links oficiais)
-- ---------------------------------------------------------------------
create table documentos (
  id             bigserial primary key,
  entidade       text not null check (entidade in ('COMPRA','ATA','CONTRATO')),
  chave          text not null,                 -- numero controle PNCP
  tipo           text not null,                 -- EDITAL, TERMO_REFERENCIA, ATA, ADITIVO, APOSTILAMENTO...
  titulo         text,
  url            text not null,
  data_publicacao date,
  fonte_id       smallint not null references fontes(id),
  coletado_em    timestamptz not null default now(),
  unique (entidade, chave, url)
);

-- ---------------------------------------------------------------------
-- 9. Classificação por tipo de despesa
-- ---------------------------------------------------------------------
create table categorias (
  id       serial primary key,
  grupo    text not null check (grupo in ('AQUISICAO','MANUTENCAO','SERVICOS','OUTROS')),
  nome     text not null,
  unique (grupo, nome)
);
create table regras_classificacao (
  id            serial primary key,
  categoria_id  int not null references categorias(id),
  tipo          text not null check (tipo in ('PDM','CATSER','REGEX_DESCRICAO','REGEX_OBJETO')),
  valor         text not null,
  prioridade    int not null default 100
);
create table classificacao_itens (
  item_id       bigint primary key references itens_atas(id) on delete cascade,
  categoria_id  int not null references categorias(id),
  metodo        text not null check (metodo in ('AUTOMATICO','MANUAL')),
  regra_id      int references regras_classificacao(id),
  definido_por  text,
  definido_em   timestamptz not null default now()
);
create table historico_classificacao (
  id            bigserial primary key,
  item_id       bigint not null,
  categoria_anterior int,
  categoria_nova     int not null,
  metodo        text not null,
  alterado_por  text,
  alterado_em   timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 10. Históricos (vigência e saldos) — alimentados por trigger
-- ---------------------------------------------------------------------
create table historico_vigencia (
  id                       bigserial primary key,
  chave_ata                text not null,
  vigencia_fim_anterior    date,
  vigencia_fim_nova        date,
  cancelada_anterior       boolean,
  cancelada_nova           boolean,
  registrado_em            timestamptz not null default now()
);
create table historico_saldos (
  id                 bigserial primary key,
  item_id            bigint not null,
  codigo_uasg        text not null,
  saldo_adesoes_anterior numeric(18,4),
  saldo_adesoes_novo     numeric(18,4),
  registrado_em      timestamptz not null default now()
);

create or replace function trg_hist_vigencia() returns trigger language plpgsql as $$
begin
  if (old.vigencia_fim is distinct from new.vigencia_fim) or (old.cancelada is distinct from new.cancelada) then
    insert into historico_vigencia(chave_ata, vigencia_fim_anterior, vigencia_fim_nova, cancelada_anterior, cancelada_nova)
    values (new.chave_ata, old.vigencia_fim, new.vigencia_fim, old.cancelada, new.cancelada);
  end if;
  return new;
end $$;
create trigger atas_hist_vig after update on atas_registro_precos
  for each row execute function trg_hist_vigencia();

create or replace function trg_hist_saldo() returns trigger language plpgsql as $$
begin
  if old.saldo_adesoes_fonte is distinct from new.saldo_adesoes_fonte then
    insert into historico_saldos(item_id, codigo_uasg, saldo_adesoes_anterior, saldo_adesoes_novo)
    values (new.item_id, new.codigo_uasg, old.saldo_adesoes_fonte, new.saldo_adesoes_fonte);
  end if;
  return new;
end $$;
create trigger unid_hist_saldo after update on unidades_itens_ata
  for each row execute function trg_hist_saldo();

create or replace function trg_hist_classif() returns trigger language plpgsql as $$
begin
  insert into historico_classificacao(item_id, categoria_anterior, categoria_nova, metodo, alterado_por)
  values (new.item_id, case when tg_op='UPDATE' then old.categoria_id end, new.categoria_id, new.metodo, new.definido_por);
  return new;
end $$;
create trigger classif_hist after insert or update on classificacao_itens
  for each row execute function trg_hist_classif();

-- ---------------------------------------------------------------------
-- 11. Usuários, perfis, alertas, auditoria
-- ---------------------------------------------------------------------
create table perfis (
  usuario_id   uuid primary key,              -- = auth.users.id no Supabase
  nome         text,
  email        text unique,
  perfil       text not null check (perfil in ('ADMINISTRADOR','GESTOR','CONSULTA')) default 'CONSULTA',
  ativo        boolean not null default true,
  criado_em    timestamptz not null default now()
);
create table permissoes (
  usuario_id   uuid references perfis(usuario_id) on delete cascade,
  recurso      text not null,                -- 'RELATORIOS','EXPORTACAO','CLASSIFICACAO','SYNC_MANUAL'
  escopo       jsonb,                        -- ex.: {"rm":[8,12]}
  primary key (usuario_id, recurso)
);
create table alertas (
  id                       bigserial primary key,
  chave_ata                text not null references atas_registro_precos(chave_ata) on delete cascade,
  marco                    text not null check (marco in ('D90','D60','D30','D15','D7','VENCIDA')),
  gerado_em                timestamptz not null default now(),
  lido_por                 uuid[],
  unique (chave_ata, marco)
);
create table auditoria (
  id          bigserial primary key,
  usuario_id  uuid,
  acao        text not null,
  entidade    text,
  chave       text,
  detalhes    jsonb,
  criado_em   timestamptz not null default now()
);

-- ===== 202611120002_views.sql =====
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

-- ===== 202611120003_seed_referencia.sql =====
set search_path = radar, public;

insert into comandos_militares_area values
 ('CMA','Comando Militar da Amazônia'),
 ('CMN','Comando Militar do Norte'),
 ('CMNE','Comando Militar do Nordeste'),
 ('CMO','Comando Militar do Oeste'),
 ('CMP','Comando Militar do Planalto'),
 ('CML','Comando Militar do Leste'),
 ('CMSE','Comando Militar do Sudeste'),
 ('CMS','Comando Militar do Sul');

-- Estrutura de referência das 12 RM. Deve ser revisada pelo administrador
-- (a API de UASG não informa RM; ver organizacoes_militares.metodo_vinculo_rm).
insert into regioes_militares values
 (1,'1ª Região Militar','CML','Rio de Janeiro/RJ'),
 (2,'2ª Região Militar','CMSE','São Paulo/SP'),
 (3,'3ª Região Militar','CMS','Porto Alegre/RS'),
 (4,'4ª Região Militar','CML','Belo Horizonte/MG'),
 (5,'5ª Região Militar','CMS','Curitiba/PR'),
 (6,'6ª Região Militar','CMNE','Salvador/BA'),
 (7,'7ª Região Militar','CMNE','Recife/PE'),
 (8,'8ª Região Militar','CMN','Belém/PA'),
 (9,'9ª Região Militar','CMO','Campo Grande/MS'),
 (10,'10ª Região Militar','CMNE','Fortaleza/CE'),
 (11,'11ª Região Militar','CMP','Brasília/DF'),
 (12,'12ª Região Militar','CMA','Manaus/AM');

-- Categorias de despesa (Módulo 8)
insert into categorias (grupo, nome) values
 ('AQUISICAO','Material de consumo'),('AQUISICAO','Material permanente'),('AQUISICAO','Equipamentos'),
 ('AQUISICAO','Ferramentas'),('AQUISICAO','Peças e componentes'),('AQUISICAO','Material de expediente'),
 ('AQUISICAO','Combustíveis e lubrificantes'),('AQUISICAO','Material de construção'),
 ('AQUISICAO','Material de informática'),('AQUISICAO','Material de saúde'),('AQUISICAO','Material de limpeza'),
 ('AQUISICAO','Gêneros alimentícios'),('AQUISICAO','Mobiliário'),('AQUISICAO','Veículos e máquinas'),
 ('MANUTENCAO','Manutenção de veículos'),('MANUTENCAO','Manutenção de máquinas pesadas'),
 ('MANUTENCAO','Manutenção de equipamentos'),('MANUTENCAO','Manutenção elétrica'),
 ('MANUTENCAO','Manutenção hidráulica'),('MANUTENCAO','Manutenção predial'),
 ('MANUTENCAO','Manutenção de equipamentos de engenharia'),('MANUTENCAO','Serviços mecânicos'),
 ('MANUTENCAO','Serviços de soldagem'),('MANUTENCAO','Serviços de usinagem'),
 ('MANUTENCAO','Fornecimento de peças'),('MANUTENCAO','Pneus e acessórios'),
 ('SERVICOS','Serviços de engenharia'),('SERVICOS','Serviços de transporte'),('SERVICOS','Serviços de locação'),
 ('SERVICOS','Serviços de tecnologia'),('SERVICOS','Serviços de limpeza'),('SERVICOS','Serviços de segurança'),
 ('SERVICOS','Serviços administrativos'),('SERVICOS','Serviços técnicos especializados'),
 ('SERVICOS','Serviços de mão de obra'),
 ('OUTROS','Obras'),('OUTROS','Obras de engenharia'),('OUTROS','Consultorias'),('OUTROS','Capacitação'),
 ('OUTROS','Serviços especializados'),('OUTROS','Outras categorias');

-- Regras iniciais por descrição/PDM (aplicadas em ordem de prioridade; editáveis)
insert into regras_classificacao (categoria_id, tipo, valor, prioridade)
select c.id, r.tipo, r.valor, r.prio from (values
 ('Pneus e acessórios','REGEX_DESCRICAO','\m(PNEU|CAMARA DE AR|CÂMARA DE AR)',10),
 ('Fornecimento de peças','REGEX_DESCRICAO','\m(PE[ÇC]A|FILTRO (DE )?(OLEO|ÓLEO|AR|COMBUST)|PASTILHA|ROLAMENTO|CORREIA|JUNTA)',20),
 ('Manutenção de máquinas pesadas','REGEX_DESCRICAO','MANUTEN.*(RETROESCAVADEIRA|MOTONIVELADORA|ESCAVADEIRA|TRATOR|ROLO COMPACTADOR|MAQUINA PESADA|MÁQUINA PESADA)',15),
 ('Manutenção de veículos','REGEX_DESCRICAO','MANUTEN.*VE[IÍ]CUL',16),
 ('Manutenção predial','REGEX_DESCRICAO','MANUTEN.*(PREDIAL|EDIFICA|IM[OÓ]VE)',17),
 ('Manutenção de equipamentos','REGEX_DESCRICAO','MANUTEN',60),
 ('Combustíveis e lubrificantes','REGEX_DESCRICAO','\m(GASOLINA|[OÓ]LEO DIESEL|DIESEL|ETANOL|LUBRIFICANTE|GRAXA|[OÓ]LEO LUBRIF)',10),
 ('Material de construção','REGEX_DESCRICAO','\m(CIMENTO|AREIA|BRITA|TIJOLO|A[ÇC]O CA-?[56]0|VERGALH|ARGAMASSA|TUBO DE CONCRETO|MADEIRA|TINTA)',30),
 ('Material de saúde','REGEX_DESCRICAO','\m(MG|ML|COMPRIMIDO|AMPOLA|SERINGA|LUVA (CIRURG|PROCED)|CATETER|GAZE|DIPIRONA|DICLOFENACO|AMOXICILINA)\M',40),
 ('Gêneros alimentícios','REGEX_DESCRICAO','\m(ARROZ|FEIJ[AÃ]O|CARNE|FRANGO|LEITE|A[ÇC][UÚ]CAR|CAF[EÉ]|MACARR|FARINHA|[OÓ]LEO DE SOJA|FRUTA|HORTALI)',40),
 ('Material de limpeza','REGEX_DESCRICAO','\m(DETERGENTE|DESINFETANTE|SAB[AÃ]O|[AÁ]GUA SANIT|VASSOURA|PAPEL HIGI|SACO DE LIXO)',40),
 ('Material de expediente','REGEX_DESCRICAO','\m(PAPEL A4|CANETA|GRAMPEADOR|CLIPS|PASTA|ENVELOPE|TONER|CARTUCHO)',45),
 ('Material de informática','REGEX_DESCRICAO','\m(COMPUTADOR|NOTEBOOK|MONITOR|TECLADO|MOUSE|SWITCH|ROTEADOR|SSD|HD EXTERNO|IMPRESSORA)',35),
 ('Mobiliário','REGEX_DESCRICAO','\m(CADEIRA|MESA|ARM[AÁ]RIO|ESTANTE|ARQUIVO DE A[ÇC]O|SOF[AÁ])',45),
 ('Serviços de tecnologia','REGEX_DESCRICAO','\m(TELEFONIA|LICEN[ÇC]A DE (USO|SOFTWARE)|INTERNET|LINK DE DADOS|CABEAMENTO|IMAGENS? (DE )?SAT)',30),
 ('Serviços de limpeza','REGEX_DESCRICAO','(LIMPEZA|DESINSETIZA|DEDETIZA|CONSERVA[ÇC][AÃ]O)',30),
 ('Serviços de transporte','REGEX_DESCRICAO','(TRANSPORTE|FRETE|PASSAGE[MN]S? A[EÉ]RE)',30),
 ('Serviços de locação','REGEX_DESCRICAO','\mLOCA[ÇC][AÃ]O',30),
 ('Serviços de engenharia','REGEX_DESCRICAO','SERVI[ÇC]OS? (COMUNS )?DE ENGENHARIA',25)
) as r(cat,tipo,valor,prio)
join categorias c on c.nome = r.cat;

-- ===== 202611120004_fila_coleta.sql =====
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

-- ===== 202611120005_seguranca.sql =====
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

-- ===== 202611120006_classificacao.sql =====
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

-- ===== 202611120007_api_views.sql =====
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

-- ===== 202611120008_supabase_permissoes.sql =====
-- Permissões do schema próprio "radar" no Supabase.
-- service_role (Worker): leitura e escrita (ignora RLS por desenho).
-- authenticated: só leitura, filtrada pelas políticas RLS da migração 005.
-- anon: nada.
grant usage on schema radar to service_role, authenticated;
grant all on all tables in schema radar to service_role;
grant all on all sequences in schema radar to service_role;
grant execute on all functions in schema radar to service_role, authenticated;
grant select on all tables in schema radar to authenticated;
alter default privileges in schema radar grant all on tables to service_role;
alter default privileges in schema radar grant all on sequences to service_role;
alter default privileges in schema radar grant select on tables to authenticated;
alter default privileges in schema radar grant execute on functions to service_role, authenticated;

-- Expõe o schema "radar" na API REST (PostgREST), mantendo os padrões do Supabase.
-- Equivale a incluir "radar" em Settings → API → Exposed schemas; confira lá após rodar.
alter role authenticator set pgrst.db_schemas = 'public, graphql_public, radar';
notify pgrst, 'reload config';

-- ===== Primeiro administrador =====
-- 1) Crie o usuário em Authentication → Users.  2) Rode, trocando os valores:
-- insert into radar.perfis(usuario_id, nome, email, perfil)
-- values ('<uuid do usuário>', '<nome>', '<email>', 'ADMINISTRADOR');
