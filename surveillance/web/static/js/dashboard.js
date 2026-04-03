// AI Surveillance Dashboard — Client JS

const socket = io();
let currentPage = 0;
const PAGE_SIZE = 25;

// ── WebSocket: real-time detections ────────────────────────────────────

socket.on("detection", (event) => {
    addLiveEvent(event);
    updateGallery(event);
});

function addLiveEvent(event) {
    const feed = document.getElementById("live-events");
    const card = document.createElement("div");

    const vehicleClasses = ["car", "truck", "motorcycle", "bicycle", "bus"];
    let borderClass = "";
    if (event.object_class === "person") borderClass = "person";
    else if (vehicleClasses.includes(event.object_class)) borderClass = "vehicle";

    const time = new Date(event.timestamp).toLocaleTimeString();
    const conf = (event.confidence * 100).toFixed(1);

    card.className = `event-card ${borderClass}`;
    card.innerHTML = `
        <span class="event-time">${time}</span>
        <span class="event-class">${event.object_class}</span>
        <span class="event-conf">${conf}%</span>
        ${event.snapshot_url ? `<a href="${event.snapshot_url}" target="_blank">[snap]</a>` : ""}
    `;

    feed.prepend(card);

    // Keep only last 50 events in DOM
    while (feed.children.length > 50) {
        feed.removeChild(feed.lastChild);
    }
}

function updateGallery(event) {
    if (!event.snapshot_url) return;
    const gallery = document.getElementById("gallery");
    const item = document.createElement("div");
    item.className = "gallery-item";
    item.innerHTML = `
        <img src="${event.snapshot_url}" alt="${event.object_class}"
             onclick="openLightbox('${event.snapshot_url}', 'image')">
        <div class="gallery-label">
            ${event.object_class} — ${(event.confidence * 100).toFixed(0)}%
        </div>
    `;
    gallery.prepend(item);

    // Limit gallery to 60 items
    while (gallery.children.length > 60) {
        gallery.removeChild(gallery.lastChild);
    }
}

// ── Lightbox ───────────────────────────────────────────────────────────

function openLightbox(src, type) {
    const lightbox = document.getElementById("lightbox");
    const img = document.getElementById("lightbox-img");
    const video = document.getElementById("lightbox-video");

    if (type === "video") {
        img.style.display = "none";
        video.style.display = "block";
        video.src = src;
    } else {
        video.style.display = "none";
        video.pause && video.pause();
        img.style.display = "block";
        img.src = src;
    }
    lightbox.classList.add("active");
}

function closeLightbox() {
    const lightbox = document.getElementById("lightbox");
    const video = document.getElementById("lightbox-video");
    lightbox.classList.remove("active");
    video.pause && video.pause();
    video.src = "";
}

// ── Events Table ───────────────────────────────────────────────────────

function loadEvents() {
    const cls = document.getElementById("filter-class").value;
    const from = document.getElementById("filter-from").value;
    const to = document.getElementById("filter-to").value;

    let url = `/api/events?limit=${PAGE_SIZE}&offset=${currentPage * PAGE_SIZE}`;
    if (cls) url += `&class=${encodeURIComponent(cls)}`;
    if (from) url += `&from=${from}T00:00:00`;
    if (to) url += `&to=${to}T23:59:59`;

    fetch(url)
        .then((r) => r.json())
        .then((data) => {
            const tbody = document.getElementById("events-body");
            tbody.innerHTML = "";

            data.events.forEach((ev) => {
                const tr = document.createElement("tr");
                const time = new Date(ev.timestamp).toLocaleString();
                const conf = (ev.confidence * 100).toFixed(1);
                tr.innerHTML = `
                    <td>${time}</td>
                    <td>${ev.object_class}</td>
                    <td>${conf}%</td>
                    <td>${ev.snapshot_url ? `<a href="${ev.snapshot_url}" onclick="event.preventDefault(); openLightbox('${ev.snapshot_url}', 'image')">View</a>` : "—"}</td>
                    <td>${ev.clip_url ? `<a href="${ev.clip_url}" onclick="event.preventDefault(); openLightbox('${ev.clip_url}', 'video')">Play</a>` : "—"}</td>
                `;
                tbody.appendChild(tr);
            });

            // Pagination
            document.getElementById("page-info").textContent = `Page ${currentPage + 1}`;
            document.getElementById("btn-prev").disabled = currentPage === 0;
            document.getElementById("btn-next").disabled = data.events.length < PAGE_SIZE;
        })
        .catch((err) => console.error("Failed to load events:", err));
}

function changePage(delta) {
    currentPage = Math.max(0, currentPage + delta);
    loadEvents();
}

// ── Stats Polling ──────────────────────────────────────────────────────

function loadStats() {
    fetch("/api/stats")
        .then((r) => r.json())
        .then((s) => {
            document.getElementById("stat-fps").textContent = s.fps ?? "--";
            document.getElementById("stat-cpu").textContent = s.cpu_percent ?? "--";
            document.getElementById("stat-mem").textContent = s.memory_percent ?? "--";
            document.getElementById("stat-detections").textContent = s.detection_count ?? "--";

            if (s.uptime_sec != null) {
                const h = Math.floor(s.uptime_sec / 3600);
                const m = Math.floor((s.uptime_sec % 3600) / 60);
                document.getElementById("stat-uptime").textContent = `${h}h ${m}m`;
            }
        })
        .catch(() => {});
}

// ── Load filter classes ────────────────────────────────────────────────

function loadClasses() {
    fetch("/api/classes")
        .then((r) => r.json())
        .then((classes) => {
            const select = document.getElementById("filter-class");
            classes.forEach((c) => {
                const opt = document.createElement("option");
                opt.value = c;
                opt.textContent = c;
                select.appendChild(opt);
            });
        })
        .catch(() => {});
}

// ── Init ───────────────────────────────────────────────────────────────

document.addEventListener("DOMContentLoaded", () => {
    loadEvents();
    loadStats();
    loadClasses();
    setInterval(loadStats, 5000);
});
