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
