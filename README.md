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

Nos dois casos ele instala em `%LOCALAPPDATA%\SteamStatusScheduler` (algo como `C:\Users\SEU_NOME\AppData\Local\SteamStatusScheduler`) e cria uma tarefa agendada que inicia junto com o Windows, sem janela nenhuma.

## Mudar os horários

Na pasta de instalação, dê duplo clique em **`Editar-horarios.bat`** (abre o `config.json` no Bloco de Notas):

```json
{
  "pollSeconds": 30,
  "steamStartupGraceSeconds": 45,
  "defaultStatus": "online",
  "windows": [
    {
      "name": "fim-de-semana-manha",
      "days": ["Saturday", "Sunday"],
      "start": "06:00",
      "end": "12:00",
      "status": "invisible"
    }
  ]
}
```

- `days`: dias em inglês: `Monday`, `Tuesday`, `Wednesday`, `Thursday`, `Friday`, `Saturday`, `Sunday` (ou `Mon`, `Tue`...).
- `start` / `end`: horário no formato `HH:mm`, dentro do mesmo dia (`start` menor que `end`).
- `status`: o que aplicar na janela:
  - `invisible`: aparece offline pros amigos, mas você ainda vê a lista e recebe mensagens. **É o recomendado.**
  - `offline`: modo "Ficar offline" da Steam, desconecta do chat de amigos.
  - `away`, `busy`, `online` também valem.
- `defaultStatus`: pra onde voltar quando a janela termina (normalmente `online`).
- Pode ter várias janelas na lista `windows`, é só copiar o bloco entre chaves e separar por vírgula.

Salvou o arquivo, pronto. Não precisa reiniciar nada, ele relê o config sozinho.

## Saber se está funcionando

Duplo clique em **`Ver-status.bat`** na pasta de instalação. Mostra se a tarefa está `Running` e as últimas linhas do log (cada troca de status vira uma linha com data e hora).

Também dá pra ver no **Agendador de Tarefas** do Windows: a tarefa se chama `SteamStatusScheduler`.

## Desinstalar

Duplo clique em **`Desinstalar.bat`** na pasta de instalação. Remove a tarefa e apaga a pasta. Se você estava invisível por causa dele, volta pra online antes de sair.

## Como funciona

- Um script PowerShell fica rodando escondido e, a cada 30 segundos (`pollSeconds`), confere o dia e a hora.
- Quando entra numa janela do `config.json` e a Steam está aberta, manda o comando `steam://friends/status/invisible` pra própria Steam. Só uma vez por janela: se você trocar o status na mão no meio, ele respeita.
- Quando a janela termina, manda `steam://friends/status/online` (ou o `defaultStatus`).
- Se a Steam estiver fechada no começo da janela, aplica assim que ela abrir (espera 45 segundos pra ela terminar de logar).
- Estado e log ficam na pasta de instalação: `state.json` e `scheduler.log`.

Limitações: a janela precisa começar e terminar no mesmo dia (sem virar a madrugada, por enquanto). O script só mexe no status de amigos, não interfere nos jogos.

## Licença

MIT. Faça o que quiser.
