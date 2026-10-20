# Steam Status Scheduler

Deixa sua Steam **invisível (ou offline, ausente...) automaticamente em horários programados** e volta pra online sozinho depois.

Exemplo que vem configurado: sábado e domingo, das 06:00 às 12:00, você aparece offline pros amigos. Às 12:00 volta pra online. Ideal pra quem gosta de jogar sozinho em certos horários sem ter que lembrar de trocar o status.

Funciona no Windows 10 e 11. Não precisa instalar nada além da própria Steam e não deixa nenhum programa rodando em segundo plano.

## Instalar

1. Baixe o projeto: botão verde **Code** > **Download ZIP** (ou [clique aqui](https://github.com/IvanPJ/steam-status-scheduler/archive/refs/heads/main.zip)).
2. Extraia o ZIP em qualquer pasta.
3. Dê duplo clique em **`Instalar.bat`**.

Se o Windows mostrar a tela azul "O Windows protegeu o computador", clique em **Mais informações** > **Executar assim mesmo**. Isso aparece porque o arquivo veio da internet, é normal.

Ele copia os arquivos pra `%LOCALAPPDATA%\SteamStatusScheduler`, cria as tarefas no Agendador de Tarefas do Windows, cria o atalho **Steam Status Scheduler** no Menu Iniciar e abre a janela de configuração. Não baixa nada da internet e não precisa de administrador.

## Configurar

Tecla Windows, digite **Steam Status Scheduler**, Enter. Abre uma janela nativa do Windows, sem navegador e sem instalar nada:

![Steam Status Scheduler](docs/screenshot.png)

- **Semana**: arraste numa linha pra criar uma janela naquele dia e horário. Clique numa janela pintada pra editar. A linha ciano marca o momento atual.
- **Janelas de horário**: `+ NOVA`, `DUPLICAR`, `REMOVER`.
- **Editar janela**: nome, dias (com atalhos seg a sex, fim de semana, todos), início e fim em `HH:mm` e o status durante a janela.
- **Fora das janelas**: pra onde voltar quando a janela termina, normalmente `ONLINE`.
- O painel grande mostra o status que a programação manda agora, a próxima janela e a contagem regressiva.
- Embaixo, dois bots jogam Pong neon sozinhos, batizados com os dois jogos que você jogou por último. As cores seguem o seu status.
- A faixa de baixo mostra o jogo rodando agora, o último jogo, quantos jogos tem na biblioteca e quanto espaço eles ocupam. Tudo vem só dos manifestos da biblioteca de jogos; nenhum dado de conta ou login da Steam é lido.
- **SALVAR** grava o config e recria as tarefas do Windows na hora.
- **TESTAR 45s** deixa você invisível por 45 segundos e volta pra online.
- **AGENDA** mostra as tarefas criadas, com a próxima e a última execução.

Status disponíveis:

- `INVISÍVEL`: aparece offline pros amigos, mas você ainda vê a lista e recebe mensagens. **É o recomendado.**
- `OFFLINE`: modo "Ficar offline" da Steam, desconecta do chat de amigos.
- `AUSENTE`, `OCUPADO`, `ONLINE` também valem.

## Como funciona

Não fica nenhum programa rodando em segundo plano. Cada janela vira duas tarefas na pasta `SteamStatusScheduler` do Agendador de Tarefas do Windows:

- no início, a tarefa roda `steam.exe -silent steam://friends/status/invisible` (ou o status escolhido);
- no fim, roda o mesmo comando com o status de "fora das janelas".

Quem executa é o próprio Windows, e quem troca o status é a própria Steam. Detalhes:

- Se o PC estava desligado no horário, a tarefa roda assim que ele ligar.
- Se a Steam estiver fechada no horário, ela abre minimizada na bandeja já com o status certo.
- Entre o início e o fim nada é forçado: se você trocar o status na mão, ele fica até o próximo horário.
- Cada janela começa e termina no mesmo dia, de 00:00 até 23:59.

**Antivírus:** não tem script escondido nem processo em segundo plano, só tarefas do Windows chamando a Steam. O PowerShell só roda quando você abre a janela de configuração ou o instalador. Tudo é script aberto, dá pra ler cada arquivo.

## Desinstalar

`Desinstalar.bat` na pasta de instalação (`%LOCALAPPDATA%\SteamStatusScheduler`). Remove as tarefas, o atalho do Menu Iniciar e a pasta, e volta pra online.

## Licença

MIT. Faça o que quiser.
