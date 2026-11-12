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
