# APS 3 — Dossiê de Arquitetura Viva: Checklist e Acompanhamento da Exportação

**Autor:** Nome Sobrenome
**Projeto:** Assistente de IA para Exportação (Sistema Fiep)
**Funcionalidade crítica:** Geração de checklist e acompanhamento da exportação
**Requisitos relacionados:** RF13 (Resumo de próximos passos), RF14 (Checklist de exportação), RF15 (Roteiro de exportação). Apoio de RF02, RF03, RF04–RF09, RF10 e RF11.

## 1. A funcionalidade

Pequenas indústrias têm dificuldade de entender as exigências aduaneiras. Depois de informar **produto, NCM e país de destino**, o exportador recebe:

1. **Checklist verificável (RF14):** documentos e procedimentos exigidos, cada item com finalidade, emissor, momento de emissão e fonte citada.
2. **Roteiro sequencial (RF15):** o mesmo checklist ordenado em etapas (*Preparação → Documentação → Despacho*), com dependências.
3. **Resumo de próximos passos (RF13):** lista objetiva do que fazer a seguir.
4. **Acompanhamento:** o usuário marca os itens e o sistema calcula o progresso até a conclusão.

É uma funcionalidade crítica porque um checklist incorreto ou fora de ordem pode gerar multa, retenção de carga ou erro fiscal. Por isso o ciclo de vida do checklist é protegido por uma máquina de estados e as fontes são citadas.

A entidade de domínio principal é o **Checklist**, que se liga às classes do diagrama de classes do semestre: `Produto`, `Simulador_exportacao`, `RegraAduaneira`, `RequisitoExportacao`, `RestricaoExportacao`, `DocumentoExportacao` e `FonteNormativa`.

## 2. Estrutura do repositório

```
aps3-nome-sobrenome/
├── docs/
│   ├── architecture/
│   │   ├── workspace.dsl      # C4 nível 2 em Structurizr DSL
│   │   └── adr-0001.md        # ADR 0001
│   └── diagrams/
│       ├── sequencia.mmd
│       ├── atividades.mmd
│       └── estados.mmd
└── README.md
```

## 3. Artefato 1 — Diagrama de Sequência

Convenções do Mermaid usadas aqui:

- `->>` é chamada **síncrona bloqueante**.
- `-)` é chamada **assíncrona** (mensageria), a notação de assíncrono do Mermaid (o `-\>` do enunciado).
- `-->>` é retorno de dados com **DTO**.
- Fragmentos combinados: `alt/else` (dados incompletos, falha de fonte, estado inválido) e `loop` (um item por requisito).

```mermaid
sequenceDiagram
    autonumber
    actor U as Usuário (Exportador)
    participant UI as WebApp (React)
    participant API as ChecklistController
    participant CTX as ContextoService
    participant CS as ChecklistService
    participant DB as ChecklistRepository
    participant SIS as SiscomexClient
    participant RS as RegraAduaneiraService
    participant IA as AssistenteIAService
    participant MQ as BarramentoEventos
    participant WK as RoteiroWorker

    %% ===== Geração do checklist (RF14) =====
    U->>UI: informar produto, NCM e destino
    UI->>API: gerarChecklist(GerarChecklistRequest)
    API->>CTX: obterContexto(sessaoId)
    CTX-->>API: ContextoDTO
    API->>CS: gerarChecklist(GerarChecklistRequest, ContextoDTO)

    alt dados mínimos incompletos
        CS-->>API: DadosPendentesDTO
        API-->>UI: 422 DadosPendentesDTO
        UI-->>U: pergunta apenas o que falta (RF03)
    else dados completos
        CS->>DB: salvar(Checklist com status SOLICITADO)
        DB-->>CS: ChecklistId
        CS->>SIS: validarNcm(ncm)
        SIS-->>CS: NcmDTO
        CS->>RS: consultarRequisitos(ncm, paisDestino)
        RS-->>CS: RequisitosDTO

        alt fonte normativa indisponível (timeout)
            CS->>DB: atualizarStatus(checklistId, FALHA)
            DB-->>CS: ok
            CS-->>API: ErroDTO
            API-->>UI: 503 ErroDTO
            UI-->>U: informa falha e oferece reprocessar
        else requisitos obtidos
            loop para cada requisito ou documento de RequisitosDTO
                CS->>IA: redigirItem(RequisitoDTO)
                IA-->>CS: ItemChecklistDTO
            end
            CS->>DB: salvarItens(checklistId, listaItens)
            DB-->>CS: ok
            CS->>DB: atualizarStatus(checklistId, GERADO)
            DB-->>CS: ok
            CS-)MQ: publicar(ChecklistGeradoEvent)
            CS-->>API: ChecklistDTO
            API-->>UI: 201 ChecklistDTO
            UI-->>U: exibe checklist
        end
    end

    %% ===== Processamento assíncrono: roteiro e próximos passos (RF13, RF15) =====
    MQ-)WK: aoReceberEvento(ChecklistGeradoEvent)
    WK->>CS: gerarRoteiro(checklistId)
    CS-->>WK: RoteiroDTO
    WK->>CS: gerarResumoProximosPassos(checklistId)
    CS-->>WK: ResumoDTO

    %% ===== Acompanhamento da execução =====
    U->>UI: iniciar execução do roteiro
    UI->>API: iniciarExecucao(checklistId)
    API->>CS: iniciarExecucao(checklistId)
    CS-->>API: ChecklistDTO
    API-->>UI: 200 ChecklistDTO

    U->>UI: marcar item como concluído
    UI->>API: marcarItem(MarcarItemRequest)
    API->>CS: marcarItem(MarcarItemRequest)
    CS->>DB: buscarPorId(checklistId)
    DB-->>CS: Checklist

    alt status diferente de EM_EXECUCAO
        CS-->>API: ErroDTO (transição inválida)
        API-->>UI: 409 ErroDTO
    else status EM_EXECUCAO
        CS->>DB: atualizarItem(checklistId, itemId, concluido)
        DB-->>CS: ok
        CS-)MQ: publicar(EtapaConcluidaEvent)
        CS-->>API: ProgressoDTO
        API-->>UI: 200 ProgressoDTO
        UI-->>U: atualiza barra de progresso
    end
```

### Regra de consistência: mensagem → operação pública

| Linha de vida (classe) | Operações públicas | Mensagens recebidas no diagrama |
|---|---|---|
| `ChecklistController` | `gerarChecklist(GerarChecklistRequest): ChecklistDTO`, `iniciarExecucao(UUID): ChecklistDTO`, `marcarItem(MarcarItemRequest): ProgressoDTO` | 1.ª, 1.ª e 1.ª de cada fluxo vindas da UI |
| `ContextoService` | `obterContexto(sessaoId): ContextoDTO` | `obterContexto` |
| `ChecklistService` | `gerarChecklist(req, ctx): ChecklistDTO`, `gerarRoteiro(UUID): RoteiroDTO`, `gerarResumoProximosPassos(UUID): ResumoDTO`, `iniciarExecucao(UUID): ChecklistDTO`, `marcarItem(req): ProgressoDTO` | os mesmos nomes |
| `ChecklistRepository` | `salvar`, `salvarItens`, `atualizarStatus`, `buscarPorId`, `atualizarItem` | os mesmos nomes |
| `SiscomexClient` | `validarNcm(ncm): NcmDTO` | `validarNcm` |
| `RegraAduaneiraService` | `consultarRequisitos(ncm, paisDestino): RequisitosDTO` | `consultarRequisitos` |
| `AssistenteIAService` | `redigirItem(RequisitoDTO): ItemChecklistDTO` | `redigirItem` |
| `BarramentoEventos` | `publicar(Evento)` | `publicar(ChecklistGeradoEvent)`, `publicar(EtapaConcluidaEvent)` |
| `RoteiroWorker` | `aoReceberEvento(ChecklistGeradoEvent)` | `aoReceberEvento` |

A `WebApp` só envia mensagens e recebe retornos, então não expõe operações públicas.

**DTOs:** `GerarChecklistRequest`, `MarcarItemRequest`, `ContextoDTO`, `DadosPendentesDTO`, `NcmDTO`, `RequisitosDTO`, `RequisitoDTO`, `ItemChecklistDTO`, `ChecklistDTO`, `RoteiroDTO`, `ResumoDTO`, `ProgressoDTO`, `ErroDTO`.

## 4. Artefato 2 — Diagrama de Atividades com Raias

Há três raias: **Usuário**, **Sistema Back-End** e **Serviços Externos e IA**. O **Fork** inicia três tarefas paralelas (requisitos do destino, documentos exigidos e validação do NCM no Siscomex), e o **Join** só libera o fluxo quando as três terminam. As guardas de cada decisão são mutuamente exclusivas.

> O Mermaid não tem swimlane nativo, então as raias são `subgraph`. Fork e Join usam `shape: fork` e `shape: join` (Mermaid 11.3 ou superior).

```mermaid
flowchart TB
    subgraph RU["Raia 1 · Usuário (Exportador)"]
        direction TB
        U0((Início)) --> U1[Solicitar checklist de exportação]
        U2[Informar dados faltantes]
        U3[Visualizar checklist, roteiro e próximos passos]
        U4[Marcar itens concluídos]
        UF((Fim))
    end

    subgraph RB["Raia 2 · Sistema Back-End"]
        direction TB
        B1[Recuperar contexto da sessão]
        B2{Dados mínimos completos?}
        B3[Solicitar apenas dados faltantes]
        B4[Registrar checklist com status SOLICITADO]
        FORK@{ shape: fork, label: "Fork" }
        B5[Consultar requisitos e restrições do destino]
        B6[Consultar documentos exigidos e emissores]
        JOIN@{ shape: join, label: "Join" }
        B7{Fontes obtidas com sucesso?}
        B8[Registrar status FALHA e permitir reprocesso]
        B9[Consolidar itens e registrar status GERADO]
        B10[Publicar ChecklistGeradoEvent]
        B11[Gerar roteiro sequencial e resumo de próximos passos]
        B12[Registrar status EM_EXECUCAO]
        B13[Atualizar item e calcular progresso]
        B14{Todos os itens obrigatórios concluídos?}
        B15[Registrar status CONCLUIDO e gerar relatório]
    end

    subgraph RE["Raia 3 · Serviços Externos e IA"]
        direction TB
        E1[Validar NCM no Siscomex]
        E2[Redigir itens em linguagem natural com citação de fonte]
    end

    U1 --> B1 --> B2
    B2 -->|"[dadosCompletos = false]"| B3 --> U2 --> B1
    B2 -->|"[dadosCompletos = true]"| B4 --> FORK
    FORK --> B5
    FORK --> B6
    FORK --> E1
    B5 --> JOIN
    B6 --> JOIN
    E1 --> JOIN
    JOIN --> B7
    B7 -->|"[fontesOk = false]"| B8 --> UF
    B7 -->|"[fontesOk = true]"| E2 --> B9 --> B10 --> B11 --> U3
    U3 --> B12 --> U4 --> B13 --> B14
    B14 -->|"[obrigatoriosPendentes > 0]"| U4
    B14 -->|"[obrigatoriosPendentes = 0]"| B15 --> UF
```

## 5. Artefato 3 — Diagrama de Transição de Estados

Entidade: **Checklist**. Os estados são `DadosPendentes`, `Solicitado`, `Gerando`, `Gerado`, `Falha`, `EmExecucao` (com os subestados `Preparacao`, `Documentacao` e `Despacho`), `Concluido` e `Cancelado`. Os estados terminais são `Concluido` e `Cancelado`.

As transições seguem o formato `Gatilho [Guarda] / Ação()`, e `Gerando`, `Falha`, `Preparacao` e `Concluido` têm ações internas (`entry /`, `do /`, `exit /`).

```mermaid
stateDiagram-v2
    direction TB
    [*] --> Solicitado : solicitarChecklist [dadosMinimosCompletos] / registrarChecklist()
    [*] --> DadosPendentes : solicitarChecklist [dadosMinimosIncompletos] / pedirDadosFaltantes()

    DadosPendentes --> Solicitado : informarDados [dadosMinimosCompletos] / atualizarContexto()
    DadosPendentes --> Cancelado : cancelar / descartarRascunho()

    Solicitado --> Gerando : iniciarGeracao [regrasDisponiveis] / consultarFontes()
    Solicitado --> Cancelado : cancelar / descartarRascunho()

    Gerando --> Gerado : concluirGeracao [totalItens > 0] / publicarChecklistGeradoEvent()
    Gerando --> Falha : erroGeracao [tentativas >= 3] / registrarFalha()

    Falha --> Gerando : reprocessar [usuarioSolicitou] / reiniciarTentativas()
    Falha --> Cancelado : cancelar / registrarMotivo()

    Gerado --> EmExecucao : iniciarExecucao [roteiroGerado] / criarProgresso()
    Gerado --> Cancelado : cancelar / registrarMotivo()

    state EmExecucao {
        [*] --> Preparacao
        Preparacao --> Documentacao : concluirEtapa [obrigatoriosDaEtapaMarcados] / liberarProximaEtapa()
        Documentacao --> Despacho : concluirEtapa [obrigatoriosDaEtapaMarcados] / liberarProximaEtapa()
    }

    EmExecucao --> Concluido : concluirDespacho [obrigatoriosPendentes = 0] / emitirRelatorio()
    EmExecucao --> Cancelado : cancelar / registrarMotivo()

    Concluido --> [*]
    Cancelado --> [*]

    Gerando : entry / registrarInicio()
    Gerando : do / redigirItensComIA()
    Gerando : exit / registrarFim()
    Falha : entry / notificarUsuario()
    Preparacao : entry / exibirItensDaEtapa()
    Preparacao : exit / validarObrigatorios()
    Concluido : entry / bloquearEdicao()
```

### Proteção contra estados inválidos

| Operação | Estado exigido | Se violado |
|---|---|---|
| `marcarItem` | `EmExecucao` | `ErroDTO` com HTTP 409 |
| `iniciarExecucao` | `Gerado` e roteiro pronto | HTTP 409 |
| `reprocessar` | `Falha` | HTTP 409 |
| qualquer alteração | `Concluido` ou `Cancelado` | bloqueada (estado terminal) |
| `concluirEtapa` | todos os obrigatórios da etapa marcados | permanece na etapa |

## 6. Artefato 4 — Visão de Contêineres C4 (Nível 2)

Diagrama em Mermaid (renderiza no GitHub). O mesmo modelo está em Structurizr DSL em [`docs/architecture/workspace.dsl`](docs/architecture/workspace.dsl).

```mermaid
C4Container
    title Contêineres — Assistente de IA para Exportação (Checklist e Acompanhamento)

    Person(exp, "Exportador / Despachante", "Solicita checklist e acompanha a exportação")
    Person(cur, "Curador Regulatório", "Valida leis, normas e exigências")

    System_Boundary(sys, "Assistente de IA para Exportação") {
        Container(web, "Web App", "React 18 + TypeScript", "Chat, checklist, roteiro e progresso")
        Container(api, "API Backend", "Node.js 20 + NestJS", "ChecklistController, ContextoService, ChecklistService, ChecklistRepository, SiscomexClient")
        Container(regras, "Serviço de Regras Aduaneiras", "Python 3.12 + FastAPI", "RegraAduaneiraService")
        Container(ia, "Serviço de IA", "Python 3.12 + FastAPI", "AssistenteIAService")
        Container(wk, "Roteiro Worker", "Node.js 20", "RoteiroWorker: roteiro e próximos passos")
        ContainerQueue(mq, "Barramento de Eventos", "RabbitMQ 3.13", "BarramentoEventos: exchange checklist.events")
        ContainerDb(db, "Banco de Dados", "PostgreSQL 16", "Checklists, itens, status e base normativa")
    }

    System_Ext(sis, "Siscomex", "NCM e dados da operação")
    System_Ext(llm, "Provedor de LLM", "Geração de texto")

    Rel(exp, web, "Usa", "HTTPS")
    Rel(cur, regras, "Atualiza base normativa", "HTTPS")
    Rel(web, api, "gerarChecklist, iniciarExecucao, marcarItem", "REST/JSON, HTTPS")
    Rel(api, db, "Lê e grava", "SQL/TCP")
    Rel(api, regras, "consultarRequisitos", "REST/JSON, HTTPS")
    Rel(api, ia, "redigirItem", "REST/JSON, HTTPS")
    Rel(api, sis, "validarNcm", "REST/JSON, HTTPS")
    Rel(api, mq, "publicar eventos", "AMQP 0-9-1, assíncrono")
    Rel(mq, wk, "aoReceberEvento", "AMQP 0-9-1, assíncrono")
    Rel(wk, api, "gerarRoteiro, gerarResumoProximosPassos", "REST/JSON, HTTPS")
    Rel(regras, db, "Lê base normativa", "SQL/TCP")
    Rel(ia, llm, "Solicita geração", "HTTPS")
```

## 7. Artefato 5 — ADR 0001

#### ADR 0001 — Mensageria assíncrona com RabbitMQ para eventos do checklist

**Status:** Aprovado

### Contexto

Após gerar o checklist (RF14), o sistema precisa produzir o roteiro sequencial (RF15)
e o resumo de próximos passos (RF13). Também precisa reagir a eventos de acompanhamento
(etapa concluída, checklist concluído). Essas tarefas envolvem leitura de dependências entre
etapas e, eventualmente, chamadas à IA. Executá-las de forma síncrona dentro da requisição
HTTP aumentaria a latência percebida pelo exportador e acoplaria a disponibilidade do
checklist à disponibilidade dessas rotinas. Além disso, a geração depende de fontes externas
(Siscomex e LLM), sujeitas a lentidão e falhas, e é preciso garantir que nenhum evento seja
perdido.

### Decisão

Adotar **RabbitMQ 3.13 (AMQP 0-9-1)** como barramento de eventos entre o `ChecklistService`
(produtor) e o `RoteiroWorker` (consumidor). Serão usados:

- exchange `topic` `checklist.events` com as routing keys `checklist.gerado` e `etapa.concluida`;
- filas duráveis com mensagens persistentes e *acknowledgement* manual;
- *dead-letter queue* (`checklist.events.dlq`) após 3 tentativas de reprocessamento;
- consumidores idempotentes, usando `checklistId` + `versao` como chave de deduplicação.

As chamadas que exigem resposta imediata ao usuário (gerar checklist, marcar item)
continuam **síncronas** via REST/HTTPS. Apenas a geração do roteiro e do resumo é desacoplada.

**Por que RabbitMQ e não Kafka ou chamada direta?**
O volume é baixo (consultas de pequenas indústrias). O RabbitMQ oferece roteamento por tópico, DLQ e
confirmação por mensagem com operação simples. O Kafka seria superdimensionado, e a chamada direta
manteria o acoplamento temporal.

### Consequências

**Vantagens**
- Resposta mais rápida ao usuário, porque o roteiro é gerado em segundo plano.
- Isolamento de falhas: se o worker cair, as mensagens ficam na fila e o checklist continua disponível.
- Escalabilidade horizontal do worker sem alterar a API.
- Rastreabilidade: eventos duráveis e DLQ facilitam a auditoria.

**Débitos e riscos aceitos**
- Consistência eventual: o roteiro pode aparecer alguns segundos depois do checklist, e a UI deve tratar o estado "gerando roteiro".
- Nova peça de infraestrutura a operar, monitorar e proteger (TLS, credenciais, backup de definições).
- Entrega *at-least-once* exige consumidores idempotentes, o que aumenta a complexidade do código.
- Risco de mensagens envenenadas, mitigado pela DLQ e por alertas.

## 8. Consistência entre os modelos

| Elemento | Sequência | Atividades | Estados | C4 |
|---|---|---|---|---|
| Validar NCM | `SiscomexClient.validarNcm` | "Validar NCM no Siscomex" | guarda `regrasDisponiveis` | `API → Siscomex` |
| Consultar requisitos | `RegraAduaneiraService.consultarRequisitos` | "Consultar requisitos e restrições do destino" | `Solicitado → Gerando` | `API → Serviço de Regras` |
| Redigir itens | `AssistenteIAService.redigirItem` (loop) | "Redigir itens em linguagem natural" | `do / redigirItensComIA()` | `API → Serviço de IA` |
| Publicar evento | `-) publicar(ChecklistGeradoEvent)` | "Publicar ChecklistGeradoEvent" | `Gerando → Gerado` | `API → RabbitMQ` |
| Roteiro e próximos passos | `RoteiroWorker` chama `gerarRoteiro` | "Gerar roteiro sequencial e resumo" | `Gerado → EmExecucao` (guarda `roteiroGerado`) | `Worker → API` |
| Falha de fonte | `alt` com `FALHA` | `B8` "Registrar FALHA" | `Gerando → Falha` | n/a |
| Marcar item | `marcarItem` com `alt` por status | "Atualizar item e calcular progresso" | só em `EmExecucao` | `Web App → API` |

## 9. Como renderizar

- **Mermaid:** o GitHub renderiza os blocos acima. Localmente, use `npx @mermaid-js/mermaid-cli -i docs/diagrams/sequencia.mmd -o sequencia.svg`.
- **Structurizr DSL:** `docker run -it --rm -p 8080:8080 -v $PWD/docs/architecture:/usr/local/structurizr structurizr/lite`.
