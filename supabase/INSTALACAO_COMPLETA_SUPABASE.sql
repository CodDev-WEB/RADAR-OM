-- RADAR OM — instalação completa (cole no SQL Editor do Supabase e execute uma vez, em banco VAZIO).
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

-- ===== 202611120009_ingestao_sql.sql =====
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

-- ===== 202611120010_coleta_ajustes.sql =====
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

-- ===== 202611120011_prioridade_profundidade.sql =====
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

-- ===== Primeiro administrador =====
-- 1) Crie o usuário em Authentication → Users.  2) Rode, trocando os valores:
-- insert into radar.perfis(usuario_id, nome, email, perfil)
-- values ('<uuid do usuário>', '<nome>', '<email>', 'ADMINISTRADOR');
