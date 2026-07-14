# qbit-autodelete inteligente

Limpeza segura de torrents do qBittorrent orientada a **maximizar upload por GiB
armazenado**, com historico persistente, retencao e ratio por categoria e modo
agressivo opcional quando o filesystem fica com pouco espaco.

## O que significa o gatilho de "XYZ GB"

Esse valor normalmente e um *low watermark*: quando o espaco livre cai abaixo dele,
o limpador aceita candidatos de pontuacao mais baixa ate tentar chegar a um *high
watermark*. Ele nao deve ser fixo para qualquer servidor.

Esta versao aceita GB, percentual ou ambos:

```text
livre >= piso                    modo normal
livre < piso                     modo agressivo
modo agressivo tenta chegar      ao alvo
```

Quando GB e percentual estao configurados, vale o maior limite. Em um volume grande,
uma configuracao somente percentual como `10% -> 15%` costuma ser mais coerente.

## Perfil recomendado: RAID0 unico e racing pelo autobrr

Quando varios HDDs formam um unico filesystem RAID0, configure `STORAGE_PATH` com o
ponto de montagem agregado. O script mede o volume como uma unidade; nao e necessario
informar cada disco. O perfil padrao foi ajustado para servidores de varios terabytes
que recebem torrents automaticamente e precisam manter margem para novas races:

```bash
DISK_PRESSURE_ENABLED="true"
STORAGE_PATH="/PATH/TO/RAID/MOUNT"
LOW_WATERMARK_GB="0"
HIGH_WATERMARK_GB="0"
LOW_WATERMARK_PERCENT="10"
HIGH_WATERMARK_PERCENT="15"

NORMAL_MIN_SCORE="70"
AGGRESSIVE_MIN_SCORE="35"
AGGRESSIVE_WITHOUT_HISTORY="false"
MAX_DELETE_PER_RUN="15"
MAX_RECLAIM_GB_PER_RUN="400"
```

Em um volume nominal proximo de 6 TB, os percentuais reservam aproximadamente 10% para
acionar a limpeza agressiva e buscam retornar a 15%; os bytes exatos dependem da
capacidade que o filesystem reporta. Essa folga absorve entradas simultaneas do autobrr.

`AGGRESSIVE_WITHOUT_HISTORY=false` impede que um torrent recem-adicionado seja julgado
sem medicao de upload. As seis amostras iniciais formam a linha de base; depois, uma
race com alto upload por GiB permanece com score baixo, enquanto resultados parados
sobem gradualmente na fila de exclusao. Categorias vindas do autobrr devem ter retencao
e ratio coerentes com cada tracker; as tags `keep` e `never-delete` continuam sendo uma
protecao absoluta.

O timer horario e suficiente porque o contador acumulado captura todo o upload entre
execucoes, inclusive picos curtos. O limite de 15 itens e 400 GiB por rodada reduz
rajadas de exclusoes nos HDDs. RAID0 nao oferece redundancia: a falha de um disco pode
comprometer todo o volume, independentemente deste script.

## Politica

Um torrent so pode ser candidato depois de passar pelas protecoes:

- pertence a uma categoria configurada;
- cumpriu a retencao minima da categoria;
- cumpriu o ratio minimo ou atingiu o prazo maximo de protecao de ratio;
- esta completo (padrao seguro);
- ficou inativo pelo tempo minimo;
- nao possui uma tag protegida;
- nao esta em transferencia, verificacao, movimentacao ou *force start*.

## Como o upload e medido

A API informa o total acumulado em `uploaded`, mas nao fornece diretamente "upload na
ultima hora". O script grava uma amostra em `STATE_FILE` e calcula na proxima execucao:

```text
upload recente = uploaded atual - uploaded da amostra anterior
eficiencia = upload recente por dia / tamanho armazenado em GiB
```

Uma media movel exponencial evita que uma unica hora excepcional distorca a decisao.
Por padrao sao exigidas seis amostras e seis horas observadas. Durante esse aprendizado,
a limpeza normal nao remove por score; o dry-run continua atualizando o historico.

Se o contador do qBittorrent diminuir por reset ou torrent readicionado, apenas aquele
historico e reiniciado. Torrents que desapareceram sao removidos do estado na gravacao
seguinte, portanto o arquivo nao cresce indefinidamente.

## Pontuacao orientada a upload

Score alto significa **bom candidato a exclusao**:

| Fator | Peso | Pontuacao maxima em |
|---|---:|---:|
| Baixa eficiencia de upload | 45 | zero MiB/GiB/dia |
| Tamanho | 20 | 100 GiB |
| Inatividade desde o ultimo trafego | 20 | 168 horas |
| Concorrencia no swarm | 15 | muitos seeds e nenhum leecher |

Com `UPLOAD_EFFICIENCY_FULL_MIB_PER_GIB_DAY=100`, um torrent que entrega pelo menos
100 MiB por GiB armazenado por dia recebe zero pontos de "baixo upload". Um torrent
sem upload recebe os 45 pontos completos. Leechers representam demanda; muitos seeds
para poucos leechers representam concorrencia e aumentam a chance de exclusao.

Isso preserva o retorno por espaco: entre um torrent de 100 GiB quase parado e um de
10 GiB enviando 2 GiB/dia, o segundo tende a permanecer. Transferencia ativa continua
sendo uma protecao absoluta no instante da verificacao.

No modo normal, apenas candidatos com `NORMAL_MIN_SCORE` sao removidos. Sob pressao
de disco, o limite passa a `AGGRESSIVE_MIN_SCORE` e os itens de maior pontuacao sao
selecionados ate o espaco estimado atingir o alvo, o limite de itens ou o limite de
GiB por execucao.

> O espaco recuperado e uma estimativa. Hardlinks, snapshots, arquivos compartilhados
> e a exclusao assincrona pelo qBittorrent podem fazer o valor real ser diferente.

## Instalador interativo (recomendado)

O instalador apresenta um menu colorido e nao exige editar o script ou as units.
Execute-o a partir da raiz do repositorio:

```bash
chmod +x install.sh
./install.sh
```

Ele solicita `sudo` somente quando precisa alterar o sistema e pergunta:

- usuario Linux que executara o servico;
- endereco, porta, usuario e senha da Web UI do qBittorrent;
- ponto de montagem que armazena os torrents;
- gatilho e alvo de espaco livre em percentual;
- categorias, retencao minima e ratio minimo em uma tabela editavel.

Na pergunta do endereco, pressionar Enter usa `http://127.0.0.1`; a porta e solicitada
separadamente e oferece `8080` como padrao. A senha nao aparece na tela nem no resumo.
Uma instalacao nova sempre usa `DRY_RUN=true`, valida a configuracao como o usuario
escolhido, ativa o timer e executa uma primeira simulacao.

O menu tambem permite reconfigurar, atualizar preservando `.env` e categorias, ver o
status e desinstalar. Antes de substituir arquivos existentes, cria um backup em
`/var/backups/qbit-autodelete`. A desinstalacao preserva configuracao e historico por
padrao e nunca remove os torrents.

Os destinos padrao sao genericos:

| Arquivo | Destino |
|---|---|
| programa | `/usr/local/bin/qbit-autodelete` |
| controle global | `/usr/local/bin/qbit-del` |
| configuracao | `/etc/qbit-autodelete.env` |
| categorias | `/etc/qbit-autodelete.categories` |
| estado | `/var/lib/qbit-autodelete/` |
| units | `/etc/systemd/system/` |

O instalador requer Linux com systemd. Se faltarem dependencias, oferece instalacao
automatica em Arch Linux/CachyOS (`pacman`), Debian/Ubuntu (`apt`), Fedora/RHEL (`dnf`)
e openSUSE (`zypper`). Nenhuma senha ou dado informado e enviado para o repositorio.

As mesmas acoes podem ser abertas diretamente:

```bash
./install.sh install
./install.sh reconfigure
./install.sh update
./install.sh status
./install.sh uninstall
```

## Comando global `qbit-del`

O instalador adiciona `qbit-del` ao PATH do sistema. Ele pode ser chamado de qualquer
diretorio e solicita `sudo` automaticamente nas operacoes que alteram o systemd ou
leem o journal completo:

```bash
qbit-del run       # executa uma verificacao manual agora
qbit-del stop      # para timer e servico
qbit-del start     # inicia o timer e executa uma verificacao
qbit-del restart   # reinicia timer e servico
qbit-del status    # painel colorido do timer e da ultima execucao
qbit-del log       # relatorio colorido da ultima execucao
```

`qbit-del status` mostra se o timer esta ativo e habilitado no boot, ultimo e proximo
disparo, resultado e horarios da ultima execucao. Como o servico e `oneshot`, ele fica
inativo depois de concluir; o painel diferencia esse estado de uma falha.

`qbit-del log` le os eventos estruturados da ultima execucao no journal e apresenta:

- data, hora, modo real ou `DRY_RUN` e resultado;
- confirmacao da conexao com o qBittorrent;
- torrents realmente removidos, agrupados por categoria;
- horario, tamanho estimado e nome de cada torrent;
- total removido e espaco estimado liberado.

O relatorio nao registra nem exibe credenciais. O espaco e estimado porque hardlinks,
snapshots e arquivos compartilhados podem mudar o ganho real no filesystem. Logs
anteriores a instalacao desta versao continuam disponiveis no journal, mas nao possuem
os eventos necessarios para montar o painel estruturado.

### Instalacao manual

Se preferir nao usar o instalador, nao e necessario editar o script. Copie os dois modelos:

```bash
sudo install -m 0755 qbit-autodelete.sh /PATH/TO/qbit-autodelete
sudo install -m 0755 qbit-del /usr/local/bin/qbit-del
sudo install -m 0640 -o root -g QBIT_SERVICE_GROUP example/qbit_autodelete.env /PATH/TO/qbit-autodelete.env
sudo install -m 0644 example/qbit-autodelete.categories /PATH/TO/qbit-autodelete.categories
sudo editor /PATH/TO/qbit-autodelete.env
sudo editor /PATH/TO/qbit-autodelete.categories
```

As categorias aceitam espacos e um ratio minimo opcional:

```text
Categoria-Filmes|48|1.0
Categoria-Series|72|1.0
Tracker-Privado|168|2.0
```

O formato e `Categoria|horas|min_ratio`. O terceiro campo pode ser omitido para usar
`DEFAULT_MIN_RATIO`. As horas sao uma **retencao minima**, nao uma ordem automatica de exclusao. A categoria
deve coincidir exatamente com o qBittorrent. Para instalar em outro servidor, basta
copiar o script e criar novos arquivos em `/etc`; URL, porta, credenciais, caminhos e
politica nao ficam misturados ao codigo.

## Teste seguro

O modelo vem com `DRY_RUN="true"`. Valide e simule antes de habilitar exclusoes:

```bash
qbit-autodelete --config /etc/qbit-autodelete.env --check-config
qbit-autodelete --config /etc/qbit-autodelete.env --dry-run
```

Deixe o timer acumular pelo menos seis amostras e revise nomes, eficiencia, scores,
tamanhos, swarm e ratio mostrados. Depois altere apenas:

```text
DRY_RUN="false"
```

Nunca versione a senha. Proteja o `.env` com modo `0640` ou mais restritivo. A opcao
`ALLOW_INCOMPLETE_DELETE` deve continuar `false` salvo se a perda de downloads parciais
for deliberada.

## systemd

O par `Type=oneshot` + timer e apropriado: nao mantem outro daemon residente, registra
inicio/fim/erro e o systemd nao inicia uma segunda instancia da mesma unit enquanto ela
ja estiver ativa. `StateDirectory=qbit-autodelete` cria um diretorio de estado persistente
com permissao para o usuario do servico. O instalador faz esta etapa automaticamente.
Na instalacao manual, instale os modelos depois de substituir todos os placeholders:

```bash
sudo install -m 0644 example/qbit-autodelete.service /etc/systemd/system/
sudo install -m 0644 example/qbit-autodelete.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now qbit-autodelete.timer
systemctl list-timers qbit-autodelete.timer
journalctl -u qbit-autodelete.service -n 100 --no-pager
```

Se o nome da unit do qBittorrent for conhecido, `After=` pode ser adicionado, mas nao e
obrigatorio: o script ja tenta autenticar novamente quando o cliente ainda esta subindo.

### Impacto em HDD

Uma verificacao por hora e leve: ha uma consulta de metadados na API e uma leitura de
`df`, sem varrer o conteudo dos arquivos. A exclusao em si pode gerar rajadas de I/O de
metadados quando ha muitos arquivos/diretorios. Os controles relevantes sao:

- `MAX_DELETE_PER_RUN` limita a quantidade;
- `MAX_RECLAIM_GB_PER_RUN` limita o volume estimado selecionado;
- `RandomizedDelaySec` evita concentrar a tarefa exatamente na virada da hora;
- o modo normal com score alto evita apagar em todo ciclo sem necessidade.

O `Nice=10` reduz a prioridade do script, mas a remocao dos arquivos ocorre no processo
do qBittorrent; os limites de lote sao a protecao mais efetiva para o HDD.

## Diagnostico

```bash
systemctl status qbit-autodelete.timer qbit-autodelete.service
journalctl -u qbit-autodelete.service --since today
systemctl start qbit-autodelete.service
```

Dependencias: Bash 4+, `curl`, `jq`, `coreutils`, `awk`, `util-linux` (`flock`) e Linux
com systemd para o agendamento sugerido.
