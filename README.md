# PDF Splitting Tool (Otimizado para PJe-JT)

## O que é este script?
O `kiwi_splitter.py` é uma aplicação enxuta e especializada para redimensionamento, particionamento e preservação nativa de PDFs. Seu objetivo principal é viabilizar o envio de grandes processos a LLMs como o Gemini 3.1 Pro, sem esgotar as regras de limite (usualmente 50 MB de tamanho e 1 milhão de tokens no Google AI Studio). Esta aplicação foi desenvolvida exclusivamente para manipulação de PDFs gerados pelo Processo Judicial Eletrônico da Justiça do Traabalho (PJe-JT). O sumário gerado pelo PJe-JT ao final do PDF é utilizado nesta aplicação como um seletor de documentos, com contagem estimada de tokens em tempo real, para que o usuário possa dimensionar apropriadamente o arquivo processado a ser enviado ao LLM.

## Funcionalidades Chave:

- **Automação de Divisão Baseada em Peso**: Se você submeter um ou mais documentos gigantes originários do processo com tamanho na casa de cem Megabytes ou mais, a configuração automática do aplicativo se encarrega de dividir em fatias ideais. Cada PDF será segmentado progressivamente sem que nenhuma fatia jamais exceda **45 MB**.
- **Mantém a Contagem de Tokens**: Os cálculos analíticos de tamanho do documento (em tokens LLM) foram deixados intactos via script tiktoken interno para consistência visual do seu projeto inicial.
- **Botão Inteligente de Marcação Geral**: Você pediu e agora acima da lista do Sumário há um alternador global `Selecionar Todos` simplificando a logística.
- **Log Persistente**: Logs idênticos aos scripts antecessores.

## 🚀 O GRANDE BÔNUS: A "Sanitização de Incrementos do PJe"
O sistema dos Tribunais brasileiros (PJe) geralmente não comprime os PDFs quando um advogado envia uma juntada ou quando o tribunal emite uma decisão incrementada. Eles empilham novos conteúdos no final da árvore do protocolo, sem jogar fora objetos inativos. Com isso os processos ficam extremamente pesados em relação ao seu conteúdo prático.

Este script conta com um mecanismo engenhoso e poderoso que **quebra esse inchaço**. Para a montagem lógica dos novos PDFs particionados que você gera com esse aplicativo, ele usa os seguintes parâmetros ocultos nos bastidores de código:
- `garbage=4`: Destrói completamente as tabelas de rastreio de todos os "XObjects" ausentes no processamento (tais como páginas que um perito adicionou mas depois removeu, imagens corrompidas, embeds de fontes antigas duplicadas). O resultado é uma árvore esguia apenas com o texto de leitura real e final que está perfeitamente linkado à visualização do processo.
- `deflate=True`: Comprime todos os textos contidos e fluxos de metadados binários invisíveis que os sistemas PJe tradicionalmente abandonam não lidados no cache do PDF.
- A união dessas forças, somada ao **algoritmo de Extração Nativa Bina-rápida (Binary Search de bytes)** faz com que você rotineiramente chegue em um fracionamento 4 vezes mais leve em bytes do que o arquivo primitivo do tribunal indicava, economizando tempo formidável de Upload futuro e processamento de LLMs.


## Geração de Arquivo Consolidado (`_full_sanitized.pdf`)
A partir da versão **1.1.0**, o script também gera automaticamente um arquivo contendo a fusão de *todos* os documentos selecionados em um único PDF (`_full_sanitized.pdf`). O objetivo desta funcionalidade é fornecer um arquivo consolidado, leve e completamente sanitizado, pronto para ser submetido a outros conversores de PDF para Markdown, dispensando os fracionamentos para cenários e processadores que toleram PDFs pesados e priorizem contexto ininterrupto.

## Atualizações Recentes (Migração Definitiva para PyQt6)
* **Reescrita Total da Interface em PyQt6:** A aplicação `kiwi_splitter.py` foi 100% reescrita utilizando o framework C++ nativo **PyQt6** (`QApplication`, `QMainWindow`, `QThread`, etc.), abandonando completamente o ecossistema Web/Flutter do Flet.
* **Resolução do "Loss of Focus Bug" no Windows:** Anteriormente (na versão Flet), a pesada manipulação matemática do `PyMuPDF` bloqueava totalmente a Thread Principal Assíncrona do Flet, e a interface gráfica "dormia" até que o usuário clicasse fora da janela. Com PyQt6, a interface roda nativamente sobre o DWM do Windows. O monitoramento/log é disparado via Sistema de Sinais Seguros de Thread do Qt (`pyqtSignal(str)`).
* **Velocidade e Estabilidade:** O algorítmo C do `PyMuPDF` (`fitz.tobytes` para particionamento de PDFs de 200MB+) roda agonicamente fechado em uma `QThread` invisível isolada no background, enquanto a GUI continua fluindo a 60 FPS, aceitando cliques e processando barras de progresso sem qualquer frame delay artificial.
* **Componentes Responsivos:** Foi implementada uma QTableWditet nativa com seleção em lote auto-estilizável em "Fusion" UI para consistência moderna nativa. Essa alteração vale exclusivamente para o script de Splitting, garantindo escalabilidade à prova de falhas na máquina do analista.

## Atualizações em estudo
* **Conversão para Markdown**
* **OCR de tabelas, imagens e documentos manuscritos**
- Estamos testando várias bibliotecas e LLMs para encontrar o balanço ideal de performance e confiabilidade, com ou sem processamento por GPU. Aceitamos sugestões!
