"""Sidecar web-GUI voor iSponsorBlockTV. Past de originele container niet aan."""
import json
import os
import re
import threading
import time
from collections import deque
from datetime import datetime, timezone

import docker
from docker.errors import APIError, NotFound
from flask import Flask, Response, jsonify, render_template, request

DATA_DIR = os.environ.get("DATA_DIR", "/app/data")
CONFIG_PATH = os.path.join(DATA_DIR, "config.json")
STATS_PATH = os.path.join(DATA_DIR, "stats.json")
TARGET = os.environ.get("TARGET_CONTAINER", "isponsorblocktv")
IMAGE_REPO = os.environ.get("IMAGE_REPO", "ghcr.io/dmunozv04/isponsorblocktv")
GUI_PASSWORD = os.environ.get("GUI_PASSWORD", "")

CATEGORIES = ["sponsor", "selfpromo", "exclusive_access", "interaction",
              "intro", "outro", "preview", "filler", "music_offtopic", "hook"]
PRESET_TAGS = ["latest", "close-ads-5s"]

app = Flask(__name__)
client = docker.from_env()
file_lock = threading.Lock()
log_buffer = deque(maxlen=500)
ANSI = re.compile(r"\x1b\[[0-9;]*m")


# ---------- helpers ----------
def atomic_write(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=4, ensure_ascii=False)
    os.replace(tmp, path)


def today():
    return datetime.now().strftime("%Y-%m-%d")


def load_stats():
    try:
        with open(STATS_PATH, encoding="utf-8") as f:
            s = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        s = {}
    s.setdefault("total", {"muted": 0, "skipped_ads": 0, "segments": 0})
    s.setdefault("days", {})
    return s


stats = load_stats()


def bump(kind):
    with file_lock:
        stats["total"][kind] += 1
        day = stats["days"].setdefault(today(), {"muted": 0, "skipped_ads": 0, "segments": 0})
        day[kind] += 1
        # bewaar max 60 dagen
        for old in sorted(stats["days"])[:-60]:
            del stats["days"][old]
        atomic_write(STATS_PATH, stats)


def classify(line):
    if " muting" in line:
        return "muted"
    if "Skipping ad" in line:
        return "skipped_ads"
    if "Skipping segment" in line:
        return "segments"
    return None


# ---------- log collector ----------
def handle_line(line):
    line = ANSI.sub("", line).rstrip()
    if not line:
        return
    log_buffer.append(line)
    kind = classify(line)
    if kind:
        bump(kind)


def collector():
    since = int(time.time())
    while True:
        try:
            c = client.containers.get(TARGET)
            if c.status != "running":
                time.sleep(3)
                continue
            buf = b""
            for chunk in c.logs(stream=True, follow=True, since=since, tail=0):
                since = int(time.time())
                buf += chunk
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    handle_line(raw.decode("utf-8", "replace"))
            time.sleep(2)  # stream beëindigd (container gestopt/herstart)
        except (NotFound, APIError, Exception):
            time.sleep(5)


threading.Thread(target=collector, daemon=True, name="log-collector").start()


# ---------- config ----------
def read_config():
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def save_config(mute_ads, skip_ads, categories):
    with file_lock:
        cfg = read_config()  # alleen deze velden aanpassen; rest blijft intact
        with open(CONFIG_PATH + ".bak", "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=4, ensure_ascii=False)
        cfg["mute_ads"] = bool(mute_ads)
        cfg["skip_ads"] = bool(skip_ads)
        cfg["skip_categories"] = [c for c in categories if c in CATEGORIES]
        atomic_write(CONFIG_PATH, cfg)


# ---------- container ----------
def container_info():
    try:
        c = client.containers.get(TARGET)
    except NotFound:
        return {"exists": False}
    image_ref = c.attrs["Config"]["Image"]
    started = c.attrs["State"].get("StartedAt")
    uptime = None
    if c.status == "running" and started:
        dt = datetime.fromisoformat(started[:26].rstrip("Z") + "+00:00")
        uptime = int((datetime.now(timezone.utc) - dt).total_seconds())
    return {"exists": True, "status": c.status, "image": image_ref,
            "tag": image_ref.rsplit(":", 1)[1] if ":" in image_ref.split("/")[-1] else "latest",
            "image_id": c.attrs["Image"][7:19], "uptime": uptime}


def device_status(cfg):
    out = []
    lines = list(log_buffer)
    for d in cfg.get("devices", []):
        name = d.get("name") or d.get("screen_id", "?")
        mine = [l for l in lines if name in l]
        last = mine[-1] if mine else ""
        low = last.lower()
        connected = bool(last) and not any(w in low for w in ("disconnect", "lost", "error", "failed"))
        video = None
        for l in reversed(mine):
            m = re.search(r"(?:video[_ ]?id|v=|watching|playing)\W+([\w-]{11})\b", l, re.I)
            if m:
                video = m.group(1)
                break
        out.append({"name": name, "connected": connected, "video": video, "last": last[-160:]})
    return out


def recreate(target_tag, force=False):
    old = client.containers.get(TARGET)
    a = old.attrs
    new_ref = f"{IMAGE_REPO}:{target_tag}"
    old_ref = a["Config"]["Image"]
    client.images.pull(IMAGE_REPO, tag=target_tag)
    new_img = client.images.get(new_ref)
    if not force and new_img.id == a["Image"] and new_ref == old_ref:
        return {"updated": False, "message": f"Geen nieuwe versie voor '{target_tag}'. Je draait al de nieuwste."}

    hc = a["HostConfig"]
    kwargs = dict(
        name=TARGET, detach=True,
        environment=a["Config"].get("Env") or [],
        volumes=hc.get("Binds") or [],
        network_mode=hc.get("NetworkMode", "host"),
        restart_policy=hc.get("RestartPolicy") or {"Name": "unless-stopped"},
        labels=a["Config"].get("Labels") or {},
    )
    old_image_id = a["Image"]
    old.stop(timeout=15)
    old.remove()
    try:
        client.containers.run(new_ref, **kwargs)
    except Exception:
        client.containers.run(old_image_id, **kwargs)  # rollback
        raise
    return {"updated": True, "message": f"Container opnieuw aangemaakt met {new_ref}."}


# ---------- auth ----------
@app.before_request
def auth():
    if not GUI_PASSWORD:
        return None
    a = request.authorization
    if a and a.username == "admin" and a.password == GUI_PASSWORD:
        return None
    return Response("Login vereist", 401, {"WWW-Authenticate": 'Basic realm="iSponsorBlockTV"'})


# ---------- routes ----------
@app.route("/")
def index():
    return render_template("index.html", categories=CATEGORIES, presets=PRESET_TAGS)


@app.route("/api/status")
def api_status():
    try:
        cfg = read_config()
    except Exception as e:
        cfg = {}
        cfg_error = str(e)
    else:
        cfg_error = None
    with file_lock:
        s = json.loads(json.dumps(stats))
    day = s["days"].get(today(), {"muted": 0, "skipped_ads": 0, "segments": 0})
    return jsonify({
        "container": container_info(),
        "stats": {"total": s["total"], "today": day},
        "config": {"mute_ads": cfg.get("mute_ads", False), "skip_ads": cfg.get("skip_ads", False),
                   "skip_categories": cfg.get("skip_categories", [])},
        "config_error": cfg_error,
        "devices": device_status(cfg),
        "logs": list(log_buffer)[-30:],
    })


@app.route("/api/config", methods=["POST"])
def api_config():
    d = request.get_json(force=True)
    try:
        save_config(d.get("mute_ads"), d.get("skip_ads"), d.get("skip_categories", []))
        client.containers.get(TARGET).restart(timeout=15)
        return jsonify({"ok": True, "message": "Opgeslagen en herstart."})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)}), 500


@app.route("/api/update", methods=["POST"])
def api_update():
    d = request.get_json(force=True)
    tag = (d.get("tag") or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}", tag):
        return jsonify({"ok": False, "message": "Ongeldige tag."}), 400
    try:
        return jsonify({"ok": True, **recreate(tag, bool(d.get("force")))})
    except Exception as e:
        return jsonify({"ok": False, "message": str(e)}), 500


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8095)
