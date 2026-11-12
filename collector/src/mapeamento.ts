// Conversão resposta-de-API → linhas do banco. Campos ausentes viram null; nada é inventado.
type R = Record<string, any>
const d10 = (v: unknown) => (typeof v === 'string' && v.length >= 10 ? v.slice(0, 10) : null)
const nz = <T>(v: T) => (v === '' || v === undefined ? null : v)

export function chaveAta(a: R): string {
  return a.numeroControlePncpAta ||
    `SIASG:${a.codigoUnidadeGerenciadora}:${a.numeroAtaRegistroPreco}:${a.numeroCompra}/${a.anoCompra}`
}

export const mapear = {
  uasg: (u: R, payloadId: number | null) => ({
    codigo_uasg: String(u.codigoUasg), nome: u.nomeUasg, codigo_orgao: u.codigoOrgao ?? null,
    cnpj_orgao: nz(u.cnpjCpfOrgao), uf: nz(u.siglaUf), municipio: nz(u.nomeMunicipioIbge),
    codigo_ibge: u.codigoMunicipioIbge ?? null, codigo_siorg: nz(u.codigoSiorg),
    codigo_unidade_polo: u.codigoUnidadePolo ? String(u.codigoUnidadePolo) : null,
    nome_unidade_polo: nz(u.nomeUnidadePolo), uso_sisg: u.usoSisg ?? null, ativa: u.statusUasg ?? null,
    fonte_id: 1, payload_id: payloadId, coletado_em: new Date().toISOString(),
    atualizado_fonte_em: nz(u.dataHoraMovimento),
  }),

  /** RM inferida do polo CGCFEx (oficial, mas a correspondência nº CGCFEx = nº RM é inferência a validar) */
  omDeUasg: (u: R) => {
    const m = /^(\d{1,2})[ºª°o]?\s*CENTRO DE GEST/i.exec(u.nomeUnidadePolo ?? '')
    const rm = m && +m[1] >= 1 && +m[1] <= 12 ? +m[1] : null
    const cma: Record<number, string> = { 1: 'CML', 2: 'CMSE', 3: 'CMS', 4: 'CML', 5: 'CMS', 6: 'CMNE', 7: 'CMNE', 8: 'CMN', 9: 'CMO', 10: 'CMNE', 11: 'CMP', 12: 'CMA' }
    return {
      codigo_uasg: String(u.codigoUasg), nome_completo: u.nomeUasg, regiao_militar: rm,
      cma_sigla: rm ? cma[rm] : null, uf: nz(u.siglaUf), municipio: nz(u.nomeMunicipioIbge),
      situacao_cadastral: u.statusUasg ? 'ATIVA' : 'INATIVA',
      metodo_vinculo_rm: rm ? 'INFERIDO_POLO_CGCFEX' : 'PENDENTE',
    }
  },

  ataCompras: (a: R, payloadId: number | null) => ({
    chave_ata: chaveAta(a), numero_controle_pncp_ata: nz(a.numeroControlePncpAta),
    numero_ata: a.numeroAtaRegistroPreco, codigo_uasg_gerenciadora: String(a.codigoUnidadeGerenciadora),
    numero_controle_pncp_compra: nz(a.numeroControlePncpCompra), numero_compra: nz(a.numeroCompra),
    ano_compra: a.anoCompra ? Number(a.anoCompra) : null, modalidade_codigo: nz(a.codigoModalidadeCompra),
    modalidade_nome: nz(a.nomeModalidadeCompra), objeto: nz(a.objeto), data_assinatura: d10(a.dataAssinatura),
    vigencia_inicio: d10(a.dataVigenciaInicial), vigencia_fim: d10(a.dataVigenciaFinal),
    valor_total: a.valorTotal ?? null, quantidade_itens: a.quantidadeItens ?? null, status_fonte: nz(a.statusAta),
    excluida_fonte: !!a.ataExcluido, link_ata_pncp: nz(a.linkAtaPNCP), link_compra_pncp: nz(a.linkCompraPNCP),
    fonte_id: 1, payload_id: payloadId, atualizado_fonte_em: nz(a.dataHoraAtualizacao),
  }),

  /** PNCP complementa: cancelamento e possibilidade de adesão */
  complementoAtaPncp: (a: R) => ({
    numero_controle_pncp_ata: a.numeroControlePNCPAta, cancelada: !!a.cancelado,
    data_cancelamento: d10(a.dataCancelamento), possibilidade_adesao_pncp: a.possibilidadeAdesao ?? null,
    data_publicacao_pncp: d10(a.dataPublicacaoPncp),
  }),

  itemAta: (i: R, chave: string, payloadId: number | null) => ({
    chave_ata: chave, numero_item: i.numeroItem, tipo_item: nz(i.tipoItem),
    codigo_item_catalogo: i.codigoItem ?? null, codigo_pdm: i.codigoPdm ?? null, nome_pdm: nz(i.nomePdm),
    descricao: nz(i.descricaoItem), ni_fornecedor: nz(i.niFornecedor), classificacao_fornecedor: nz(i.classificacaoFornecedor),
    quantidade_homologada_item: i.quantidadeHomologadaItem ?? null, quantidade_registrada: i.quantidadeHomologadaVencedor ?? null,
    valor_unitario: i.valorUnitario ?? null, valor_total: i.valorTotal ?? null,
    maximo_adesao_fonte: i.maximoAdesao ?? null, quantidade_empenhada_fonte: i.quantidadeEmpenhada ?? null,
    excluido_fonte: !!i.itemExcluido, fonte_id: 1, payload_id: payloadId, atualizado_fonte_em: nz(i.dataHoraAtualizacao),
  }),

  unidadeItem: (u: R, itemId: number, payloadId: number | null) => ({
    item_id: itemId, codigo_uasg: String(u.codigoUnidade), tipo_unidade: u.tipoUnidade,
    quantidade_registrada: u.quantidadeRegistrada ?? null, aceita_adesao: u.aceitaAdesao ?? null,
    qtd_limite_adesao: u.qtdLimiteAdesao ?? null, qtd_limite_informado_compra: u.qtdLimiteInformadoCompra ?? null,
    saldo_adesoes_fonte: u.saldoAdesoes ?? null, saldo_remanejamento_empenho_fonte: u.saldoRemanejamentoEmpenho ?? null,
    fonte_id: 1, payload_id: payloadId, atualizado_fonte_em: nz(u.dataHoraAtualizacao),
  }),

  /** "160201 - COMISSAO REGIONAL DE OBRAS/7" → { codigo, nome } */
  separarUnidade(texto: string): { codigo: string; nome: string } {
    const i = texto.indexOf(' - ')
    return i < 0 ? { codigo: texto.trim(), nome: texto.trim() } : { codigo: texto.slice(0, i).trim(), nome: texto.slice(i + 3).trim() }
  },

  adesao: (a: R, itemId: number, payloadId: number | null) => ({
    item_id: itemId, codigo_uasg_aderente: mapear.separarUnidade(a.unidadeNaoParticipante).codigo,
    data_aprovacao: a.dataAprovacaoAnalise, quantidade_aprovada: a.quantidadeAprovadaAdesao,
    fonte_id: 1, payload_id: payloadId,
  }),

  contratoPncp: (c: R, payloadId: number | null) => ({
    numero_controle_pncp: c.numeroControlePNCP, numero_controle_pncp_ata: nz(c.numeroControlePncpAta),
    numero_controle_pncp_compra: nz(c.numeroControlePncpCompra), fruto_adesao: c.frutoAdesao ?? null,
    codigo_uasg: String(c.unidadeOrgao?.codigoUnidade), ni_fornecedor: nz(c.niFornecedor),
    numero_contrato_empenho: nz(c.numeroContratoEmpenho), tipo_contrato: c.tipoContrato?.nome ?? null,
    categoria: c.categoriaProcesso?.nome ?? null, objeto: nz(c.objetoContrato), processo: nz(c.processo),
    valor_inicial: c.valorInicial ?? null, valor_global: c.valorGlobal ?? null, valor_acumulado: c.valorAcumulado ?? null,
    data_assinatura: d10(c.dataAssinatura), vigencia_inicio: d10(c.dataVigenciaInicio), vigencia_fim: d10(c.dataVigenciaFim),
    fonte_id: 2, payload_id: payloadId, atualizado_fonte_em: nz(c.dataAtualizacaoGlobal),
  }),
}
