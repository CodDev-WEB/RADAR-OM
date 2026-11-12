// Orquestração da sincronização diária (fila persistente, retomável, com orçamento de requisições).
import { ClienteApi, sha256, type LogFn } from './http.js'
import { compras, pncp } from './fontes.js'
import { mapear, chaveAta } from './mapeamento.js'
import type { Armazenamento } from './armazenamento.js'

type Tarefa = { id: number; tarefa: string; chave: Record<string, any>; tentativas: number }
type Contadores = { novos: number; atualizados: number; erros: number }

export interface Contexto {
  db: Armazenamento
  compras: ClienteApi
  pncp: ClienteApi
  log: LogFn
  hoje?: string                    // AAAA-MM-DD (injeção para testes)
}

const dia = (base: string, delta: number) => new Date(Date.parse(base + 'T00:00:00Z') + delta * 86_400_000).toISOString().slice(0, 10)

export class Sincronizador {
  private c: Contadores = { novos: 0, atualizados: 0, erros: 0 }
  private uasgsConhecidas = new Set<string>()
  private orgaosConhecidos = new Set<number>()
  constructor(private x: Contexto, private syncId: number) {}

  get hoje() { return this.x.hoje ?? new Date(Date.now() - 3 * 3600_000).toISOString().slice(0, 10) } // America/Sao_Paulo

  // ---------- início do ciclo (02h00 BRT) ----------
  static async iniciar(x: Contexto, tipo: 'DIARIA' | 'MANUAL' | 'BACKFILL', etapa: (e: string) => void = () => {}): Promise<Sincronizador> {
    etapa('encerrar ciclo anterior ainda aberto')
    await x.db.update('sincronizacoes', 'status=eq.EM_ANDAMENTO', { status: 'FALHA', finalizada_em: new Date().toISOString(), observacoes: `substituída por nova sincronização ${tipo}` })
    etapa('registrar a sincronização (tabela radar.sincronizacoes)')
    const [s] = await x.db.upsert('sincronizacoes', [{ tipo, status: 'EM_ANDAMENTO' }], 'id')
    const sync = new Sincronizador(x, Number(s.id))
    etapa('liberar tarefas presas (função radar.liberar_tarefas_presas)')
    await x.db.rpc('liberar_tarefas_presas', {})
    etapa('consultar o cadastro de UASGs no Compras.gov.br')
    // 1) cadastro oficial de UASGs do Exército (identificação auditável — nunca pelo nome)
    await sync.garantirOrgao(52121)
    for await (const pg of compras.uasgsExercito(x.compras)) {
      const pid = await sync.payload(1, pg)
      await x.db.upsert('uasgs', pg.registros.map((u) => mapear.uasg(u, pid)), 'codigo_uasg')
      await x.db.upsert('organizacoes_militares', pg.registros.map(mapear.omDeUasg), 'codigo_uasg', true)
    }
    etapa('enfileirar as UASGs do Exército (tabela radar.fila_coleta)')
    const eb = await x.db.select('uasgs', 'select=codigo_uasg&pertence_exercito=is.true&ativa=is.true')
    const ontem = dia(sync.hoje, -1)
    await sync.enfileirar([
      { tarefa: 'PNCP_ATAS_ATUALIZACAO', chave: { ini: ontem, fim: sync.hoje }, prioridade: 5 },
      { tarefa: 'PNCP_CONTRATOS_ATUALIZACAO', chave: { ini: ontem, fim: sync.hoje }, prioridade: 5 },
      ...eb.map((u) => ({ tarefa: 'ATAS_UASG', chave: { uasg: u.codigo_uasg }, prioridade: 10 })),
    ], true)
    x.log('INFO', `ciclo ${tipo} iniciado: ${eb.length} UASGs do Exército enfileiradas`)
    return sync
  }

  // ---------- processamento de uma fatia (chamado a cada disparo do cron) ----------
  async processarFatia(maxTarefas = 150): Promise<{ restantes: number }> {
    const lote = await this.x.db.rpc<Tarefa[]>('reservar_tarefas', { p_limite: maxTarefas, p_sync: this.syncId })
    for (const t of lote) {
      try {
        await this.executar(t)
        await this.x.db.update('fila_coleta', `id=eq.${t.id}`, { status: 'OK', ultimo_erro: null, atualizado_em: new Date().toISOString() })
      } catch (e) {
        this.c.erros++
        const espera = Math.min(2 ** t.tentativas * 5, 240)
        await this.x.db.update('fila_coleta', `id=eq.${t.id}`, {
          status: 'ERRO', ultimo_erro: String(e).slice(0, 500),
          proxima_em: new Date(Date.now() + espera * 60_000).toISOString(),
        })
        await this.x.db.upsert('logs_integracao', [{ sincronizacao_id: this.syncId, nivel: 'ERRO', mensagem: String(e).slice(0, 1000), parametros: t.chave, tentativa: t.tentativas }], 'id')
      }
    }
    const pend = await this.x.db.select('fila_coleta', 'select=id&status=in.(PENDENTE,ERRO,EXECUTANDO)&tentativas=lt.6&limit=1')
    await this.fechar(pend.length === 0)
    return { restantes: pend.length }
  }

  private async executar(t: Tarefa) {
    const k = t.chave
    switch (t.tarefa) {
      case 'ATAS_UASG': {
        // atas com fim de vigência de ontem até +3 anos (vigentes e as que acabaram de vencer)
        for await (const pg of compras.atasPorFimVigencia(this.x.compras, k.uasg, dia(this.hoje, -1), dia(this.hoje, 3 * 365))) {
          const pid = await this.payload(1, pg)
          const antes = await this.mapaAtualizacao(pg.registros.map(chaveAta))
          const linhas = pg.registros.map((a) => mapear.ataCompras(a, pid))
          await this.x.db.upsert('atas_registro_precos', linhas, 'chave_ata')
          const mudou = linhas.filter((l) => antes.get(l.chave_ata) !== l.atualizado_fonte_em)
          this.c.novos += linhas.filter((l) => !antes.has(l.chave_ata)).length
          this.c.atualizados += mudou.filter((l) => antes.has(l.chave_ata)).length
          await this.enfileirar(mudou.flatMap((l) => l.numero_controle_pncp_ata ? [
            { tarefa: 'ITENS_ATA', chave: { ata: l.numero_controle_pncp_ata }, prioridade: 20 },
            { tarefa: 'EMPENHOS_ATA', chave: { numeroAta: l.numero_ata, uasg: l.codigo_uasg_gerenciadora, chave: l.chave_ata }, prioridade: 60 },
          ] : []))
        }
        return
      }
      case 'ATA_EXTERNA': {
        for await (const pg of compras.ataPorId(this.x.compras, k.ata)) {
          const pid = await this.payload(1, pg)
          for (const a of pg.registros) await this.garantirUasg(String(a.codigoUnidadeGerenciadora), a.nomeUnidadeGerenciadora)
          await this.x.db.upsert('atas_registro_precos', pg.registros.map((a) => mapear.ataCompras(a, pid)), 'chave_ata')
        }
        await this.enfileirar([{ tarefa: 'ITENS_ATA', chave: { ata: k.ata }, prioridade: 20 }])
        return
      }
      case 'ITENS_ATA': {
        for await (const pg of compras.itensPorAta(this.x.compras, k.ata)) {
          const pid = await this.payload(1, pg)
          const forn = pg.registros.filter((i) => i.niFornecedor).map((i) => ({ ni: i.niFornecedor, razao_social: i.nomeRazaoSocialFornecedor, fonte_id: 1 }))
          await this.x.db.upsert('fornecedores', dedup(forn, 'ni'), 'ni')
          const itens = await this.x.db.upsert('itens_atas', pg.registros.map((i) => mapear.itemAta(i, k.ata, pid)), 'chave_ata,numero_item')
          await this.enfileirar(itens.map((i, n) => ({ tarefa: 'UNIDADES_ITEM', prioridade: 30,
            chave: { itemId: i.id, numeroAta: pg.registros[n].numeroAtaRegistroPreco, uasg: String(pg.registros[n].codigoUnidadeGerenciadora), numeroItem: i.numero_item } })))
        }
        return
      }
      case 'UNIDADES_ITEM': {
        let aceita = false, saldoNovo: unknown = null
        const antes = await this.x.db.select('unidades_itens_ata', `select=saldo_adesoes_fonte&item_id=eq.${k.itemId}&limit=1`)
        for await (const pg of compras.unidadesItem(this.x.compras, k.numeroAta, k.uasg, k.numeroItem)) {
          const pid = await this.payload(1, pg)
          for (const u of pg.registros) await this.garantirUasg(String(u.codigoUnidade), u.nomeUnidade)
          await this.x.db.upsert('unidades_itens_ata', pg.registros.map((u) => mapear.unidadeItem(u, k.itemId, pid)), 'item_id,codigo_uasg')
          aceita ||= pg.registros.some((u) => u.aceitaAdesao)
          saldoNovo = pg.registros[0]?.saldoAdesoes ?? saldoNovo
        }
        // só consulta adesões se o item aceita adesão E (primeira coleta OU o saldo mudou)
        const saldoAntes = antes[0]?.saldo_adesoes_fonte
        if (aceita && (antes.length === 0 || Number(saldoAntes) !== Number(saldoNovo)))
          await this.enfileirar([{ tarefa: 'ADESOES_ITEM', chave: k, prioridade: 40 }], true)
        return
      }
      case 'ADESOES_ITEM': {
        for await (const pg of compras.adesoesItem(this.x.compras, k.numeroAta, k.uasg, k.numeroItem)) {
          const pid = await this.payload(1, pg)
          for (const a of pg.registros) {
            const u = mapear.separarUnidade(a.unidadeNaoParticipante)
            await this.garantirUasg(u.codigo, u.nome)
          }
          const r = await this.x.db.upsert('adesoes', pg.registros.map((a) => mapear.adesao(a, k.itemId, pid)),
            'item_id,codigo_uasg_aderente,data_aprovacao,quantidade_aprovada', true)
          this.c.novos += r.length
        }
        return
      }
      case 'EMPENHOS_ATA': {
        // estrutura de retorno ainda não observada com dados (amostra retornou vazio):
        // guarda bruto e NÃO vincula ao saldo até o mapeamento ser validado
        for await (const pg of compras.empenhosSaldo(this.x.compras, k.numeroAta, k.uasg)) {
          const pid = await this.payload(1, pg)
          await this.x.db.upsert('empenhos', pg.registros.map((e) => ({ chave_ata: k.chave, bruto: e, vinculo_item_confirmado: false, fonte_id: 1, payload_id: pid })), 'id')
        }
        return
      }
      case 'PNCP_CONTRATOS_ATUALIZACAO': {
        for await (const pg of pncp.contratosAtualizados(this.x.pncp, k.ini, k.fim)) {
          const pid = await this.payload(2, pg)
          for (const c of pg.registros) await this.garantirUasg(String(c.unidadeOrgao?.codigoUnidade), c.unidadeOrgao?.nomeUnidade)
          const forn = pg.registros.filter((c) => c.niFornecedor).map((c) => ({ ni: c.niFornecedor, razao_social: c.nomeRazaoSocialFornecedor, fonte_id: 2 }))
          await this.x.db.upsert('fornecedores', dedup(forn, 'ni'), 'ni')
          await this.x.db.upsert('contratos', pg.registros.map((c) => mapear.contratoPncp(c, pid)), 'numero_controle_pncp')
          // contrato fruto de adesão a ata ainda desconhecida (ex.: ata da Marinha) → buscar a ata
          const atas = [...new Set(pg.registros.filter((c) => c.frutoAdesao && c.numeroControlePncpAta).map((c) => c.numeroControlePncpAta as string))]
          if (atas.length) {
            const conhecidas = new Set((await this.x.db.select('atas_registro_precos', `select=numero_controle_pncp_ata&numero_controle_pncp_ata=in.(${atas.map((a) => `"${a}"`).join(',')})`)).map((r) => r.numero_controle_pncp_ata))
            await this.enfileirar(atas.filter((a) => !conhecidas.has(a)).map((a) => ({ tarefa: 'ATA_EXTERNA', chave: { ata: a }, prioridade: 15 })))
          }
        }
        return
      }
      case 'PNCP_ATAS_ATUALIZACAO': {
        for await (const pg of pncp.atasAtualizadas(this.x.pncp, k.ini, k.fim)) {
          await this.payload(2, pg)
          for (const a of pg.registros) {
            const comp = mapear.complementoAtaPncp(a)
            await this.x.db.update('atas_registro_precos', `numero_controle_pncp_ata=eq.${encodeURIComponent(comp.numero_controle_pncp_ata)}`, comp)
          }
        }
        return
      }
      default: throw new Error(`tarefa desconhecida: ${t.tarefa}`)
    }
  }

  // ---------- utilitários ----------
  /** órgão (FK de uasgs) vem do cadastro oficial; se não existir lá, registra só o código */
  async garantirOrgao(codigo: number | null | undefined) {
    if (codigo == null || this.orgaosConhecidos.has(codigo)) return
    const ja = await this.x.db.select('orgaos_publicos', `select=codigo_orgao&codigo_orgao=eq.${codigo}`)
    if (!ja.length) {
      const regs: Record<string, any>[] = []
      for await (const pg of compras.orgao(this.x.compras, codigo)) regs.push(...pg.registros)
      await this.x.db.upsert('orgaos_publicos', regs.length ? regs.map(mapear.orgao)
        : [{ codigo_orgao: codigo, nome: `Órgão ${codigo} (não localizado no cadastro)`, forca: 'OUTRO', fonte_id: 1 }], 'codigo_orgao', true)
    }
    this.orgaosConhecidos.add(codigo)
  }

  /** UASG nunca vista: consulta o cadastro oficial para saber o órgão (Exército? Marinha?) */
  private async garantirUasg(codigo: string, nome?: string) {
    if (!codigo || this.uasgsConhecidas.has(codigo)) return
    const ja = await this.x.db.select('uasgs', `select=codigo_uasg&codigo_uasg=eq.${codigo}`)
    if (!ja.length) {
      let achou = false
      for await (const pg of (async function* (c: ClienteApi) {
        const { corpo } = await c.getJson<any>('/modulo-uasg/1_consultarUasg', { statusUasg: 'true', codigoUasg: codigo })
        yield corpo?.resultado ?? []
      })(this.x.compras)) {
        if (pg.length) {
          for (const u of pg) await this.garantirOrgao(u.codigoOrgao)
          await this.x.db.upsert('uasgs', pg.map((u: any) => mapear.uasg(u, null)), 'codigo_uasg'); achou = true
        }
      }
      if (!achou) await this.x.db.upsert('uasgs', [{ codigo_uasg: codigo, nome: nome ?? codigo, codigo_orgao: null, fonte_id: 1 }], 'codigo_uasg', true)
    }
    this.uasgsConhecidas.add(codigo)
  }

  private async mapaAtualizacao(chaves: string[]) {
    const m = new Map<string, unknown>()
    for (let i = 0; i < chaves.length; i += 100) {
      const lista = chaves.slice(i, i + 100).map((c) => `"${c}"`).join(',')
      for (const r of await this.x.db.select('atas_registro_precos', `select=chave_ata,atualizado_fonte_em&chave_ata=in.(${lista})`))
        m.set(String(r.chave_ata), r.atualizado_fonte_em)
    }
    return m
  }

  private async payload(fonte: number, pg: { endpoint: string; params: Record<string, unknown>; corpoBruto: unknown }) {
    const corpo = JSON.stringify(pg.corpoBruto ?? null)
    const hash = await sha256(corpo)
    const [p] = await this.x.db.upsert('payloads', [{ fonte_id: fonte, endpoint: pg.endpoint, parametros: pg.params, http_status: 200, hash_sha256: hash, corpo: pg.corpoBruto, sincronizacao_id: this.syncId }], 'hash_sha256,endpoint')
    return p ? Number(p.id) : null
  }

  private async enfileirar(t: Array<{ tarefa: string; chave: Record<string, unknown>; prioridade: number }>, reabrir = false) {
    if (!t.length) return
    await this.x.db.upsert('fila_coleta', t.map((x) => ({ ...x, status: 'PENDENTE', tentativas: 0, proxima_em: new Date().toISOString(), sincronizacao_id: this.syncId })), 'tarefa,chave', !reabrir)
  }

  private async fechar(concluiu: boolean) {
    const m = [this.x.compras.metricas, this.x.pncp.metricas]
    await this.x.db.update('sincronizacoes', `id=eq.${this.syncId}`, {
      reg_novos: this.c.novos, reg_atualizados: this.c.atualizados, reg_erros: this.c.erros,
      requisicoes: m.reduce((s, x) => s + x.requisicoes, 0), respostas_429: m.reduce((s, x) => s + x.respostas429, 0),
      ...(concluiu ? { status: this.c.erros ? 'SUCESSO_PARCIAL' : 'SUCESSO', finalizada_em: new Date().toISOString() } : {}),
    })
  }
}

function dedup<T extends Record<string, unknown>>(l: T[], k: string) {
  return [...new Map(l.map((x) => [x[k], x])).values()]
}
