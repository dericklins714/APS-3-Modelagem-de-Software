workspace "Assistente de IA para Exportação - Checklist e Acompanhamento" "C4 Nível 2 (Contêineres) para RF13, RF14 e RF15" {

    model {
        exportador = person "Exportador / Despachante" "Pequena indústria que precisa de checklist e acompanhamento da exportação."
        curador    = person "Curador Regulatório" "Revisa e valida leis, normas e exigências (RF12)."

        siscomex = softwareSystem "Siscomex" "Sistema oficial de comércio exterior (NCM e dados da operação)." "Externo"
        llm      = softwareSystem "Provedor de LLM" "API de modelo de linguagem para redação em linguagem natural." "Externo"

        assistente = softwareSystem "Assistente de IA para Exportação" "Gera checklist, roteiro e acompanhamento de exportação." {
            webapp  = container "Web App" "Interface de chat, checklist, roteiro e progresso." "React 18 + TypeScript" "WebBrowser"
            api     = container "API Backend" "ChecklistController, ContextoService, ChecklistService, ChecklistRepository e SiscomexClient." "Node.js 20 + NestJS"
            regras  = container "Serviço de Regras Aduaneiras" "RegraAduaneiraService: requisitos, restrições e documentos por NCM e destino." "Python 3.12 + FastAPI"
            ia      = container "Serviço de IA" "AssistenteIAService: redige itens em linguagem natural citando a fonte." "Python 3.12 + FastAPI"
            worker  = container "Roteiro Worker" "RoteiroWorker: consome eventos e gera roteiro e resumo de próximos passos." "Node.js 20"
            mq      = container "Barramento de Eventos" "BarramentoEventos: exchange topic checklist.events." "RabbitMQ 3.13" "Queue"
            db      = container "Banco de Dados" "Checklists, itens, status, histórico e base normativa." "PostgreSQL 16" "Database"
        }

        exportador -> webapp "Usa" "HTTPS"
        curador -> regras "Atualiza base normativa" "HTTPS"

        webapp -> api "Chama gerarChecklist, iniciarExecucao e marcarItem" "REST/JSON sobre HTTPS"
        api -> db "Lê e grava checklists e itens" "SQL / TCP (pg)"
        api -> regras "consultarRequisitos(ncm, paisDestino)" "REST/JSON sobre HTTPS"
        api -> ia "redigirItem(RequisitoDTO)" "REST/JSON sobre HTTPS"
        api -> siscomex "validarNcm(ncm)" "REST/JSON sobre HTTPS"
        api -> mq "Publica ChecklistGeradoEvent e EtapaConcluidaEvent" "AMQP 0-9-1 (assíncrono)"
        mq -> worker "Entrega eventos" "AMQP 0-9-1 (assíncrono)"
        worker -> api "gerarRoteiro e gerarResumoProximosPassos" "REST/JSON sobre HTTPS"
        regras -> db "Lê a base normativa" "SQL / TCP (pg)"
        ia -> llm "Solicita geração de texto" "HTTPS"
    }

    views {
        container assistente "Containers" {
            include *
            autolayout lr
        }

        styles {
            element "Person" {
                shape person
                background #08427b
                color #ffffff
            }
            element "Software System" {
                background #1168bd
                color #ffffff
            }
            element "Externo" {
                background #999999
                color #ffffff
            }
            element "Container" {
                background #438dd5
                color #ffffff
            }
            element "WebBrowser" {
                shape webbrowser
            }
            element "Database" {
                shape cylinder
            }
            element "Queue" {
                shape pipe
            }
        }
    }
}
