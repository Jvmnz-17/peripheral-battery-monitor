# Peripheral Battery Monitor

Painel local que mostra o nível de bateria de periféricos sem fio, lendo os
dados que os próprios aplicativos oficiais dos fabricantes já salvam no disco
(MCHOSE HUB e RapooGameDev), sem precisar abrir a interface deles.

Feito para: **MCHOSE V9 PRO** (headset) e **Rapoo VT9 PRO** (mouse) no Windows.
Pode servir de base para outros periféricos desses mesmos apps, mas os
caminhos e o parsing foram construídos por engenharia reversa em cima de
arquivos não documentados — podem quebrar se os fabricantes mudarem o
formato.

## Como funciona

- **MCHOSE HUB** grava o estado de cada dispositivo (incluindo `batteryLevel`)
  em `AppData/Roaming/MCHOSEHUB/files/config/mc_main_store_key.json`. É só ler
  o JSON.
- **RapooGameDev** não persiste a bateria em lugar nenhum de forma direta, mas
  registra em log o pacote bruto que recebe do mouse via USB
  (`VT950InterruputRead "..."`). O último byte desse pacote corresponde à
  porcentagem da bateria — o app decodifica esse log (que usa escaping estilo
  JSON) e extrai o valor.

Um serviço em Python lê essas duas fontes a cada 5 minutos e grava o
resultado no Redis. O painel web lê sempre do Redis (não bate nos arquivos a
cada acesso).

## Rodando

Requer Docker Desktop com WSL2 (Windows).

```bash
cd docker
cp .env.example .env
# edite .env com o caminho do SEU usuário do Windows
docker compose up -d --build
```

Acesse `http://localhost:8765/`.

## Estrutura

```
docker/                 -> versão principal (Docker + Redis)
  app.py                -> leitura dos arquivos + cache no Redis + painel web
  docker-compose.yml
  Dockerfile
  .env.example

legacy-powershell/       -> versão alternativa sem Docker (PowerShell puro)
  battery-monitor.ps1    -> mesmo painel, servido via HttpListener nativo
  Iniciar Battery Monitor.bat
```

## Adaptando para outros periféricos

- Para outro dispositivo MCHOSE: o JSON já suporta múltiplos itens em
  `webIndexList`; ajuste `get_mchose_battery()` em `app.py` para escolher o
  dispositivo certo.
- Para outro mouse/dongle Rapoo: o nome do marcador no log
  (`VT950InterruputRead`) muda por modelo. Abra os `.txt` em
  `AppData/Local/RapooGameDev/Log` enquanto o app oficial está aberto e
  procure por linhas parecidas para achar o marcador certo do seu
  dispositivo.
