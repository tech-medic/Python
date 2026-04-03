"""AI Surveillance Camera — Web Dashboard Service."""

import json
import logging
import os
import threading
import time

import psutil
import psycopg2
import psycopg2.extras
import redis
import yaml
from flask import Flask, Response, jsonify, render_template, request, send_from_directory
from flask_socketio import SocketIO

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
)
log = logging.getLogger("web")

app = Flask(__name__)
app.config["SECRET_KEY"] = os.urandom(24).hex()
socketio = SocketIO(app, async_mode="gevent", cors_allowed_origins="*")

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")
DATABASE_URL = os.environ.get("DATABASE_URL", "")
CONFIG_PATH = "/app/config/config.yaml"

rdb = redis.Redis.from_url(REDIS_URL)


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def get_db():
    return psycopg2.connect(DATABASE_URL)


# ── Routes ──────────────────────────────────────────────────────────────

@app.route("/")
def index():
    return render_template("index.html")


@app.route("/health")
def health():
    return jsonify({"status": "ok"})


@app.route("/api/events")
def api_events():
    """Return detection events with optional filters."""
    object_class = request.args.get("class")
    date_from = request.args.get("from")
    date_to = request.args.get("to")
    limit = min(int(request.args.get("limit", 100)), 500)
    offset = int(request.args.get("offset", 0))

    query = "SELECT * FROM detection_events WHERE 1=1"
    params = []

    if object_class:
        query += " AND object_class = %s"
        params.append(object_class)
    if date_from:
        query += " AND timestamp >= %s"
        params.append(date_from)
    if date_to:
        query += " AND timestamp <= %s"
        params.append(date_to)

    query += " ORDER BY timestamp DESC LIMIT %s OFFSET %s"
    params.extend([limit, offset])

    conn = get_db()
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(query, params)
        rows = cur.fetchall()

        cur.execute("SELECT COUNT(*) FROM detection_events")
        total = cur.fetchone()["count"]
    conn.close()

    for row in rows:
        row["timestamp"] = row["timestamp"].isoformat()
        if row.get("snapshot_path"):
            row["snapshot_url"] = "/snapshots/" + row["snapshot_path"].split("/")[-1]
        if row.get("clip_path"):
            row["clip_url"] = "/clips/" + row["clip_path"].split("/")[-1]

    return jsonify({"events": rows, "total": total})


@app.route("/api/stats")
def api_stats():
    """Return system and detector stats."""
    detector_stats = {}
    try:
        raw = rdb.get("surveillance:stats")
        if raw:
            detector_stats = json.loads(raw)
    except redis.RedisError:
        pass

    detector_stats["cpu_percent"] = psutil.cpu_percent(interval=0.1)
    detector_stats["memory_percent"] = psutil.virtual_memory().percent
    return jsonify(detector_stats)


@app.route("/api/classes")
def api_classes():
    """Return distinct detected object classes."""
    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT DISTINCT object_class FROM detection_events ORDER BY object_class")
        classes = [r[0] for r in cur.fetchall()]
    conn.close()
    return jsonify(classes)


# ── Static file serving for clips/snapshots ─────────────────────────────

@app.route("/clips/<path:filename>")
def serve_clip(filename):
    return send_from_directory("/app/data/clips", filename)


@app.route("/snapshots/<path:filename>")
def serve_snapshot(filename):
    return send_from_directory("/app/data/snapshots", filename)


# ── MJPEG Stream ────────────────────────────────────────────────────────

def generate_mjpeg():
    """Yield MJPEG frames from Redis."""
    while True:
        try:
            frame_data = rdb.get("surveillance:latest_frame")
            if frame_data:
                yield (
                    b"--frame\r\n"
                    b"Content-Type: image/jpeg\r\n\r\n" + frame_data + b"\r\n"
                )
            else:
                time.sleep(0.1)
        except redis.RedisError:
            time.sleep(0.5)
        time.sleep(0.05)


@app.route("/stream")
def video_stream():
    return Response(
        generate_mjpeg(),
        mimetype="multipart/x-mixed-replace; boundary=frame",
    )


# ── WebSocket: real-time events via Redis pub/sub ───────────────────────

def redis_event_listener():
    """Subscribe to Redis detection events and forward via WebSocket."""
    pubsub = rdb.pubsub()
    pubsub.subscribe("surveillance:events")
    log.info("Redis event listener started")

    for message in pubsub.listen():
        if message["type"] == "message":
            try:
                event = json.loads(message["data"])
                if event.get("snapshot_path"):
                    event["snapshot_url"] = "/snapshots/" + event["snapshot_path"].split("/")[-1]
                if event.get("clip_path"):
                    event["clip_url"] = "/clips/" + event["clip_path"].split("/")[-1]
                socketio.emit("detection", event)
            except (json.JSONDecodeError, KeyError) as e:
                log.warning("Bad event message: %s", e)


@socketio.on("connect")
def handle_connect():
    log.info("WebSocket client connected")


# ── Main ────────────────────────────────────────────────────────────────

if __name__ == "__main__":
    config = load_config()
    host = config.get("web", {}).get("host", "0.0.0.0")
    port = config.get("web", {}).get("port", 8080)

    # Start Redis event listener in background
    t = threading.Thread(target=redis_event_listener, daemon=True)
    t.start()

    log.info("Web dashboard starting on %s:%d", host, port)
    socketio.run(app, host=host, port=port, debug=False)
