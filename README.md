# Steam Version Manager

Baixe, guarde e jogue **versões antigas** de jogos da Steam no Windows, sem mexer na instalação da Steam.

Feito para quando uma atualização quebra algo, ou quando o servidor que você joga ainda não atualizou e você precisa da versão anterior.

> English summary at the end.

## O que ele faz

- **Lista os jogos instalados** em todas as suas bibliotecas Steam.
- **Mostra as versões de cada jogo** com build, data e título da atualização, tirados das notas de patch oficiais da Steam.
- **Detecta sozinho a versão instalada na Steam** e guarda o histórico em cada abertura.
- **Importa versões antigas do SteamDB**: você abre a página, aperta Ctrl+A e Ctrl+C e cola no programa.
- **Baixa a versão escolhida** numa pasta separada. A instalação da Steam nunca é alterada.
- **Abre o jogo** já com o executável certo. Em jogos com BattlEye ou EasyAntiCheat, ele usa o launcher, como a Steam faz.

### Download sem dor de cabeça

- **Um login só.** Todas as partes do jogo (depots) são baixadas num único comando.
- **Sessão lembrada.** Você escaneia o QR code da Steam uma vez, e os próximos downloads entram sozinhos.
- **QR code grande**, numa janela própria e centralizada. Se ele expirar, aparece outro automaticamente, com um aviso sonoro.
- **Progresso dentro do programa**, sem janela preta.
- **Reinício automático.** Se o download ficar parado por vários minutos ou cair no meio, ele continua de onde parou.
- **Confere o espaço em disco** antes de começar e avisa se não couber.
- **Botão Jogar só com download completo.** Download interrompido aparece como "Download incompleto", com o botão "Continuar download".

## Requisitos

- Windows 10 ou 11, com o Windows PowerShell 5.1 que já vem no sistema (ou PowerShell 7).
- Steam instalada e uma conta que **tenha o jogo**.
- Espaço em disco para cada versão guardada. O SCUM, por exemplo, ocupa ~80 GB por versão.

## Como usar

1. Baixe o repositório (botão **Code → Download ZIP**) e extraia numa pasta.
2. Dê dois cliques em **`Abrir Steam Version Manager.bat`**.
3. Escolha o jogo na lista da esquerda.
4. Selecione uma versão e clique no botão principal:
   - **Baixar esta versão** ou **Continuar download**;
   - **Jogar esta versão**, depois de baixada;
   - **Importar do SteamDB...**, quando falta o manifest daquela versão.

Na primeira vez, o programa oferece baixar o [DepotDownloader](https://github.com/SteamRE/DepotDownloader), o motor de download open source que fala com os servidores da Steam.

### Login na Steam

O download usa a sua própria conta, porque só dá para baixar jogos que você tem.

- Na primeira vez aparece um **QR code**. Escaneie com o app da Steam no celular.
- O DepotDownloader guarda uma **chave de sessão** no seu PC (não é a sua senha). Os próximos downloads entram sozinhos.
- Para entrar com outra conta, ou esquecer a sessão, use **Configurações**.

O programa nunca pede nem guarda a sua senha.

## Onde ficam as coisas

| O quê | Onde |
|---|---|
| Versões baixadas | `D:\GameVersions` (ou `%USERPROFILE%\GameVersions`); dá para mudar em Configurações |
| Histórico de versões | `versions.json` dentro da pasta de versões |
| Logs dos downloads | `_logs` dentro da pasta de versões |
| DepotDownloader | `_tools` dentro da pasta de versões |
| Configurações | `%APPDATA%\SteamVersionManager\settings.json` |

## Limites e cuidados

- **Servidores online** costumam aceitar só a versão atual do jogo. Uma versão antiga é para jogar sozinho (single player) ou em servidores que estejam na mesma versão.
- **Anti-cheat:** o programa não modifica nenhum arquivo do jogo, só baixa a versão oficial da própria Steam. Mesmo assim, siga as regras do jogo e do servidor.
- **Versões muito antigas** podem ter sido removidas dos servidores da Steam e não baixar mais.
- **Telas de primeira vez:** ao abrir uma versão antiga, alguns jogos pedem de novo para aceitar termos, porque cada pasta conta como uma instalação nova.

## Problemas comuns

- **O QR code não apareceu ou expirou:** o programa gera outro sozinho. Se desistir depois de várias tentativas, clique em "Continuar download".
- **O download parou:** se ficar sem atividade por alguns minutos, ele reinicia sozinho. Você também pode clicar em "Parar download" e depois "Continuar download".
- **Disco cheio:** apague uma versão antiga pelo botão "Apagar arquivos" ou libere espaço, e clique em "Continuar download".
- **Abriu o executável errado:** em Configurações, use "Esquecer executáveis escolhidos".
- Os detalhes de cada download ficam no log, na pasta `_logs`.

## Testes

Dê dois cliques em **`Rodar testes.bat`**. Os testes criam uma Steam falsa numa pasta temporária: não tocam na sua Steam nem nos seus jogos. A pasta `tests/fixtures` tem saídas reais do DepotDownloader (com o nome da conta trocado), usadas para testar login, QR code, progresso e falhas.

## Estrutura

| Arquivo | Função |
|---|---|
| `SteamVersionManager.ps1` | Interface (Windows Forms) |
| `SteamVersionManager.Core.ps1` | Lógica sem interface: Steam, versões, SteamDB, download (testável) |
| `Run-Tests.ps1` | Testes automáticos |
| `tests/fixtures/` | Saídas reais do DepotDownloader usadas nos testes |

## Licença

**Todos os direitos reservados.** Você pode usar o programa e ler o código. Copiar, modificar ou redistribuir só com autorização. Veja [LICENSE](LICENSE).

O DepotDownloader **não faz parte deste repositório**. Ele é baixado da página oficial do projeto SteamRE e segue a licença dele (GPL-2.0).

## Aviso

Projeto independente, sem ligação com a Valve ou com os desenvolvedores dos jogos. Steam é marca da Valve Corporation. Use por sua conta e risco e respeite o Acordo de Assinatura do Steam.

---

## English summary

**Steam Version Manager** lets you download, keep and play older versions of your own Steam games on Windows, in a separate folder. Your Steam install is never touched.

- Lists your installed games and their versions, with patch-note titles from Steam's official news feed.
- Imports older builds by pasting SteamDB pages.
- Downloads with [DepotDownloader](https://github.com/SteamRE/DepotDownloader) inside the app. All depots use a single login. You scan a QR code once, and the session is remembered. You get a progress bar, automatic resume when a download stalls or drops, and a disk-space check before starting.
- Launches the right executable, including the anti-cheat launcher when the game has one.

Run `Abrir Steam Version Manager.bat` to start, and `Rodar testes.bat` to run the tests. All rights reserved: see [LICENSE](LICENSE).
