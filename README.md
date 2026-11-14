# qbit-autodelete inteligente

Limpeza segura de torrents do qBittorrent orientada a **maximizar upload por GiB
armazenado**, com historico persistente, retencao e ratio por categoria, limpeza sob
pressao e uma faixa de emergencia para impedir que o filesystem fique cheio.

## O que significa o gatilho de "XYZ GB"

Esse valor normalmente e um *low watermark*: quando o espaco livre cai abaixo dele,
o limpador aceita candidatos de pontuacao mais baixa ate tentar chegar a um *high
watermark*. Ele nao deve ser fixo para qualquer servidor.

Esta versao aceita GB, percentual ou ambos:

```text
livre >= gatilho agressivo                modo normal
critico <= livre < gatilho agressivo      modo agressivo
livre < critico                            modo emergencia
modos de pressao tentam chegar             ao alvo
```

Quando GB e percentual estao configurados, vale o maior limite. Em um volume grande,
uma configuracao somente percentual como `10% / 20% / 30%` (emergencia, agressivo e
alvo) costuma ser mais coerente.

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
CRITICAL_WATERMARK_GB="0"
CRITICAL_WATERMARK_PERCENT="10"
LOW_WATERMARK_PERCENT="20"
HIGH_WATERMARK_PERCENT="30"

NORMAL_MIN_SCORE="65"
AGGRESSIVE_MIN_SCORE="30"
AGGRESSIVE_WITHOUT_HISTORY="false"
AGGRESSIVE_MIN_INACTIVE_HOURS="2"
MAX_DELETE_PER_RUN="20"
MAX_RECLAIM_GB_PER_RUN="500"

EMERGENCY_MIN_SCORE="0"
EMERGENCY_WITHOUT_HISTORY="true"
EMERGENCY_MIN_INACTIVE_HOURS="0"
EMERGENCY_RATIO_PROTECTION_MAX_HOURS="48"
EMERGENCY_MAX_DELETE_PER_RUN="30"
EMERGENCY_MAX_RECLAIM_GB_PER_RUN="800"
```

Em um volume nominal proximo de 6 TB, a limpeza reage antes, com 20% livres, e busca
retornar a 30%. A emergencia entra abaixo de 10%; os bytes exatos dependem da capacidade
que o filesystem reporta. Essa folga absorve varias entradas simultaneas do autobrr.

`AGGRESSIVE_WITHOUT_HISTORY=false` impede que um torrent recem-adicionado seja julgado
sem medicao de upload. As seis amostras iniciais formam a linha de base; depois, uma
race com alto upload por GiB permanece com score baixo, enquanto resultados parados
sobem gradualmente na fila de exclusao. Categorias vindas do autobrr devem ter retencao
e ratio coerentes com cada tracker; as tags `keep` e `never-delete` continuam sendo uma
protecao absoluta.

Somente na emergencia, `EMERGENCY_WITHOUT_HISTORY=true` permite considerar um item sem
as seis horas de aprendizado. `EMERGENCY_MIN_INACTIVE_HOURS=0` dispensa a inatividade
passada. `EMERGENCY_RATIO_PROTECTION_MAX_HOURS` pode encurtar apenas nesse modo o prazo
de protecao de um torrent abaixo do ratio; a categoria, a retencao de emergencia, tags,
estado incompleto e transferencia ativa continuam protegidos.

O timer verifica a politica a cada 30 minutos. A consulta e leve e o contador acumulado
captura o upload entre execucoes, inclusive picos curtos. Os limites de 20 itens/500 GiB
no modo normal ou agressivo e 30 itens/800 GiB na emergencia controlam as rajadas de
exclusao nos HDDs. RAID0 nao oferece redundancia: a falha de um disco pode comprometer
todo o volume, independentemente deste script.

## Politica

### Ultimo recurso opcional para BJ

`LAST_RESORT_ENABLED=true` permite dispensar a retencao minima de torrents **BJ completos**
somente em emergencia e abaixo do mesmo limiar de ultimo recurso do rendimento
(`CRITICAL_WATERMARK_PERCENT × YIELD_OVERRIDE_PERCENT_OF_CRITICAL / 100` quando
o limite percentual governa). Exemplo: 18% × 33% = **5,94% livre**.
Nesse estado, os mais antigos por conclusao sao escolhidos primeiro. Acima do limiar,
a retencao normal/de emergencia continua valendo. O padrao e `false`.

Tags protegidas, incompletos, force start, transferencias ativas e limites por rodada
continuam protegidos conforme a configuracao existente. A excecao nao se aplica a
categorias fora de `BJ `. O espaco e reconferido antes da exclusao:
se ja recuperou, candidatos que dependiam da dispensa de retencao sao retirados.
Isso nao autoriza limpar outro cliente nem garante espaco se so restarem itens protegidos.

Um torrent so pode ser candidato depois de passar pelas protecoes:

- pertence a uma categoria configurada;
- cumpriu a retencao normal ou a retencao especifica de emergencia da categoria;
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
de disco, o limite passa a `AGGRESSIVE_MIN_SCORE`. Abaixo do limite critico entra o
modo de emergencia, com lote proprio e permissao configuravel para candidatos sem
historico. Em todos os modos, os itens de maior pontuacao sao selecionados ate o espaco
estimado atingir o alvo, o limite de itens ou o limite de GiB por execucao. Sob
pressao, caminhos cujos arquivos so possuem blocos mantidos por hardlinks nao contam
como capacidade recuperavel isoladamente. Quando todos os torrents gerenciados que
apontam para o mesmo conjunto de inodes estao elegiveis, eles formam um lote atomico:
o grupo e removido junto e os blocos fisicos sao contabilizados uma unica vez. Se um
dos membros estiver protegido por retencao, ratio, tag ou transferencia ativa, o grupo
inteiro fica fora daquela rodada para nao prometer espaco que continuaria ocupado.

O historico e gravado de forma atomica, e o resumo usado por `qbit-del log` e produzido
como telemetria auxiliar. Uma falha apenas nesses dados gera aviso, mas nao cancela uma
exclusao ja planejada. Isso evita que falta de espaco ou um resumo muito grande bloqueiem
justamente a rotina responsavel por recuperar capacidade.

O resumo separa tamanho logico, estimativa fisica pela contagem de hardlinks e variacao
real observada no filesystem antes/depois da API. Como o qBittorrent pode excluir os
arquivos depois de responder, `PHYSICAL_MEASURE_TIMEOUT_SECONDS` controla por quanto
tempo o script acompanha o `df`. Escritas concorrentes ainda podem afetar a medicao.

## Grupos de arquivos, rendimento e modo de pressao

Esta secao descreve os recursos pensados para maximizar o upload dado o disco.

### Torrents que compartilham arquivos

Somente torrents do qBittorrent em categorias listadas no arquivo de regras sao
gerenciados. Torrents que compartilham arquivos (mesmo caminho ou hardlink) formam um
grupo fisico, que e avaliado e excluido junto. O grupo e o componente conectado: um
torrent que usa so parte dos arquivos de outro continua no mesmo grupo. A selecao avalia
o grupo inteiro em todos os modos: todos os membros precisam passar por retencao, ratio,
inatividade, rendimento, historico e score.

O espaco liberavel conta apenas os inodes cujos nomes estao todos dentro do grupo. Um
arquivo que tambem tem um nome fora do grupo (por exemplo, um hardlink de um torrent em
categoria nao listada) continua no disco e nao entra na estimativa; o torrent de fora do
grupo nunca e selecionado. O resumo de cada rodada informa por que os grupos foram
bloqueados (`pai_retencao`, `pai_ratio`, `sem_recuperacao`, ...).

### Protecao por rendimento

`PROTECT_EFFICIENCY_MIB_PER_GIB_DAY` (0 desliga) impede a selecao de torrents cujo upload
recente, pela media movel ou pela velocidade instantanea, supera o valor em MiB por GiB por
dia. Vale em todos os modos. A unica excecao e a emergencia com o disco livre abaixo de
`YIELD_OVERRIDE_PERCENT_OF_CRITICAL`% do nivel critico, quando nao ha mais nada morto para
apagar. Sem HnR, o piso de ratio e os prazos longos so mantem conteudo parado; use
`min_ratio` 0 nas regras e prazos curtos, e deixe o rendimento decidir.

### Reconferencia antes de excluir

Com `REVERIFY_BEFORE_DELETE=true` o script consulta de novo os candidatos imediatamente
antes de excluir. Tag protegida nova, torrent que voltou a render, force start, torrent que
deixou de estar completo ou membro ausente retiram o **grupo inteiro** da rodada. Se a API
falhar, a exclusao fica para a proxima rodada.

### Modo de pressao (`--pressure-gate`)

`qbit-autodelete --pressure-gate` mede so o disco. Fica em silencio quando o espaco livre
esta acima do nivel baixo, quando outra execucao ocupa o lock ou quando a ultima execucao
completa foi ha menos de `PRESSURE_GATE_MIN_INTERVAL_SECONDS`. Caso contrario faz uma
execucao completa. Com a unit `qbit-autodelete-gate.timer` (a cada 5 minutos) a reserva de
disco pode ser menor, pois a reacao a uma rajada deixa de levar ate 30 minutos.

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
- limites critico, agressivo e alvo de espaco livre em percentual;
- aplicacao opcional do perfil recomendado para racing de alta entrada;
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

Em uma instalacao anterior, primeiro use `update` para trocar os executaveis e o timer
sem alterar o `.env`. Depois use `reconfigure` para adicionar os tres limites; aceite o
perfil de racing quando quiser aplicar os scores, lotes e intervalo de amostragem
recomendados por esta versao.

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
- quantidade, volume, atividade e upload dos torrents gerenciados;
- espaco livre, limites critico/agressivo/alvo e volume que falta recuperar;
- historico pronto, elegiveis, selecionados e faixa de pontuacao;
- ate oito categorias ordenadas por espaco, com score medio e maximo;
- os cinco maiores scores, com eficiencia, inatividade, ratio e swarm;
- torrents realmente removidos, agrupados por categoria;
- horario, tamanho estimado e nome de cada torrent;
- total removido e espaco estimado liberado.

Essas metricas representam o estado observado na ultima execucao, nao uma consulta em
tempo real. Score alto significa maior prioridade de limpeza, mas o status exibido ao
lado do torrent deixa claro se ele foi selecionado, ainda esta aprendendo, esta apenas
elegivel ou permanece bloqueado pelas protecoes.

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
Categoria-Filmes|48|1.0|36
Categoria-Series|72|1.0|48
Tracker-Privado|168|2.0|120
```

O formato e `Categoria|horas_normais|min_ratio|horas_emergencia`. O terceiro campo pode
ser omitido para usar `DEFAULT_MIN_RATIO`; o quarto usa as horas normais quando omitido
e nao pode ser maior que elas. As horas sao uma **retencao minima**, nao uma ordem
automatica de exclusao. A categoria
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

`qbit-del stop`, `start`, `restart` e `status` tratam tambem o timer de pressao quando ele esta instalado.

O modelo da unit define `TimeoutStartSec=20min`: uma varredura travada no disco nao bloqueia
as proximas rodadas em silencio. A prioridade de I/O e `best-effort` baixa; a classe `idle`
fica sem fatia quando o disco esta ocupado. Para alertar falhas, use `OnFailure=` com uma
unit propria. O modo de pressao usa `example/qbit-autodelete-gate.service` e `.timer`.

Se o nome da unit do qBittorrent for conhecido, `After=` pode ser adicionado, mas nao e
obrigatorio: o script ja tenta autenticar novamente quando o cliente ainda esta subindo.

### Impacto em HDD

Uma verificacao a cada 30 minutos e leve: ha uma consulta de metadados na API e uma
leitura de `df`, sem varrer o conteudo dos arquivos. A exclusao em si pode gerar rajadas
de I/O de metadados quando ha muitos arquivos/diretorios. Os controles relevantes sao:

- `MAX_DELETE_PER_RUN` limita a quantidade;
- `MAX_RECLAIM_GB_PER_RUN` limita o volume estimado selecionado;
- `RandomizedDelaySec` evita concentrar a tarefa exatamente na virada do relogio;
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

### Correção 3.7.1: torrents distintos na mesma pasta

O inventário físico consulta `/api/v2/torrents/files` e usa `save_path + name`
para cada arquivo registrado. Não varre a pasta `content_path` inteira, pois
vários torrents podem usar a mesma pasta com arquivos diferentes. Caminhos de
hardlinks são contados uma vez, e a reconferência existente recusa torrents
movidos durante a rodada. Falha da API, caminho inválido ou arquivo completo
que desapareceu bloqueiam a exclusão daquela rodada.

Esta é uma correção no script Bash existente, sem novo serviço, dependência ou
alteração dos valores da política. O limite de recuperação por rodada considera
também o próximo candidato, evitando ultrapassar o teto já configurado.
Teste de regressão: `bash tests/test-file-inventory.sh`.

### Versão 3.8.0: somente categorias do arquivo de regras

O script gerencia apenas torrents do qBittorrent cujas categorias estão no arquivo de
regras. Cada grupo de torrents que compartilham arquivos só é candidato quando todos os
membros são elegíveis; os motivos de bloqueio continuam `pai_<motivo>`. Variáveis de
versões anteriores que não existem mais neste README podem permanecer no arquivo de
configuração: são lidas e ignoradas.
