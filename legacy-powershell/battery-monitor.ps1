# Battery Monitor - local dashboard for MCHOSE HUB and RapooGameDev peripherals
# Serves a small web UI at http://localhost:8765/ by reading each app's local data files.

$Port = 8765
$McHoseConfig = "$env:APPDATA\MCHOSEHUB\files\config\mc_main_store_key.json"
$RapooLogDir  = "$env:LOCALAPPDATA\RapooGameDev\Log"

function Get-McHoseBattery {
    try {
        if (-not (Test-Path $McHoseConfig)) { return $null }
        $json = Get-Content -Path $McHoseConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        $dev = $json.webIndexList | Select-Object -First 1
        if (-not $dev) { return $null }
        [pscustomobject]@{
            name    = $dev.productName
            percent = [int]$dev.batteryLevel
            status  = $dev.chargeStatusElectron
        }
    } catch { return $null }
}

function Get-RapooBatteryPercent {
    try {
        $files = Get-ChildItem "$RapooLogDir\*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 3
        foreach ($f in $files) {
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            $marker = [System.Text.Encoding]::ASCII.GetBytes('VT950InterruputRead "')
            $lastStart = -1
            for ($i = 0; $i -le $bytes.Length - $marker.Length; $i++) {
                $match = $true
                for ($j = 0; $j -lt $marker.Length; $j++) { if ($bytes[$i+$j] -ne $marker[$j]) { $match = $false; break } }
                if ($match) { $lastStart = $i + $marker.Length }
            }
            if ($lastStart -ge 0) {
                $pos = $lastStart
                $lastByte = -1
                while ($pos -lt $bytes.Length) {
                    $b = $bytes[$pos]
                    if ($b -eq 0x22) { break }
                    if ($b -eq 0x5C -and ($pos + 1) -lt $bytes.Length) {
                        $n = [char]$bytes[$pos + 1]
                        if ($n -eq 'n') { $lastByte = 0x0A; $pos += 2 }
                        elseif ($n -eq 'r') { $lastByte = 0x0D; $pos += 2 }
                        elseif ($n -eq 't') { $lastByte = 0x09; $pos += 2 }
                        elseif ($n -eq 'b') { $lastByte = 0x08; $pos += 2 }
                        elseif ($n -eq 'f') { $lastByte = 0x0C; $pos += 2 }
                        elseif ($n -eq '\') { $lastByte = 0x5C; $pos += 2 }
                        elseif ($n -eq '"') { $lastByte = 0x22; $pos += 2 }
                        elseif ($n -eq 'u') {
                            $hexChars = @()
                            for ($k = 0; $k -lt 4; $k++) { $hexChars += [char]$bytes[$pos + 2 + $k] }
                            $lastByte = [Convert]::ToInt32((-join $hexChars), 16)
                            $pos += 6
                        } else { $lastByte = [int]$n; $pos += 2 }
                    } else { $lastByte = $b; $pos += 1 }
                }
                if ($lastByte -ge 0) { return $lastByte }
            }
        }
        return $null
    } catch { return $null }
}

function Get-BatteryJson {
    $mchose = Get-McHoseBattery
    $rapooPct = Get-RapooBatteryPercent

    $devices = @()
    if ($mchose) {
        $devices += [pscustomobject]@{
            name    = $mchose.name
            kind    = "headset"
            percent = $mchose.percent
            status  = $mchose.status
        }
    }
    if ($null -ne $rapooPct) {
        $devices += [pscustomobject]@{
            name    = "Rapoo VT9 PRO"
            kind    = "mouse"
            percent = $rapooPct
            status  = $null
        }
    }

    [pscustomobject]@{
        updatedAt = (Get-Date).ToString("HH:mm:ss")
        devices   = $devices
    } | ConvertTo-Json -Depth 4
}

$Html = @'
<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Bateria dos Perifericos</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root { color-scheme: light dark; }
  body {
    font-family: -apple-system, Segoe UI, Roboto, sans-serif;
    background: #111318; color: #eee;
    margin: 0; padding: 40px 20px;
    display: flex; flex-direction: column; align-items: center;
  }
  h1 { font-size: 20px; font-weight: 600; margin-bottom: 4px; }
  .updated { color: #888; font-size: 13px; margin-bottom: 28px; }
  .cards { display: flex; gap: 20px; flex-wrap: wrap; justify-content: center; max-width: 700px; }
  .card {
    background: #1b1e26; border-radius: 16px; padding: 22px 26px;
    width: 220px; box-shadow: 0 4px 16px rgba(0,0,0,0.3);
  }
  .icon { font-size: 28px; }
  .name { font-size: 15px; font-weight: 600; margin-top: 8px; }
  .kind { font-size: 12px; color: #888; margin-bottom: 14px; text-transform: uppercase; letter-spacing: 0.04em; }
  .pct { font-size: 32px; font-weight: 700; }
  .bar-track { background: #2a2e38; border-radius: 6px; height: 8px; margin-top: 10px; overflow: hidden; }
  .bar-fill { height: 100%; border-radius: 6px; transition: width 0.4s; }
  .status { font-size: 12px; color: #888; margin-top: 8px; }
  .empty { color: #888; margin-top: 40px; }
</style>
</head>
<body>
  <h1>Bateria dos Perifericos</h1>
  <div class="updated" id="updated">carregando...</div>
  <div class="cards" id="cards"></div>

<script>
const ICONS = { headset: "\u{1F3A7}", mouse: "\u{1F5B1}\u{FE0F}" };
const NAMES = { headset: "fone", mouse: "mouse" };

function colorFor(pct) {
  if (pct <= 20) return "#e5484d";
  if (pct <= 45) return "#f5a623";
  return "#3ecf6e";
}

async function refresh() {
  try {
    const res = await fetch("/api/battery", { cache: "no-store" });
    const data = await res.json();
    const devices = Array.isArray(data.devices) ? data.devices : (data.devices ? [data.devices] : []);
    document.getElementById("updated").textContent = "atualizado as " + data.updatedAt;

    const container = document.getElementById("cards");
    if (devices.length === 0) {
      container.innerHTML = '<div class="empty">Nenhum dispositivo encontrado. Abra o MCHOSE HUB ou o RapooGameDev.</div>';
      return;
    }

    container.innerHTML = devices.map(d => `
      <div class="card">
        <div class="icon">${ICONS[d.kind] || "\u{1F50B}"}</div>
        <div class="name">${d.name}</div>
        <div class="kind">${NAMES[d.kind] || d.kind}</div>
        <div class="pct" style="color:${colorFor(d.percent)}">${d.percent}%</div>
        <div class="bar-track"><div class="bar-fill" style="width:${d.percent}%;background:${colorFor(d.percent)}"></div></div>
        ${d.status ? `<div class="status">${d.status === "discharge" ? "descarregando" : d.status}</div>` : ""}
      </div>
    `).join("");
  } catch (e) {
    document.getElementById("updated").textContent = "erro ao atualizar";
  }
}

refresh();
setInterval(refresh, 5000);
</script>
</body>
</html>
'@

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Battery Monitor rodando em http://localhost:$Port/  (Ctrl+C para parar)"

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response
        try {
            if ($request.Url.AbsolutePath -eq "/api/battery") {
                $body = [System.Text.Encoding]::UTF8.GetBytes((Get-BatteryJson))
                $response.ContentType = "application/json; charset=utf-8"
                $response.ContentLength64 = $body.Length
                $response.OutputStream.Write($body, 0, $body.Length)
            } else {
                $body = [System.Text.Encoding]::UTF8.GetBytes($Html)
                $response.ContentType = "text/html; charset=utf-8"
                $response.ContentLength64 = $body.Length
                $response.OutputStream.Write($body, 0, $body.Length)
            }
        } finally {
            $response.OutputStream.Close()
        }
    }
} finally {
    $listener.Stop()
}
