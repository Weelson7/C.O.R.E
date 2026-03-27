const API_URL    = '/api/sites';
const REFRESH_MS = 30_000;
const TIMEOUT_MS = 8_000;

const grid        = document.getElementById('card-grid');
const badge       = document.getElementById('status-badge');
const countEl     = document.getElementById('service-count');
const refreshEl   = document.getElementById('last-refresh');
const errorBanner = document.getElementById('error-banner');
const incidentEl  = document.getElementById('incident-banner');
const ingressPathEl = document.getElementById('ingress-path');

async function loadSites() {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), TIMEOUT_MS);

  try {
    const res = await fetch(API_URL, { signal: controller.signal });
    clearTimeout(timer);

    if (!res.ok) throw new Error(`HTTP ${res.status}`);

    const sites = await res.json();
    if (!Array.isArray(sites)) throw new Error('Invalid response shape');

    const summary = renderCards(sites);
    updateIngressPath(sites);
    countEl.textContent   = sites.length;
    refreshEl.textContent = `last refresh: ${timestamp()}`;
    badge.textContent     = 'Online';
    badge.className       = 'badge ok';
    errorBanner.classList.add('hidden');
    updateIncident(summary);

  } catch (err) {
    clearTimeout(timer);
    const reason = err.name === 'AbortError' ? 'timeout' : err.message;
    console.error('[indexer] fetch failed:', reason);
    badge.textContent = 'Manual action required';
    badge.className   = 'badge err';
    errorBanner.classList.remove('hidden');
    incidentEl.className = 'incident-banner critical';
    incidentEl.textContent = 'Critical incident: service discovery is unavailable. Supervisor failover readiness should be verified.';
    if (ingressPathEl) {
      ingressPathEl.innerHTML = 'ingress path: <code>unknown</code>';
    }
    if (grid.querySelectorAll('.card').length === 0) {
      grid.innerHTML = '';
      const msg = document.createElement('p');
      msg.className = 'meta-bar';
      msg.textContent = 'No data available while API is unreachable.';
      grid.appendChild(msg);
    }
  }
}

function renderCards(sites) {
  grid.innerHTML = '';
  const summary = {
    healthy: 0,
    degraded: 0,
    down: 0,
    failover: 0,
    unknown: 0,
  };

  if (sites.length === 0) {
    const msg = document.createElement('p');
    msg.className   = 'meta-bar';
    msg.textContent = 'No sites found in sites-available.';
    grid.appendChild(msg);
    return summary;
  }

  for (let i = 0; i < sites.length; i += 1) {
    const site = sites[i];
    const serviceState = classifyState(site);
    summary[serviceState] += 1;

    const a = document.createElement('a');
    a.className = `card ${stateClass(serviceState)}`;
    a.style.animationDelay = `${Math.min(i, 8) * 30}ms`;
    a.href      = `https://${sanitize(site.domain)}`;
    a.target    = '_blank';
    a.rel       = 'noopener noreferrer';

    const top = document.createElement('div');
    top.className = 'card-top';

    const name = document.createElement('span');
    name.className = 'card-name';
    name.textContent = site.name ?? '';

    const dot = document.createElement('span');
    dot.className = `status-dot ${dotClass(serviceState)}`;
    dot.title = stateLabel(serviceState);

    top.appendChild(name);
    top.appendChild(dot);

    const domain = document.createElement('span');
    domain.className = 'card-domain';
    domain.textContent = site.domain ?? '';

    const desc = document.createElement('p');
    desc.className = 'card-desc';
    desc.textContent = site.description || 'No service description provided.';

    const node = document.createElement('span');
    node.className = 'card-node';
    const siteNode = site.node || 'node-0';
    const siteRole = String(site.role || inferRole(site)).toLowerCase();
    node.textContent = `node: ${siteNode} (${siteRole})`;

    const status = document.createElement('span');
    status.className = `card-status ${dotClass(serviceState)}`;
    status.textContent = stateLabel(serviceState);

    const tag = document.createElement('span');
    tag.className = 'card-tag';
    tag.textContent = formatTag(site.tag ?? 'service');

    a.appendChild(top);
    a.appendChild(domain);
    a.appendChild(desc);
    a.appendChild(node);
    a.appendChild(status);
    a.appendChild(tag);

    grid.appendChild(a);
  }

  return summary;
}

function updateIngressPath(sites) {
  if (!ingressPathEl) return;

  const hasSubSupervisorPath = sites.some((site) => {
    const path = String(site.ingressPath || site.tag || '').toLowerCase();
    return path.includes('sub-supervisor') || path.includes('failover');
  });

  const path = hasSubSupervisorPath ? 'sub-supervisor' : 'supervisor';
  ingressPathEl.innerHTML = `ingress path: <code>${path}</code>`;
}

function inferRole(site) {
  const statusRaw = String(site.status ?? '').toLowerCase();
  const tagRaw = String(site.tag ?? '').toLowerCase();

  if (statusRaw.includes('failover') || tagRaw.includes('failover')) {
    return 'beta';
  }

  return 'alpha';
}

function updateIncident(summary) {
  const total = summary.healthy + summary.degraded + summary.down + summary.failover + summary.unknown;

  if (total === 0) {
    incidentEl.className = 'incident-banner info';
    incidentEl.textContent = 'Info: no indexed services discovered yet.';
    return;
  }

  if (summary.down > 0) {
    incidentEl.className = 'incident-banner critical';
    incidentEl.textContent = `Critical: ${summary.down} service(s) down. Manual action required.`;
    return;
  }

  if (summary.degraded > 0) {
    incidentEl.className = 'incident-banner warning';
    incidentEl.textContent = `Warning: ${summary.degraded} service(s) degraded. Review supervisor health and upstream checks.`;
    return;
  }

  if (summary.failover > 0) {
    incidentEl.className = 'incident-banner info';
    incidentEl.textContent = `Info: failover active for ${summary.failover} service(s). Traffic is rerouted.`;
    return;
  }

  incidentEl.className = 'incident-banner ok';
  incidentEl.textContent = 'Online: all indexed services report healthy state.';
}

function classifyState(site) {
  const statusRaw = String(site.status ?? '').toLowerCase();
  const tagRaw = String(site.tag ?? '').toLowerCase();

  if (statusRaw === 'down' || statusRaw === 'critical' || statusRaw === 'offline') {
    return 'down';
  }

  if (statusRaw === 'degraded' || statusRaw === 'warning') {
    return 'degraded';
  }

  if (statusRaw === 'failover-active' || statusRaw === 'failover' || tagRaw.includes('failover') || tagRaw.includes('reroute')) {
    return 'failover';
  }

  if (site.wip === true || tagRaw.includes('wip') || tagRaw.includes('maintenance')) {
    return 'degraded';
  }

  if (statusRaw === 'healthy' || statusRaw === 'online' || statusRaw === 'ok') {
    return 'healthy';
  }

  return 'healthy';
}

function stateClass(state) {
  if (state === 'down') return 'is-down';
  if (state === 'degraded') return 'is-degraded';
  if (state === 'failover') return 'is-failover';
  return '';
}

function dotClass(state) {
  if (state === 'down') return 'down';
  if (state === 'degraded') return 'degraded';
  if (state === 'failover') return 'failover';
  if (state === 'unknown') return 'unknown';
  return 'healthy';
}

function stateLabel(state) {
  if (state === 'down') return 'Manual action required';
  if (state === 'degraded') return 'Degraded';
  if (state === 'failover') return 'Failover active';
  if (state === 'unknown') return 'Unknown';
  return 'Online';
}

function formatTag(tag) {
  return String(tag).replace(/[_\s]+/g, '-').toUpperCase();
}

function sanitize(str) {
  return String(str).replace(/[^a-zA-Z0-9.\-]/g, '');
}

function timestamp() {
  return new Date().toLocaleTimeString('en-GB', {
    hour: '2-digit', minute: '2-digit', second: '2-digit',
  });
}

loadSites();
setInterval(loadSites, REFRESH_MS);
