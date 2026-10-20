# Steam Status Scheduler

Deixa sua Steam **invisível (ou offline, ausente...) automaticamente em horários programados** e volta pra online sozinho depois.

Exemplo que vem configurado: sábado e domingo, das 06:00 às 12:00, você aparece offline pros amigos. Às 12:00 volta pra online. Ideal pra quem gosta de jogar sozinho em certos horários sem ter que lembrar de trocar o status.

Funciona no Windows 10 e 11. Não precisa instalar nada além da própria Steam.

## Instalar

1. Baixe o projeto: botão verde **Code** > **Download ZIP** (ou [clique aqui](https://github.com/IvanPJ/steam-status-scheduler/archive/refs/heads/main.zip)).
2. Extraia o ZIP em qualquer pasta.
3. Dê duplo clique em **`Instalar.bat`**.

Se o Windows mostrar a tela azul "O Windows protegeu o computador", clique em **Mais informações** > **Executar assim mesmo**. Isso aparece porque o arquivo veio da internet, é normal.

Ele instala em `%LOCALAPPDATA%\SteamStatusScheduler`, cria uma tarefa agendada que inicia junto com o Windows (com janela oculta), cria o atalho **Steam Status Scheduler** no Menu Iniciar e já abre a janela de configuração. Não baixa nada da internet e não precisa de administrador.

**Antivírus:** é tudo script PowerShell aberto, dá pra ler cada arquivo. Alguns antivírus (Kaspersky, por exemplo) desconfiam de script que roda escondido no logon. Se o seu bloquear, adicione a pasta `%LOCALAPPDATA%\SteamStatusScheduler` nas exceções e rode o `Instalar.bat` de novo.

## Configurar

Tecla Windows, digite **Steam Status Scheduler**, Enter (ou `Configurar.bat` na pasta de instalação). Abre uma janela nativa, sem navegador e sem nada instalado além do Windows:

![Steam Status Scheduler](docs/screenshot.png)

- **Grade semanal**: arraste numa linha pra criar uma janela naquele dia e horário. Clique numa janela pintada pra editar.
- **Janelas**: lista à esquerda. `[ + Nova ]`, `[ Duplicar ]`, `[ Remover ]`.
- **Editar**: nome, dias (com atalhos seg-sex / fds / todos), início e fim em `HH:mm`, status durante a janela.
- **Fora das janelas**: pra onde voltar quando a janela termina (normalmente `online`).
- **Modo atual** e **próxima janela** com contagem regressiva, no painel da direita. A caveira fica com os olhos vermelhos quando você está invisível.
- **[ Testar 45s ]**: deixa você invisível por 45 segundos e volta pra online, pra ver que funciona.
- **[ Log ]**: cada troca de status vira uma linha com data e hora.
- **[ SALVAR ]**: o serviço lê o novo horário em até 30 segundos, não precisa reiniciar nada.
- O cabeçalho do painel esquerdo mostra se o serviço está **ATIVO**. Se aparecer PARADO, tem um botão `[ Iniciar ]`.

Status disponíveis:

- `invisible`: aparece offline pros amigos, mas você ainda vê a lista e recebe mensagens. **É o recomendado.**
- `offline`: modo "Ficar offline" da Steam, desconecta do chat de amigos.
- `away`, `busy`, `online` também valem.

Detalhes: cada janela começa e termina no mesmo dia (de 00:00 até 23:59). Se você trocar o status na mão no meio de uma janela, ele respeita e não força de volta.

## Desinstalar

`Desinstalar.bat` na pasta de instalação (`%LOCALAPPDATA%\SteamStatusScheduler`). Remove a tarefa, o atalho do Menu Iniciar e a pasta. Se você estava invisível por causa dele, volta pra online antes de sair.

## Como funciona

- Um script PowerShell fica rodando escondido e, a cada 30 segundos, confere o dia e a hora.
- Quando entra numa janela e a Steam está aberta, manda o comando `steam://friends/status/invisible` pra própria Steam. Só uma vez por janela.
- Quando a janela termina, manda `steam://friends/status/online` (ou o status que você escolheu em [P]).
- Se a Steam estiver fechada no começo da janela, aplica assim que ela abrir (espera 45 segundos pra ela terminar de logar).
- Tudo fica na pasta de instalação: `config.json` (horários), `state.json`, `scheduler.log`. Quem preferir pode editar o `config.json` direto no Bloco de Notas.

O script só mexe no status de amigos, não interfere nos jogos.

## Licença

MIT. Faça o que quiser.
