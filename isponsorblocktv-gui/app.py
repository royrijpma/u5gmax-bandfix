"""Sidecar Web-GUI voor iSponsorBlockTV. Wijzigt de upstream-container niet,
beheert alleen config.json, stats.json en de container via de Docker socket."""
import json, os, re, threading, time
from datetime import datetime, timezone
import docker
from flask import Flask, jsonify, render_template, request

TARGET = os.environ.get("TARGET_CONTAINER", "isponsorblocktv")
REPO = os.environ.get("IMAGE_REPO", "ghcr.io/dmunozv04/isponsorblocktv")
DATA_DIR = os.environ.get("DATA_DIR", "/app/data")
HOST_DATA_DIR = os.environ.get("HOST_DATA_DIR", "/Volume1/docker/isponsorblocktv/data")
CONFIG_PATH = os.path.join(DATA_DIR, "config.json")
STATS_PATH = os.path.join(DATA_DIR, "stats.json")
CATEGORIES = ["sponsor", "selfpromo", "exclusive_access", "interaction", "intro",
              "outro", "preview", "filler", "music_offtopic", "hook"]
PATTERNS = {"muted": " muting", "skipped_ads": "Skipping ad", "skipped_segments": "Skipping segment"}

app = Flask(__name__)
client = docker.from_env()
lock = threading.Lock()
recent = []          # laatste logregels voor TV-status (max 500)
RECENT_MAX = 500


# ---------- stats ----------
def _empty():
    return {k: 0 for k in PATTERNS}

def load_stats():
    try:
        with open(STATS_PATH) as f:
            s = json.load(f)
    except (OSError, ValueError):
        s = {}
    s.setdefault("total", _empty()); s.setdefault("days", {}); s.setdefault("last_ts", 0)
    return s

def save_stats(s):
    cutoff = sorted(s["days"])[-90:]
    s["days"] = {d: s["days"][d] for d in cutoff}
    tmp = STATS_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f, indent=2)
    os.replace(tmp, STATS_PATH)

stats = load_stats()

def parse_line(raw):
    """Docker timestamps=True: '2026-01-01T12:00:00.123456789Z tekst'."""
    text = raw.decode("utf-8", "replace").rstrip()
    ts, _, msg = text.partition(" ")
    try:
        epoch = datetime.fromisoformat(ts[:26].rstrip("Z") + "+00:00").timestamp()
    except ValueError:
        return None, text
    return epoch, msg

def count_line(msg, epoch):
    hit = [k for k, p in PATTERNS.items() if p in msg]
    if not hit:
        return
    day = datetime.fromtimestamp(epoch).strftime("%Y-%m-%d")
    with lock:
        d = stats["days"].setdefault(day, _empty())
        for k in hit:
            stats["total"][k] += 1; d[k] += 1

def log_watcher():
    last_save = 0
    while True:
        try:
            c = client.containers.get(TARGET)
            since = stats["last_ts"] or time.time()
            for raw in c.logs(stream=True, follow=True, timestamps=True, since=since):
                epoch, msg = parse_line(raw)
                if epoch is None or epoch <= stats["last_ts"]:
                    continue
                recent.append(msg)
                del recent[:-RECENT_MAX]
                count_line(msg, epoch)
                with lock:
                    stats["last_ts"] = epoch
                    if time.time() - last_save > 5:
                        save_stats(stats); last_save = time.time()
        except Exception as e:
            print("log watcher:", e, flush=True)
        with lock:
            save_stats(stats)
        time.sleep(5)   # container herstart/bestaat niet: opnieuw proberen

_started = False
def start_watcher():
    global _started
    if not _started:
        _started = True
        threading.Thread(target=log_watcher, daemon=True).start()
start_watcher()


# ---------- config ----------
def read_config():
    with open(CONFIG_PATH) as f:
        return json.load(f)

@app.get("/api/config")
def get_config():
    try:
        cfg = read_config()
    except (OSError, ValueError) as e:
        return jsonify(error=str(e)), 500
    return jsonify(mute_ads=cfg.get("mute_ads", False), skip_ads=cfg.get("skip_ads", False),
                   skip_categories=cfg.get("skip_categories", []), all_categories=CATEGORIES)

@app.post("/api/config")
def save_config():
    body = request.get_json(force=True)
    cfg = read_config()                      # alles wat we niet kennen blijft intact
    cfg["mute_ads"] = bool(body.get("mute_ads"))
    cfg["skip_ads"] = bool(body.get("skip_ads"))
    cfg["skip_categories"] = [c for c in body.get("skip_categories", []) if c in CATEGORIES]
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH + ".bak", "w") as f:
            json.dump(read_config(), f, indent=2)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(cfg, f, indent=2)
    os.replace(tmp, CONFIG_PATH)
    try:
        client.containers.get(TARGET).restart(timeout=15)
    except docker.errors.DockerException as e:
        return jsonify(error=f"Opgeslagen, maar herstart mislukt: {e}"), 500
    return jsonify(ok=True)


# ---------- status ----------
def uptime_seconds(c):
    if c.status != "running":
        return None
    started = c.attrs["State"]["StartedAt"][:26].rstrip("Z")
    dt = datetime.fromisoformat(started).replace(tzinfo=timezone.utc)
    return int((datetime.now(timezone.utc) - dt).total_seconds())

@app.get("/api/status")
def status():
    try:
        c = client.containers.get(TARGET)
    except docker.errors.NotFound:
        return jsonify(found=False)
    image = c.attrs["Config"]["Image"]
    return jsonify(found=True, status=c.status, image=image,
                   tag=image.rsplit(":", 1)[1] if ":" in image.split("/")[-1] else "latest",
                   uptime=uptime_seconds(c), image_id=c.image.short_id)

@app.get("/api/stats")
def get_stats():
    today = datetime.now().strftime("%Y-%m-%d")
    with lock:
        return jsonify(total=stats["total"], today=stats["days"].get(today, _empty()))

@app.get("/api/logs")
def logs():
    return jsonify(lines=recent[-30:])

VIDEO_RE = re.compile(r"(?:video[_ ]?id|watching|playing)\D{0,6}([\w-]{11})\b", re.I)

@app.get("/api/tvs")
def tvs():
    try:
        devices = read_config().get("devices", [])
    except (OSError, ValueError):
        devices = []
    out = []
    for d in devices:
        name = d.get("name") or d.get("screen_id", "?")
        mine = [l for l in recent if name.lower() in l.lower()]
        connected, video = None, None
        for l in reversed(mine):
            low = l.lower()
            if connected is None:
                if "disconnect" in low or "lost" in low:
                    connected = False
                elif "connect" in low or "paired" in low:
                    connected = True
            if video is None and (m := VIDEO_RE.search(l)):
                video = m.group(1)
        if connected is None and mine:
            connected = True
        out.append(dict(name=name, connected=connected, video_id=video))
    return jsonify(tvs=out)


# ---------- image / update ----------
@app.post("/api/update")
def update():
    body = request.get_json(force=True)
    tag = (body.get("custom_tag") or body.get("tag") or "latest").strip()
    if not re.fullmatch(r"[\w][\w.-]{0,127}", tag):
        return jsonify(error="Ongeldige tag"), 400
    ref = f"{REPO}:{tag}"
    try:
        old = client.containers.get(TARGET)
    except docker.errors.NotFound:
        return jsonify(error="Container niet gevonden"), 404
    old_ref, old_id = old.attrs["Config"]["Image"], old.image.id
    try:
        new_img = client.images.pull(REPO, tag=tag)
    except docker.errors.DockerException as e:
        return jsonify(error=f"Pull mislukt: {e}"), 502
    if old_ref == ref and old_id == new_img.id and not body.get("force"):
        return jsonify(ok=True, changed=False, message=f"{ref} is al up-to-date.")

    h = old.attrs["HostConfig"]
    env = old.attrs["Config"].get("Env") or []
    if not any(e.startswith("TZ=") for e in env):
        env.append("TZ=Europe/Amsterdam")
    binds = h.get("Binds") or [f"{HOST_DATA_DIR}:/app/data"]
    old.stop(timeout=15)
    old.remove()
    client.containers.run(ref, name=TARGET, detach=True, network_mode=h.get("NetworkMode") or "host",
                          restart_policy=h.get("RestartPolicy") or {"Name": "unless-stopped"},
                          environment=env, volumes=binds)
    with lock:
        stats["last_ts"] = stats["last_ts"]  # tellers blijven; watcher pakt nieuwe container op
    return jsonify(ok=True, changed=True, message=f"Nu actief: {ref}")

@app.post("/api/restart")
def restart():
    client.containers.get(TARGET).restart(timeout=15)
    return jsonify(ok=True)

@app.get("/")
def index():
    return render_template("index.html")
