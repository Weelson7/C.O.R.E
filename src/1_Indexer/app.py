from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor, as_completed
from copy import deepcopy
from dataclasses import dataclass
import re
import ssl
from time import monotonic
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

from flask import Flask, Response, jsonify

app = Flask(__name__)

PROBE_TIMEOUT_SECONDS = 3
PROBE_CACHE_TTL_SECONDS = 10
PROBE_WORKERS = 8

SERVICE_MARKERS: dict[str, str] = {
    "index.core": '"service":"indexer"',
}

_PROBE_CACHE: dict[str, Any] = {"ts": 0.0, "sites": None}


@dataclass
class ProbeResult:
    status: str
    note: str | None = None


def _is_adguard_like(headers: dict[str, str], body: str) -> bool:
    server = headers.get("server", "").lower()
    location = headers.get("location", "").lower()
    body_lc = body.lower()

    if "adguardhome" in server:
        return True

    if "/login.html" in location:
        return True

    if "adguard home" in body_lc:
        return True

    return False


def _probe_url(url: str, *, verify_tls: bool) -> tuple[int, dict[str, str], str] | None:
    request = Request(
        url,
        headers={
            "User-Agent": "core-indexer/1.0",
            "Accept": "application/json,text/plain,text/html;q=0.9,*/*;q=0.5",
        },
        method="GET",
    )

    context = None
    if not verify_tls:
        context = ssl._create_unverified_context()

    try:
        with urlopen(request, timeout=PROBE_TIMEOUT_SECONDS, context=context) as response:
            status = int(response.status)
            headers = {k.lower(): v for k, v in response.headers.items()}
            body = response.read(8192).decode("utf-8", errors="ignore")
            return status, headers, body
    except HTTPError as exc:
        try:
            body = exc.read(8192).decode("utf-8", errors="ignore")
        except Exception:
            body = ""
        headers = {k.lower(): v for k, v in exc.headers.items()}
        return int(exc.code), headers, body
    except (URLError, TimeoutError, OSError):
        return None


def _expected_marker(domain: str) -> str | None:
    return SERVICE_MARKERS.get(domain)


def _probe_service(service: dict[str, Any]) -> ProbeResult:
    domain = str(service.get("domain", "")).strip()
    if not domain:
        return ProbeResult(status="unknown", note="no domain configured")

    is_adguard_service = domain == "dns.core"
    paths = ("/health", "/")
    schemes = (
        ("https", False),
        ("http", True),
    )

    expected = _expected_marker(domain)
    non_adguard_match = False

    for scheme, verify_tls in schemes:
        for path in paths:
            response = _probe_url(f"{scheme}://{domain}{path}", verify_tls=verify_tls)
            if response is None:
                continue

            status, headers, body = response
            if status >= 500:
                continue

            if _is_adguard_like(headers, body):
                if is_adguard_service:
                    return ProbeResult(status="healthy")
                continue

            non_adguard_match = True
            if expected is not None:
                body_compact = re.sub(r"\s+", "", body)
                if expected in body_compact:
                    return ProbeResult(status="healthy")
                continue

            if status < 500:
                return ProbeResult(status="healthy")

    if expected is not None and non_adguard_match:
        return ProbeResult(status="degraded", note="health endpoint did not return expected marker")

    return ProbeResult(status="down", note="service unreachable or routed to fallback")


def _probe_catalog() -> list[dict[str, Any]]:
    cloned = deepcopy(SERVICE_CATALOG)
    with ThreadPoolExecutor(max_workers=min(PROBE_WORKERS, max(1, len(cloned)))) as executor:
        futures = {executor.submit(_probe_service, site): idx for idx, site in enumerate(cloned)}
        for future in as_completed(futures):
            idx = futures[future]
            result = future.result()
            cloned[idx]["status"] = result.status
            if result.note:
                cloned[idx]["probeNote"] = result.note
            else:
                cloned[idx].pop("probeNote", None)

    return cloned


def _get_cached_sites() -> list[dict[str, Any]]:
    now = monotonic()
    cached_sites = _PROBE_CACHE.get("sites")
    cached_ts = float(_PROBE_CACHE.get("ts", 0.0))
    if cached_sites is not None and (now - cached_ts) < PROBE_CACHE_TTL_SECONDS:
        return cached_sites

    sites = _probe_catalog()
    _PROBE_CACHE["ts"] = now
    _PROBE_CACHE["sites"] = sites
    return sites

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
        "name": "OnlyOffice",
        "domain": "onlyoffice.core",
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
        "name": "Seafile",
        "domain": "seafile.core",
        "description": "Self-hosted file sync and sharing",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "storage",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "ncdu-web-viewer",
        "domain": "ncdu.core",
        "description": "Interactive disk usage analyzer",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "ops",
        "ingressPath": "supervisor",
        "wip": False,
    },
    {
        "name": "Music Assistant",
        "domain": "music.core",
        "description": "Self-hosted music library and playback control",
        "node": "node-0",
        "role": "alpha",
        "status": "online",
        "tag": "media",
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
    return jsonify(_get_cached_sites()), 200


@app.get("/health")
def health() -> tuple[Response, int]:
    return jsonify({"status": "ok", "service": "indexer"}), 200


if __name__ == "__main__":
    from os import getenv

    port = int(getenv("PORT", "5001"))
    app.run(host="0.0.0.0", port=port)
