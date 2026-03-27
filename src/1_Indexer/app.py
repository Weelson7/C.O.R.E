from __future__ import annotations

from flask import Flask, Response, jsonify

app = Flask(__name__)

SERVICE_CATALOG = [
    {
        "name": "DNS",
        "domain": "dns.core",
        "description": "AdGuard DNS control plane",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "infra",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Indexer",
        "domain": "index.core",
        "description": "Service index and control dashboard",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "portal",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Jellyfin",
        "domain": "jellyfin.core",
        "description": "Media streaming service",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "media",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Suwayomi",
        "domain": "suwayomi.core",
        "description": "Manga server",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "media",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Kasm",
        "domain": "kasm.core",
        "description": "Workspace streaming runtime",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "workspace",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Crafty",
        "domain": "crafty.core",
        "description": "Game server management",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "games",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "ttyd",
        "domain": "ttyd.core",
        "description": "Web terminal",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "ops",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "qBittorrent",
        "domain": "qbittorrent.core",
        "description": "Torrent management",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "media",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Jupyter",
        "domain": "jupyter.core",
        "description": "Notebook environment",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "compute",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Stirling",
        "domain": "stirling.core",
        "description": "Document tooling",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "utility",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Doom",
        "domain": "doom.zenith.su",
        "description": "WASM DOOM runtime",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "fun",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Supervisor",
        "domain": "supervisor.core",
        "description": "Cluster orchestration control surface",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "control",
        "ingressPath": "supervisor",
        "wip": False,
    },
]


@app.get("/api/sites")
def sites() -> tuple[Response, int]:
    return jsonify(SERVICE_CATALOG), 200


@app.get("/health")
def health() -> tuple[Response, int]:
    return jsonify({"status": "ok"}), 200


if __name__ == "__main__":
    from os import getenv

    port = int(getenv("PORT", "5001"))
    app.run(host="0.0.0.0", port=port)
