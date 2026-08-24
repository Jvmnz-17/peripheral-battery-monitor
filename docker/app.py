import os
import json
import time
import threading
from datetime import datetime

import redis
from flask import Flask, jsonify, Response

MCHOSE_CONFIG = "/data/mchose/mc_main_store_key.json"
RAPOO_LOG_DIR = "/data/rapoo-log"
REFRESH_SECONDS = int(os.environ.get("REFRESH_SECONDS", 300))
REDIS_HOST = os.environ.get("REDIS_HOST", "redis")
REDIS_PORT = int(os.environ.get("REDIS_PORT", 6379))
CACHE_KEY = "battery:snapshot"

r = redis.Redis(host=REDIS_HOST, port=REDIS_PORT, decode_responses=True)
app = Flask(__name__)


def get_mchose_battery():
    try:
        with open(MCHOSE_CONFIG, "r", encoding="utf-8") as f:
            data = json.load(f)
        devices = data.get("webIndexList") or []
        if not devices:
            return None
        dev = devices[0]
        return {
            "name": dev.get("productName"),
            "kind": "headset",
            "percent": int(dev.get("batteryLevel", 0)),
            "status": dev.get("chargeStatusElectron"),
        }
    except Exception:
        return None


def decode_last_byte(content: bytes):
    # Decodes the JSON-style escaped byte string Qt writes to the log, returning
    # the value of the last byte before the closing quote (the battery percent).
    i = 0
    last = None
    n = len(content)
    simple = {"n": 0x0A, "r": 0x0D, "t": 0x09, "b": 0x08, "f": 0x0C, "\\": 0x5C, '"': 0x22}
    while i < n:
        b = content[i]
        if b == 0x22:
            break
        if b == 0x5C and i + 1 < n:
            nxt = chr(content[i + 1])
            if nxt in simple:
                last = simple[nxt]
                i += 2
            elif nxt == "u" and i + 6 <= n:
                hex_str = content[i + 2:i + 6].decode("ascii", errors="ignore")
                last = int(hex_str, 16)
                i += 6
            else:
                last = ord(nxt)
                i += 2
        else:
            last = b
            i += 1
    return last


def get_rapoo_battery():
    try:
        if not os.path.isdir(RAPOO_LOG_DIR):
            return None
        files = sorted(
            (os.path.join(RAPOO_LOG_DIR, f) for f in os.listdir(RAPOO_LOG_DIR) if f.endswith(".txt")),
            key=os.path.getmtime,
            reverse=True,
        )[:3]
        marker = b'VT950InterruputRead "'
        for path in files:
            with open(path, "rb") as f:
                data = f.read()
            idx = data.rfind(marker)
            if idx == -1:
                continue
            content = data[idx + len(marker):]
            pct = decode_last_byte(content)
            if pct is not None:
                return {"name": "Rapoo VT9 PRO", "kind": "mouse", "percent": pct, "status": None}
        return None
    except Exception:
        return None


def refresh_loop():
    while True:
        devices = []
        mchose = get_mchose_battery()
        if mchose:
            devices.append(mchose)
        rapoo = get_rapoo_battery()
        if rapoo:
            devices.append(rapoo)
        snapshot = {"updatedAt": datetime.now().strftime("%H:%M:%S"), "devices": devices}
        r.set(CACHE_KEY, json.dumps(snapshot))
        time.sleep(REFRESH_SECONDS)


@app.route("/api/battery")
def api_battery():
    cached = r.get(CACHE_KEY)
    if cached:
        return Response(cached, mimetype="application/json")
    return jsonify({"updatedAt": None, "devices": []})


HTML = """<!doctype html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Bateria dos Perifericos</title>
<link rel="icon" href="data:image/svg+xml,<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'><text y='.9em' font-size='90'>%F0%9F%94%8B</text></svg>">
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
  .updated { color: #888; font-size: 13px; margin-bottom: 4px; }
  .source { color: #555; font-size: 11px; margin-bottom: 28px; }
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
  <div class="source">cache no Redis, atualizado a cada 5 min</div>
  <div class="cards" id="cards"></div>

<script>
const ICONS = { headset: "\\u{1F3A7}", mouse: "\\u{1F5B1}\\u{FE0F}" };
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
    const devices = Array.isArray(data.devices) ? data.devices : [];
    document.getElementById("updated").textContent = data.updatedAt
      ? "ultima leitura as " + data.updatedAt
      : "aguardando primeira leitura...";

    const container = document.getElementById("cards");
    if (devices.length === 0) {
      container.innerHTML = '<div class="empty">Nenhum dispositivo encontrado ainda.</div>';
      return;
    }

    container.innerHTML = devices.map(d => `
      <div class="card">
        <div class="icon">${ICONS[d.kind] || "\\u{1F50B}"}</div>
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
setInterval(refresh, 30000);
</script>
</body>
</html>
"""


@app.route("/")
def index():
    return Response(HTML, mimetype="text/html")


if __name__ == "__main__":
    threading.Thread(target=refresh_loop, daemon=True).start()
    app.run(host="0.0.0.0", port=8765)
