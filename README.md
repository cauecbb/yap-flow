<img src="assets/yap-icon.png" alt="Yap Flow" width="96" height="96">

# Yap Flow

Ditado por voz pra macOS no estilo do Wispr Flow, só que open source.

Você segura o fn, fala e solta, e o texto é colado no app em que você estava (Slack, e-mail, terminal, Claude Code, qualquer campo de texto). Com uma chave de API, o texto já sai limpo: sem "é", "hã" e repetições, com pontuação e com lista quando você enumera. Funciona com Gemini, OpenAI, Groq, Claude ou qualquer API compatível com a da OpenAI. Sem chave, roda tudo no próprio Mac.

É um fork do [Yap](https://github.com/FrigadeHQ/yap), da Frigade. Não tem nenhuma ligação com o Wispr Flow; o nome só aparece aqui como referência.

## O que mudou em relação ao Yap

- Segurar fn pra falar e soltar pra colar. Um toque rápido no fn liga o modo mãos-livres, e outro toque termina. Esc cancela.
- Transcrição na nuvem com o provedor que você escolher: Gemini, OpenAI, Groq ou qualquer servidor compatível com a API da OpenAI.
- Limpeza do texto com Gemini, OpenAI, Claude, Groq, um servidor compatível ou a Apple Intelligence.
- Com o Gemini, o áudio vai em streaming enquanto você fala, então ao soltar o fn o texto chega rápido.
- Se a API falhar ou não tiver chave, ele usa o reconhecimento de voz da Apple, que roda no Mac.
- A barrinha de gravação é uma pílula preta pequena. Dá pra arrastar ela pra baixo ou pras laterais, e nas laterais ela fica na vertical.
- Sons novos e configuráveis, e ajustes pra português.

## Requisitos

- macOS 26 ou mais novo, em Mac com Apple Silicon
- Xcode 26 ou mais novo (App Store)
- Homebrew
- Uma chave de API de algum provedor, se quiser transcrição ou limpeza na nuvem

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

## Escolhendo a API

Tudo fica em Open Yap... (ícone na barra de menu), na seção AI. São duas escolhas:

- **Transcription**: quem transforma a fala em texto. Gemini, OpenAI, Groq, Custom ou On-device only.
- **Cleanup**: quem limpa o texto depois. Gemini, OpenAI, Claude, Groq, Custom, Apple Intelligence ou Off. O Gemini já faz a limpeza junto com a transcrição, então quando ele transcreve essa opção fica desligada. O Claude só aparece aqui porque não transcreve áudio.

Ao escolher um provedor, aparecem os campos da chave e do modelo. A chave fica guardada no Keychain do macOS. O modelo pode ficar em branco pra usar o padrão:

| Provedor | Transcrição | Limpeza | Onde pegar a chave |
|---|---|---|---|
| Gemini | `gemini-3.5-transcribe` (já limpa) | `gemini-3.5-flash-lite` | aistudio.google.com/apikey |
| OpenAI | `gpt-transcribe` | `gpt-6-luna` | platform.openai.com/api-keys |
| Groq | `whisper-large-v3-turbo` | `openai/gpt-oss-20b` | console.groq.com/keys |
| Claude | (não transcreve) | `claude-opus-5-5` | Claude Console |
| Custom | você define | você define | depende do servidor |

Algumas combinações que funcionam bem:

- **Gemini sozinho**: o mais parecido com o Wispr. Transcreve em streaming, limpa e entende português e inglês misturados. Custa por volta de US$ 0,005 por minuto. No plano gratuito do Gemini, o Google pode usar o áudio pra treinar os modelos.
- **Groq + Groq**: muito rápido e barato.
- **OpenAI + Claude**: transcrição da OpenAI e limpeza do Claude. Se quiser a limpeza mais rápida e barata, troque o modelo do Claude pra `claude-haiku-5-5`.
- **On-device only + Apple Intelligence**: nada sai do Mac. Reconhece um idioma por vez (configurável em Language).

### Custom: qualquer API compatível com a OpenAI

O Custom aceita qualquer servidor que implemente `/audio/transcriptions` e `/chat/completions` no formato da OpenAI: OpenRouter, Together, Fireworks, LM Studio, Ollama, LocalAI etc. Preencha a Base URL (por exemplo `https://openrouter.ai/api/v1` ou `http://localhost:11434/v1`) e os nomes dos modelos. A chave é opcional, porque servidores locais normalmente não pedem.

Dá pra usar o Custom só na limpeza, por exemplo com a transcrição no Gemini ou no Mac e a limpeza num modelo rodando localmente.

### Outras opções

Algumas configurações não aparecem na tela e podem ser mudadas pelo Terminal. Reabra o app depois.

```bash
# fixar os idiomas em vez de detectar automaticamente
defaults write com.frigade.Yap languageCodes -array pt-BR en-US

# desligar o streaming do Gemini (manda o áudio inteiro quando você solta o fn)
defaults write com.frigade.Yap geminiStreaming -bool false

# modelo do streaming do Gemini
defaults write com.frigade.Yap geminiLiveModel gemini-3.5-transcribe-live

# idioma do modo local
defaults write com.frigade.Yap dictationLanguage pt-BR
```

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

Os sons padrão são batidinhas curtas de madeira, uma subindo pra começar, uma descendo pra terminar e duas pra travar o mãos-livres. Eles são gerados do zero pelo `Tools/generate-sounds.py`, então dá pra mexer nas notas e na duração e gerar de novo.

Pra usar sons seus, coloque arquivos `.wav` curtos em `Sources/Resources/Sounds/` com os nomes `dictation-start.wav`, `dictation-stop.wav` e `dictation-lock.wav` e rode o `install-local.sh`. Eles têm prioridade sobre os padrão, e essa pasta não vai pro git.

## Privacidade

O áudio só sai do Mac se você escolher um provedor de transcrição na nuvem, e vai só pra ele. Fica na memória enquanto você fala, e trechos de silêncio não são enviados. Com a limpeza na nuvem, o que vai é o texto transcrito. Com On-device only e Apple Intelligence (ou Off), nada sai do Mac. Histórico e dicionário ficam salvos localmente, e o app não tem conta nem telemetria.

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
- `Sources/Services/AIConfig.swift`: provedores, modelos padrão e configurações
- `Sources/Services/AIRouters.swift`: escolhe o provedor de cada ditado e cai no local se der erro
- `Sources/Services/GeminiAPI.swift` e `GeminiLiveSession.swift`: Gemini, com o streaming
- `Sources/Services/OpenAICompatibleTranscriber.swift`: transcrição da OpenAI, Groq e Custom
- `Sources/Services/LLMCleaner.swift`: limpeza com OpenAI, Claude, Groq, Gemini e Custom
- `Sources/HUD/`: a barrinha

Pra adicionar um provedor que não fala o formato da OpenAI, crie um caso em `AIService` e `TranscriptionProvider` (ou `CleanupProvider`) em `AIConfig.swift` e trate ele em `AIRouters.swift`. Os testes em `Tests/ProviderRequestTests.swift` mostram como conferir a requisição sem gastar chamada de API.

Pull requests são bem-vindos.

## Licença

MIT, a mesma do projeto original. A base (captura de áudio, transcrição local, colagem em qualquer app, histórico e dicionário) é do [Yap](https://github.com/FrigadeHQ/yap), da [Frigade](https://frigade.com).
