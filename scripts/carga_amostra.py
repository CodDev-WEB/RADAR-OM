#!/usr/bin/env python3
"""
Carga do primeiro conjunto de registros REAIS coletados em 12/11/2026
(dadosabertos.compras.gov.br e pncp.gov.br) no banco RADAR OM.

Gera SQL e envia ao psql. Nenhum valor é inventado: campos ausentes na fonte
ficam NULL. Cada lote é registrado em `payloads` com hash SHA-256.

Uso: python3 carga_amostra.py <dir_raw> | psql -h /tmp -U postgres radar_om
"""
import json, sys, hashlib, re, os

RAW = sys.argv[1] if len(sys.argv) > 1 else 'data/raw'
out = []
def q(v):
    if v is None or v == '': return 'NULL'
    if isinstance(v, bool): return 'true' if v else 'false'
    if isinstance(v, (int, float)): return repr(v)
    return "'" + str(v).replace("'", "''") + "'"
def emit(s): out.append(s)
def payload(fonte, endpoint, params, corpo, coletado):
    s = json.dumps(corpo, ensure_ascii=False, sort_keys=True)
    h = hashlib.sha256(s.encode()).hexdigest()
    emit(f"insert into payloads(fonte_id,endpoint,parametros,http_status,hash_sha256,corpo,coletado_em,sincronizacao_id) "
         f"values ({fonte},{q(endpoint)},{q(json.dumps(params))}::jsonb,200,{q(h)},NULL,{q(coletado)},currval('sincronizacoes_id_seq')) "
         f"on conflict do nothing;")
    return f"(select id from payloads where hash_sha256={q(h)} and endpoint={q(endpoint)})"

RM_POLO = re.compile(r'^(\d{1,2})[ºª°o]?\s*CENTRO DE GEST', re.I)
CMA_DA_RM = {1:'CML',2:'CMSE',3:'CMS',4:'CML',5:'CMS',6:'CMNE',7:'CMNE',8:'CMN',9:'CMO',10:'CMNE',11:'CMP',12:'CMA'}

emit("set search_path = radar, public; begin;")
emit("insert into sincronizacoes(tipo,status,observacoes) values ('BACKFILL','EM_ANDAMENTO','Carga da amostra real coletada em 2026-11-12 via navegador (Etapa 1)');")
emit("""insert into orgaos_publicos(codigo_orgao,nome,sigla,cnpj,codigo_orgao_vinculado,nome_orgao_vinculado,forca,fonte_id)
values (52121,'COMANDO DO EXERCITO','CMDO EX','00394452000103',52000,'MINISTERIO DEFESA','EXERCITO',1) on conflict do nothing;""")

# ---------- UASGs do Exército ----------
uasgs = json.load(open(os.path.join(RAW, 'compras_uasgs_exercito.json')))
pid = payload(1, '/modulo-uasg/1_consultarUasg', {'statusUasg': True, 'cnpjCpfOrgao': '00394452000103'}, uasgs, '2026-11-12T12:31:00Z')
for u in uasgs:
    emit(f"""insert into uasgs(codigo_uasg,nome,codigo_orgao,cnpj_orgao,uf,municipio,codigo_ibge,codigo_siorg,codigo_unidade_polo,nome_unidade_polo,uso_sisg,ativa,fonte_id,payload_id,coletado_em,atualizado_fonte_em)
values ({q(u['codigoUasg'])},{q(u['nomeUasg'])},{u['codigoOrgao']},{q(u['cnpjCpfOrgao'])},{q(u['siglaUf'])},{q(u['nomeMunicipioIbge'])},{q(u['codigoMunicipioIbge'])},{q(u['codigoSiorg'])},{q(str(u['codigoUnidadePolo'] or '') )},{q(u['nomeUnidadePolo'])},{q(u['usoSisg'])},{q(u['statusUasg'])},1,{pid},'2026-11-12T12:31:00Z',{q(u['dataHoraMovimento'])}) on conflict (codigo_uasg) do nothing;""")
    m = RM_POLO.match(u['nomeUnidadePolo'] or '')
    rm = int(m.group(1)) if m and 1 <= int(m.group(1)) <= 12 else None
    metodo = 'INFERIDO_POLO_CGCFEX' if rm else 'PENDENTE'
    emit(f"""insert into organizacoes_militares(codigo_uasg,nome_completo,regiao_militar,cma_sigla,uf,municipio,situacao_cadastral,metodo_vinculo_rm)
values ({q(u['codigoUasg'])},{q(u['nomeUasg'])},{q(rm)},{q(CMA_DA_RM.get(rm))},{q(u['siglaUf'])},{q(u['nomeMunicipioIbge'])},{q('ATIVA' if u['statusUasg'] else 'INATIVA')},{q(metodo)}) on conflict do nothing;""")
    emit(f"insert into om_aliases(om_id,alias,origem) select id,{q(u['nomeUasg'])},'NOME_UASG_COMPRAS' from organizacoes_militares where codigo_uasg={q(u['codigoUasg'])} on conflict do nothing;")

def uasg_externa(codigo, nome, origem):
    """UASG vista numa fonte mas fora do cadastro do Exército: registra SEM marcar como Exército."""
    emit(f"insert into uasgs(codigo_uasg,nome,codigo_orgao,fonte_id) values ({q(codigo)},{q(nome)},NULL,{origem}) on conflict (codigo_uasg) do nothing;")

def fornecedor(ni, nome, fonte):
    if ni: emit(f"insert into fornecedores(ni,razao_social,fonte_id) values ({q(ni)},{q(nome)},{fonte}) on conflict (ni) do nothing;")

def chave(A):
    return A.get('numeroControlePncpAta') or f"SIASG:{A['codigoUnidadeGerenciadora']}:{A['numeroAtaRegistroPreco']}:{A['numeroCompra']}/{A['anoCompra']}"

def ata(A, pid, fonte=1):
    emit(f"""insert into atas_registro_precos(chave_ata,numero_controle_pncp_ata,numero_ata,codigo_uasg_gerenciadora,numero_controle_pncp_compra,numero_compra,ano_compra,modalidade_codigo,modalidade_nome,objeto,data_assinatura,vigencia_inicio,vigencia_fim,valor_total,quantidade_itens,status_fonte,excluida_fonte,link_ata_pncp,link_compra_pncp,fonte_id,payload_id,atualizado_fonte_em)
values ({q(chave(A))},{q(A.get('numeroControlePncpAta'))},{q(A['numeroAtaRegistroPreco'])},{q(A['codigoUnidadeGerenciadora'])},{q(A.get('numeroControlePncpCompra'))},{q(A['numeroCompra'])},{q(int(A['anoCompra']))},{q(A.get('codigoModalidadeCompra'))},{q(A.get('nomeModalidadeCompra'))},{q(A.get('objeto'))},{q((A.get('dataAssinatura') or '')[:10])},{q(A['dataVigenciaInicial'][:10])},{q(A['dataVigenciaFinal'][:10])},{q(A.get('valorTotal'))},{q(A.get('quantidadeItens'))},{q(A.get('statusAta'))},{q(bool(A.get('ataExcluido')))},{q(A.get('linkAtaPNCP'))},{q(A.get('linkCompraPNCP'))},{fonte},{pid},{q(A.get('dataHoraAtualizacao'))})
on conflict (chave_ata) do update set vigencia_fim=excluded.vigencia_fim, valor_total=excluded.valor_total, atualizado_fonte_em=excluded.atualizado_fonte_em;""")

def item(I, pid, ch, fonte=1):
    fornecedor(I.get('niFornecedor'), I.get('nomeRazaoSocialFornecedor'), fonte)
    emit(f"""insert into itens_atas(chave_ata,numero_item,tipo_item,codigo_item_catalogo,codigo_pdm,nome_pdm,descricao,ni_fornecedor,quantidade_homologada_item,quantidade_registrada,valor_unitario,valor_total,maximo_adesao_fonte,quantidade_empenhada_fonte,excluido_fonte,fonte_id,payload_id,atualizado_fonte_em)
values ({q(ch)},{q(I['numeroItem'])},{q(I.get('tipoItem'))},{q(I.get('codigoItem'))},{q(I.get('codigoPdm'))},{q(I.get('nomePdm'))},{q(I.get('descricaoItem'))},{q(I.get('niFornecedor'))},{q(I.get('quantidadeHomologadaItem'))},{q(I.get('quantidadeHomologadaVencedor'))},{q(I.get('valorUnitario'))},{q(I.get('valorTotal'))},{q(I.get('maximoAdesao'))},{q(I.get('quantidadeEmpenhada'))},{q(bool(I.get('itemExcluido')))},{fonte},{pid},{q(I.get('dataHoraAtualizacao'))})
on conflict (chave_ata,numero_item) do nothing;""")

# ---------- 8º BEC (UASG 160171): atas + itens 2025 ----------
b = json.load(open(os.path.join(RAW, 'compras_8bec_160171.json')))
atas = [dict(zip(b['AK'], r)) for r in b['atas']]
itens = [dict(zip(b['IK'], r)) for r in b['itens']]
pa = payload(1, '/modulo-arp/1_consultarARP', {'codigoUnidadeGerenciadora': '160171', 'janelas': '2023..2026'}, b['atas'], b['coletadoEm'])
pi = payload(1, '/modulo-arp/2_consultarARPItem', {'codigoUnidadeGerenciadora': '160171', 'vigenciaInicial': '2025'}, b['itens'], b['coletadoEm'])
vistos = {}
for A in atas:
    k = chave(A)
    if k in vistos: continue          # duplicidade na fonte (600 registros → chaves únicas)
    vistos[k] = A; ata(A, pa)
# itens: casam pela ata PNCP; itens sem PNCP casam por (uasg, numero_ata) — ambíguo se houver 2 compras
por_pncp = {A['numeroControlePncpAta']: k for k, A in vistos.items() if A['numeroControlePncpAta']}
por_num = {}
for k, A in vistos.items(): por_num.setdefault(A['numeroAtaRegistroPreco'], []).append(k)
sem_vinculo = 0
for I in itens:
    k = por_pncp.get(I['numeroControlePncpAta']) if I['numeroControlePncpAta'] else None
    if not k and len(por_num.get(I['numeroAtaRegistroPreco'], [])) == 1: k = por_num[I['numeroAtaRegistroPreco']][0]
    if k: item(I, pi, k)
    else: sem_vinculo += 1
print(f"-- itens sem ata vinculável: {sem_vinculo}", file=sys.stderr)

# ---------- Validação: atas com adesões (Cmdo 10ª RM e 1º CGEO) ----------
v = json.load(open(os.path.join(RAW, 'compras_validacao_adesoes.json')))
for cpncp, d in v.items():
    if cpncp == 'fin': continue
    A = d['ata']['resultado'][0]
    p1 = payload(1, '/modulo-arp/1.1_consultarARP_Id', {'numeroControlePncpAta': cpncp}, d['ata'], '2026-11-12T12:38:00Z')
    ata(A, p1)
    p2 = payload(1, '/modulo-arp/2.1_consultarARPItem_Id', {'numeroControlePncpAta': cpncp}, d['itens'], '2026-11-12T12:38:00Z')
    for I in d['itens']['resultado']: item(I, p2, chave(A))
    p3 = payload(1, '/modulo-arp/3_consultarUnidadesItem', {'numeroControlePncpAta': cpncp}, d['unid'], '2026-11-12T12:38:00Z')
    for U in d['unid']:
        emit(f"""insert into unidades_itens_ata(item_id,codigo_uasg,tipo_unidade,quantidade_registrada,aceita_adesao,qtd_limite_adesao,qtd_limite_informado_compra,saldo_adesoes_fonte,saldo_remanejamento_empenho_fonte,fonte_id,payload_id,atualizado_fonte_em)
select i.id,{q(U['codigoUnidade'])},{q(U['tipoUnidade'])},{q(U['quantidadeRegistrada'])},{q(U['aceitaAdesao'])},{q(U['qtdLimiteAdesao'])},{q(U['qtdLimiteInformadoCompra'])},{q(U['saldoAdesoes'])},{q(U['saldoRemanejamentoEmpenho'])},1,{p3},{q(U['dataHoraAtualizacao'])}
from itens_atas i where i.chave_ata={q(cpncp)} and i.numero_item={q(U['numeroItem'])} on conflict do nothing;""")
    p5 = payload(1, '/modulo-arp/5_consultarAdesoesItem', {'numeroControlePncpAta': cpncp}, d['ades'], '2026-11-12T12:38:00Z')
    for D in d['ades']:
        cod, nome = [s.strip() for s in D['unidadeNaoParticipante'].split(' - ', 1)]
        uasg_externa(cod, nome, 1)
        emit(f"""insert into adesoes(item_id,codigo_uasg_aderente,data_aprovacao,quantidade_aprovada,fonte_id,payload_id)
select i.id,{q(cod)},{q(D['dataAprovacaoAnalise'])},{q(D['quantidadeAprovadaAdesao'])},1,{p5}
from itens_atas i where i.chave_ata={q(cpncp)} and i.numero_item={q(D['_item'])} on conflict do nothing;""")

# ---------- PNCP: contratos do Exército vinculados a atas ----------
c = json.load(open(os.path.join(RAW, 'pncp_contratos_exercito_2026_vinculados_ata.json')))
pc = payload(2, '/v1/contratos', {'cnpjOrgao': '00394452000103', 'dataInicial': '20260101', 'dataFinal': '20261112', 'paginas': f"1..{c['pages']}"}, c['rows'], c['coletadoEm'])
for r in c['rows']:
    R = dict(zip(c['K'], r))
    uasg_externa(R['codigoUnidade'], R['nomeUnidade'], 2)
    fornecedor(R['niFornecedor'], R['nomeFornecedor'], 2)
    emit(f"""insert into contratos(numero_controle_pncp,numero_controle_pncp_ata,numero_controle_pncp_compra,fruto_adesao,codigo_uasg,ni_fornecedor,numero_contrato_empenho,tipo_contrato,categoria,objeto,processo,valor_inicial,valor_global,data_assinatura,vigencia_inicio,vigencia_fim,fonte_id,payload_id,atualizado_fonte_em)
values ({q(R['numeroControlePNCP'])},{q(R['numeroControlePncpAta'])},{q(R['numeroControlePncpCompra'])},{q(R['frutoAdesao'])},{q(R['codigoUnidade'])},{q(R['niFornecedor'])},{q(R['numeroContratoEmpenho'])},{q(R['tipoContrato'])},{q(R['categoria'])},{q(R['objeto'])},{q(R['processo'])},{q(R['valorInicial'])},{q(R['valorGlobal'])},{q(R['dataAssinatura'])},{q(R['vigenciaInicio'])},{q(R['vigenciaFim'])},2,{pc},{q(R['dataAtualizacaoGlobal'])}) on conflict do nothing;""")

emit("""update sincronizacoes set status='SUCESSO', finalizada_em=now(),
 reg_novos=(select count(*) from atas_registro_precos)+(select count(*) from itens_atas)+(select count(*) from adesoes)+(select count(*) from contratos)
 where id=currval('sincronizacoes_id_seq');""")
emit("commit;")
print('\n'.join(out))
