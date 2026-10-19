# Steam Status Scheduler

Deixa sua Steam **invisível (ou offline, ausente...) automaticamente em horários programados** e volta pra online sozinho depois.

Exemplo que vem configurado: sábado e domingo, das 06:00 às 12:00, você aparece offline pros amigos. Às 12:00 volta pra online. Ideal pra quem gosta de jogar sozinho em certos horários sem ter que lembrar de trocar o status.

Funciona no Windows 10 e 11. Não precisa instalar nada além da própria Steam.

## Instalar

### Jeito 1: duplo clique

1. Baixe o projeto: botão verde **Code** > **Download ZIP** (ou [clique aqui](https://github.com/IvanPJ/steam-status-scheduler/archive/refs/heads/main.zip)).
2. Extraia o ZIP em qualquer pasta.
3. Dê duplo clique em **`Instalar.bat`**.

Se o Windows mostrar a tela azul "O Windows protegeu o computador", clique em **Mais informações** > **Executar assim mesmo**. Isso aparece porque o arquivo veio da internet, é normal.

### Jeito 2: uma linha no PowerShell

Abra o PowerShell (tecla Windows, digite `powershell`, Enter) e cole:

```powershell
irm https://raw.githubusercontent.com/IvanPJ/steam-status-scheduler/main/install.ps1 | iex
```

Nos dois casos ele instala em `%LOCALAPPDATA%\SteamStatusScheduler`, cria uma tarefa agendada que inicia junto com o Windows (sem janela nenhuma), cria o atalho **Steam Status Scheduler** no Menu Iniciar e já abre a tela de configuração.

## Configurar

Tecla Windows, digite **Steam Status Scheduler**, Enter (ou `Configurar.bat` na pasta de instalação). Abre isso:

```
   ___ _____ ___   _   __  __    ___ _____ _ _____ _   _ ___
  / __|_   _| __| /_\ |  \/  |  / __|_   _/_\_   _| | | / __|
  \__ \ | | | _| / _ \| |\/| |  \__ \ | |/ _ \| | | |_| \__ \
  |___/ |_| |___/_/ \_\_|  |_|  |___/ |_/_/ \_\_|  \___/|___/
                          S C H E D U L E R

+----------------------------------------------------------------------------+
|  Servico: ATIVO                                                            |
+----------------------------------------------------------------------------+
|  JANELAS DE HORARIO                                                        |
|    #  Nome                 Dias                   Horario      Status      |
|    1  fim-de-semana-manha  Sab e Dom              06:00-12:00  invisible   |
|                                                                            |
|  Fora das janelas: online                                                  |
+----------------------------------------------------------------------------+
|  SEMANA  (cada bloco = 30 min)                                             |
|         0     3     6     9     12    15    18    21    24                 |
|   Seg   ................................................                   |
|   Ter   ................................................                   |
|   Qua   ................................................                   |
|   Qui   ................................................                   |
|   Sex   ................................................                   |
|   Sab   ............############........................                   |
|   Dom   ............############........................                   |
|         # invisible  X offline  ~ away  ! busy  = online                   |
+----------------------------------------------------------------------------+
|  [A] Adicionar  [E] Editar  [R] Remover  [P] Status fora das janelas       |
|  [T] Testar agora  [L] Ver log  [S] Salvar  [Q] Sair                       |
+----------------------------------------------------------------------------+
```

- **[A] Adicionar / [E] Editar**: pergunta nome, dias (marca com 1-7, ou `U` = seg a sex, `F` = sab e dom, `T` = todos), horário de início e fim, e o status.
- **[P]**: pra onde voltar quando a janela termina (normalmente `online`).
- **[T] Testar agora**: deixa você invisível por 45 segundos e volta pra online, pra ver que funciona.
- **[L] Ver log**: cada troca de status vira uma linha com data e hora.
- **[S] Salvar**: o serviço lê o novo horário em até 30 segundos, não precisa reiniciar nada.
- O cabeçalho mostra se o serviço está **ATIVO**. Se aparecer PARADO, aperta **[I]** pra iniciar.

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
