# AI Surveillance Camera System

Dockerized AI-powered surveillance system for USB webcams. Uses YOLOv8 for object detection with motion pre-filtering, a Flask web dashboard with live streaming, and Telegram alerts.

## Architecture

```
┌────────────┐    ┌───────────┐    ┌──────────────┐
│  Detector   │───>│   Redis   │<───│ Web Dashboard│
│ (YOLOv8 +  │    │ (pub/sub) │    │  (Flask +    │
│  OpenCV)   │    └───────────┘    │  WebSocket)  │
└─────┬──────┘                     └──────┬───────┘
      │                                   │
      └──────────┐  ┌────────────────────┘
                 │  │
            ┌────▼──▼────┐
            │ PostgreSQL  │
            │  (events)   │
            └─────────────┘
```

**Services:**
- **detector** — Webcam capture, motion detection, YOLOv8 inference, clip/snapshot saving, Telegram alerts
- **web** — Live MJPEG stream, real-time WebSocket events, detection log, snapshot/clip gallery, system stats
- **redis** — Message broker (pub/sub for real-time events, frame buffer for streaming)
- **db** — PostgreSQL for detection event persistence

## Parrot Linux Setup

### 1. Prerequisites

```bash
# Update system
sudo apt update && sudo apt upgrade -y

# Add your user to the video group for webcam access
sudo usermod -aG video $USER
# Log out and back in for group change to take effect
```

### 2. Install Docker

```bash
# Install Docker
sudo apt install -y docker.io docker-compose

# Start and enable Docker
sudo systemctl start docker
sudo systemctl enable docker

# Add user to docker group (avoids needing sudo)
sudo usermod -aG docker $USER

# Log out and back in, then verify:
docker run hello-world
```

### 3. Verify Webcam

```bash
# Check that the webcam is detected
ls -la /dev/video*

# Install v4l-utils if not present
sudo apt install -y v4l-utils

# List webcam capabilities
v4l2-ctl --list-devices
v4l2-ctl --device=/dev/video0 --list-formats-ext

# Quick test (requires GUI)
ffplay /dev/video0
```

If `/dev/video0` is not your webcam, update `config/config.yaml` and `docker-compose.yml` with the correct device.

### 4. Configure

```bash
cd surveillance

# Create .env from example
cp .env.example .env

# Edit .env — set a strong DB password and (optionally) Telegram credentials
nano .env

# Edit config as needed
nano config/config.yaml
```

**Telegram setup (optional):**
1. Message [@BotFather](https://t.me/BotFather) on Telegram, create a bot, copy the token
2. Get your chat ID by messaging [@userinfobot](https://t.me/userinfobot)
3. Set `TELEGRAM_BOT_TOKEN` and `TELEGRAM_CHAT_ID` in `.env`
4. Set `alerts.telegram.enabled: true` in `config/config.yaml`

### 5. First Run

```bash
# Build and start all services
docker-compose up --build -d

# Watch logs
docker-compose logs -f

# Open dashboard
xdg-open http://localhost:8080
```

### 6. Verify Webcam Passthrough

```bash
# Check that the detector container sees the webcam
docker-compose exec detector ls -la /dev/video0

# Check detector logs for "Camera opened" message
docker-compose logs detector | head -20

# Verify all services are healthy
docker-compose ps
```

## Usage

| URL | Description |
|-----|-------------|
| `http://localhost:8080` | Web dashboard |
| `http://localhost:8080/stream` | Raw MJPEG stream |
| `http://localhost:8080/api/events` | Detection events JSON |
| `http://localhost:8080/api/stats` | System stats JSON |

### API Query Parameters

**GET /api/events**
- `class` — Filter by object class (e.g., `person`, `car`)
- `from` — Start datetime (ISO format)
- `to` — End datetime (ISO format)
- `limit` — Max results (default 100, max 500)
- `offset` — Pagination offset

## Configuration Reference

All settings are in `config/config.yaml`:

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| camera | device | /dev/video0 | Webcam device path |
| camera | width/height | 1280x720 | Capture resolution |
| camera | fps | 15 | Capture framerate |
| detection | confidence_threshold | 0.45 | Min YOLO confidence |
| detection | model | yolov8n.pt | YOLO model (n/s/m/l/x) |
| motion | sensitivity | 25 | Lower = more sensitive |
| motion | min_area | 3000 | Min contour area (px) |
| recording | clip_duration_sec | 10 | Clip length |
| storage | retention_days | 7 | Auto-delete after N days |

## GPU Support (Optional)

For NVIDIA GPU acceleration:

```bash
# Install NVIDIA Container Toolkit
# See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

# Uncomment the GPU section in docker-compose.yml under the detector service
# Change model to yolov8s.pt or larger in config.yaml for better accuracy
docker-compose up --build -d
```

## Troubleshooting

**"Camera not available"** — Check `/dev/video0` exists, user is in `video` group, device is mapped in `docker-compose.yml`

**Low FPS** — Use `yolov8n.pt` (nano), reduce resolution, increase motion sensitivity to filter more frames

**No Telegram alerts** — Verify token/chat ID in `.env`, set `alerts.telegram.enabled: true` in config

**Permission denied on /dev/video0** — Run `sudo chmod 666 /dev/video0` or ensure the `video` group mapping is correct

## File Structure

```
surveillance/
├── docker-compose.yml
├── .env.example
├── config/
│   └── config.yaml
├── detector/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── main.py
│   ├── motion.py
│   ├── recorder.py
│   ├── alerts.py
│   └── cleanup.py
├── web/
│   ├── Dockerfile
│   ├── requirements.txt
│   ├── app.py
│   └── templates/
│       └── index.html
│   └── static/
│       ├── css/style.css
│       └── js/dashboard.js
└── data/
    ├── clips/
    └── snapshots/
```
