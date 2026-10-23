<img src="assets/yap-icon.png" alt="Yap Flow" width="96" height="96">

# Yap Flow

Ditado por voz pra macOS no estilo do Wispr Flow, só que open source.

Você segura o fn, fala e solta, e o texto é colado no app em que você estava (Slack, e-mail, terminal, Claude Code, qualquer campo de texto). Com uma chave do Gemini, o texto já sai limpo: sem "é", "hã" e repetições, com pontuação, com lista quando você enumera, e entendendo português e inglês misturados.

É um fork do [Yap](https://github.com/FrigadeHQ/yap), da Frigade. Não tem nenhuma ligação com o Wispr Flow; o nome só aparece aqui como referência.

## O que mudou em relação ao Yap

- Segurar fn pra falar e soltar pra colar. Um toque rápido no fn liga o modo mãos-livres, e outro toque termina. Esc cancela.
- Transcrição com o Gemini 3.5 Transcribe no modo SMART, que tira as hesitações, aplica correções faladas ("na terça, não, na quarta") e formata listas, números e datas.
- O áudio vai pro Gemini em streaming enquanto você fala, então ao soltar o fn o texto chega rápido.
- Se não tiver chave, ou se a API falhar, ele usa o reconhecimento de voz da Apple, que roda no próprio Mac.
- A barrinha de gravação é uma pílula preta pequena. Dá pra arrastar ela pra baixo ou pras laterais, e nas laterais ela fica na vertical.
- Ajustes pra português: hesitações comuns e detecção automática de idioma.

## Requisitos

- macOS 26 ou mais novo, em Mac com Apple Silicon
- Xcode 26 ou mais novo (App Store)
- Homebrew
- Uma chave da API do Gemini, se quiser a transcrição na nuvem

## Instalação

```bash
git clone https://github.com/cauecbb/yap-flow.git
cd yap-flow
./scripts/create-signing-cert.sh
./install-local.sh
```

O `install-local.sh` compila, instala em `/Applications/Yap.app` e abre o app. Pra atualizar, é só dar `git pull` e rodar ele de novo.

O `create-signing-cert.sh` é opcional e só precisa rodar uma vez. Ele cria um certificado local pra assinar o app. Sem ele, o macOS trata cada compilação como um app novo e pede as permissões de novo toda vez que você atualiza.

Se você já tem o Yap original instalado, este vai substituir ele, porque os dois usam o mesmo nome e bundle id.

Na primeira vez o app pede acesso ao microfone, ao reconhecimento de fala, à acessibilidade e à automação. A acessibilidade precisa ser ligada na mão em Ajustes do Sistema > Privacidade e Segurança > Acessibilidade. Sem ela o app não consegue ler o fn nem colar o texto.

### Se o fn abrir o painel de emojis

O macOS faz isso por padrão. Em Ajustes do Sistema > Teclado, troque a opção da tecla fn/Globo ("Pressionar ... para") pra "Não fazer nada". Precisa ser pela tela de Ajustes; mudar por `defaults write` só vale depois de sair e entrar de novo na conta.

## Configurando a API

### Gemini

1. Gere uma chave em https://aistudio.google.com/apikey
2. Abra o app pelo ícone na barra de menu, vá em Open Yap... e cole a chave em Cloud transcription.

A chave fica guardada no Keychain do macOS. O custo fica em torno de US$ 0,005 por minuto de áudio no plano pago. O plano gratuito também funciona, mas nele o Google pode usar o áudio pra treinar os modelos.

### Sem API

Sem chave, ou com a opção Transcribe with Gemini desligada, tudo roda no Mac usando o `SpeechAnalyzer` da Apple. É mais rápido e nada sai do computador, mas ele reconhece um idioma por vez (configurável em Language) e não formata o texto. Se a Apple Intelligence estiver ligada, a opção Clean up transcripts faz uma limpeza básica, também localmente.

### Outras opções

Algumas configurações não aparecem na tela e podem ser mudadas pelo Terminal. Reabra o app depois.

```bash
# trocar o modelo usado
defaults write com.frigade.Yap geminiModel gemini-3.5-transcribe
defaults write com.frigade.Yap geminiLiveModel gemini-3.5-transcribe-live

# desligar o streaming (manda o áudio inteiro quando você solta o fn)
defaults write com.frigade.Yap geminiStreaming -bool false

# fixar os idiomas em vez de detectar automaticamente
defaults write com.frigade.Yap geminiLanguageCodes -array pt-BR en-US

# idioma do modo local
defaults write com.frigade.Yap dictationLanguage pt-BR
```

### Usando outro provedor

Por enquanto só o Gemini está implementado, mas dá pra plugar outro (OpenAI, Groq, Deepgram etc.). A parte de nuvem depende de dois protocolos:

- `CloudTranscribing`, em `Sources/Services/GeminiTranscriber.swift`, recebe o áudio inteiro em WAV (16 kHz, mono) quando você solta o fn e devolve o texto. Implementar só esse já é suficiente.
- `CloudStream`, em `Sources/Services/GeminiLiveSession.swift`, é opcional e serve pra APIs que aceitam streaming. Ele recebe o áudio em pedaços enquanto você fala.

Pra trocar, crie uma classe que implemente `CloudTranscribing` (a do Gemini serve de exemplo) e use ela no lugar de `GeminiTranscriber()` em `Sources/AppState.swift`. Se a API só transcrever, sem limpar o texto, dá pra passar o resultado por um LLM com as mesmas regras de `TranscriptCleanupService.swift`. Quando o provedor retorna `nil`, o app usa a transcrição local, então uma falha na API não faz você perder o que falou.

## Atalhos

| Ação | Atalho |
|---|---|
| Ditar | segurar fn, falar, soltar |
| Mãos-livres | toque rápido no fn, ou fn+espaço enquanto segura; outro toque termina |
| Cancelar | Esc |
| Alternativo | Cmd+Shift+D (configurável) |

Combinações com fn, como setas, delete e F1 a F12, continuam funcionando normalmente.

A posição da barrinha pode ser escolhida arrastando ou em Open Yap... > Bar position.

## Sons

O app usa sons do macOS por padrão. Pra usar outros, coloque arquivos `.wav` curtos em `Sources/Resources/Sounds/` com os nomes `dictation-start.wav`, `dictation-stop.wav` e `dictation-lock.wav` e rode o `install-local.sh`. Essa pasta não vai pro git.

## Privacidade

Com o Gemini ligado, o áudio de cada ditado é enviado pra API do Google. Ele fica só na memória enquanto você fala, e trechos de silêncio não são enviados. Sem o Gemini, nada sai do Mac. Histórico e dicionário ficam salvos localmente, e o app não tem conta nem telemetria.

## Desenvolvimento

```bash
xcodegen generate
open Yap.xcodeproj
```

Testes:

```bash
xcodebuild -project Yap.xcodeproj -scheme Yap -destination 'platform=macOS' test
```

Os pontos principais do código:

- `Sources/Services/PushToTalkMonitor.swift`: leitura do fn
- `Sources/Coordinator/RecordingCoordinator.swift`: fluxo de gravar, transcrever e colar
- `Sources/HUD/`: a barrinha
- `Sources/Services/GeminiTranscriber.swift` e `GeminiLiveSession.swift`: integração com o Gemini

Pull requests são bem-vindos, principalmente com outros provedores.

## Licença

MIT, a mesma do projeto original. A base (captura de áudio, transcrição local, colagem em qualquer app, histórico e dicionário) é do [Yap](https://github.com/FrigadeHQ/yap), da [Frigade](https://frigade.com).
