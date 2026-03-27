const servicesPath = 'data/services.json';
const nodesPath = 'data/nodes.json';
const statePath = 'data/state.json';
const eventsPath = 'data/events.log';

const tabs = document.querySelectorAll('.tab');
const views = document.querySelectorAll('.view');
const bannerEl = document.getElementById('banner');
const refreshBtn = document.getElementById('refresh-btn');
const activeSupervisorEl = document.getElementById('active-supervisor');

const metricServices = document.getElementById('metric-services');
const metricNodes = document.getElementById('metric-nodes');
const metricFailover = document.getElementById('metric-failover');
const metricUnhealthy = document.getElementById('metric-unhealthy');
const policyList = document.getElementById('policy-list');

const servicesBody = document.getElementById('services-body');
const nodesBody = document.getElementById('nodes-body');
const eventsList = document.getElementById('events-list');

const actionService = document.getElementById('action-service');
const actionRole = document.getElementById('action-role');
const actionNode = document.getElementById('action-node');
const healthNode = document.getElementById('health-node');
const healthValue = document.getElementById('health-value');
const forceNode = document.getElementById('force-node');
const commandOutput = document.getElementById('command-output');

const btnAssign = document.getElementById('btn-assign');
const btnHealth = document.getElementById('btn-health');
const btnForce = document.getElementById('btn-force');
const btnCycle = document.getElementById('btn-cycle');

let model = {
  services: [],
  nodes: [],
  state: null,
  events: [],
  consensus: null,
  remediation: null,
};

function setBanner(kind, text) {
  bannerEl.className = `banner ${kind}`;
  bannerEl.textContent = text;
}

async function fetchJson(path) {
  const res = await fetch(path, { cache: 'no-store' });
  if (!res.ok) throw new Error(`Failed ${path}: ${res.status}`);
  return res.json();
}

async function fetchEvents() {
  const res = await fetch(eventsPath, { cache: 'no-store' });
  if (!res.ok) return [];
  const raw = await res.text();
  const lines = raw.trim().split(/\r?\n/).filter(Boolean);
  return lines
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean)
    .slice(-150)
    .reverse();
}

async function loadData() {
  setBanner('info', 'Loading supervisor data...');

  try {
    const [services, nodes, state, events] = await Promise.all([
      fetchJson(servicesPath),
      fetchJson(nodesPath),
      fetchJson(statePath),
      fetchEvents(),
    ]);

    model = { services, nodes, state, events };
    renderAll();

    const unhealthy = nodes.filter((n) => !n.healthy).length;
    if (unhealthy > 0) {
      setBanner('warn', `${unhealthy} node(s) unhealthy. Automatic failover policy may trigger.`);
    } else {
      setBanner('info', 'Supervisor state loaded. Automatic takeover enabled with optional overrides.');
    }
  } catch (err) {
    console.error(err);
    setBanner('critical', 'Failed to load supervisor data. Ensure data/*.json exists and is served over HTTP.');
  }
}

function renderAll() {
  renderMetrics();
  renderPolicy();
  renderServices();
  renderNodes();
  renderEvents();
  renderConsensusState();
  renderRemediationState();
  renderActionInputs();
}

function renderMetrics() {
  const failoverCount = model.services.filter((s) => s.status === 'failover-active').length;
  const unhealthyCount = model.nodes.filter((n) => !n.healthy).length;

  metricServices.textContent = String(model.services.length);
  metricNodes.textContent = String(model.nodes.length);
  metricFailover.textContent = String(failoverCount);
  metricUnhealthy.textContent = String(unhealthyCount);

  const activeNode = model.state?.supervisor?.activeNodeId || 'unknown';
  const activeNodeHealth = model.nodes.find((n) => n.id === activeNode)?.healthy;

  activeSupervisorEl.textContent = `active: ${activeNode}`;
  activeSupervisorEl.className = `badge ${activeNodeHealth === false ? 'down' : 'ok'}`;
}

function renderPolicy() {
  const policy = model.state?.policy || {};
  const maintenance = model.state?.supervisor?.maintenance || { nodes: [], services: [] };
  const lines = [
    `Promotion timeout: ${policy.promotionTimeoutSeconds || 1200}s`,
    `Beta sync interval: ${policy.betaSyncInterval || 'daily'}`,
    `Gamma backup interval: ${policy.gammaBackupInterval || 'daily-incremental-weekly-full'}`,
    `Gamma retention: ${policy.gammaRetentionMonths || 12} months`,
    `Automatic takeover: ${String(model.state?.supervisor?.automaticTakeover === true)}`,
    `Maintenance nodes: ${maintenance.nodes.length}`,
    `Maintenance services: ${maintenance.services.length}`,
  ];

  policyList.innerHTML = '';
  for (const line of lines) {
    const li = document.createElement('li');
    li.textContent = line;
    policyList.appendChild(li);
  }
}

function renderServices() {
  servicesBody.innerHTML = '';

  for (const svc of model.services) {
    const tr = document.createElement('tr');
    const role = svc.roleAssignments || {};

    tr.innerHTML = `
      <td>${escapeHtml(svc.id)}</td>
      <td>${badgeForStatus(svc.status || 'unknown')}</td>
      <td>${escapeHtml(svc.domain || '-')}</td>
      <td>${svc.containerized ? 'yes' : 'no'}</td>
      <td>${escapeHtml(role.alpha || '-')}</td>
      <td>${escapeHtml(role.beta || '-')}</td>
      <td>${escapeHtml(role.gamma || '-')}</td>
    `;

    servicesBody.appendChild(tr);
  }
}

function renderNodes() {
  nodesBody.innerHTML = '';

  for (const node of model.nodes) {
    const tr = document.createElement('tr');
    tr.innerHTML = `
      <td>${escapeHtml(node.id || '-')}</td>
      <td>${escapeHtml(node.hostname || '-')}</td>
      <td>${escapeHtml(node.netbirdIp || '-')}</td>
      <td>${badgeForStatus(node.healthy ? 'healthy' : 'down')}</td>
      <td>${node.isSupervisor ? 'yes' : 'no'}</td>
      <td>${node.isSubSupervisor ? 'yes' : 'no'}</td>
      <td>${(node.alphaServices || []).length}</td>
      <td>${(node.betaServices || []).length}</td>
      <td>${(node.gammaServices || []).length}</td>
    `;
    nodesBody.appendChild(tr);
  }
}

function renderEvents() {
  eventsList.innerHTML = '';

  if (model.events.length === 0) {
    const empty = document.createElement('div');
    empty.className = 'event';
    empty.textContent = 'No events yet.';
    eventsList.appendChild(empty);
    return;
  }

  for (const ev of model.events) {
    const item = document.createElement('article');
    item.className = 'event';
    item.innerHTML = `
      <div class="meta">${escapeHtml(ev.ts || '-')} | ${escapeHtml(ev.level || 'info')} | ${escapeHtml(ev.event || '-')}</div>
      <div>actor: ${escapeHtml(ev.actor || '-')}</div>
      <div>reason: ${escapeHtml(ev.reason || '-')}</div>
      <div>outcome: ${escapeHtml(ev.outcome || '-')}</div>
    `;
    eventsList.appendChild(item);
  }
}

function renderConsensusState() {
  const consensusPanel = document.getElementById('consensus-details');
  if (!consensusPanel) return;

  const consensus = model.state?.consensus || {};
  const leader = consensus.leader || 'none';
  const term = consensus.term || 0;
  
  consensusPanel.innerHTML = `
    <dl class="kv-list">
      <dt>Current Term</dt><dd>${term}</dd>
      <dt>Leader</dt><dd>${escapeHtml(leader)}</dd>
      <dt>Voted For</dt><dd>${escapeHtml(consensus.votedFor || 'none')}</dd>
      <dt>Followers</dt><dd>${(consensus.followers || []).length} node(s)</dd>
    </dl>
  `;
}

function renderRemediationState() {
  const remediationPanel = document.getElementById('remediation-details');
  if (!remediationPanel) return;

  const remediation = model.state?.remediation || {};
  const quarantined = remediation.quarantined || [];
  const cooldowns = Object.keys(remediation.cooldowns || {}).length;
  
  remediationPanel.innerHTML = `
    <dl class="kv-list">
      <dt>Quarantined Nodes</dt><dd>${quarantined.length > 0 ? quarantined.join(', ') : 'none'}</dd>
      <dt>Active Cooldowns</dt><dd>${cooldowns}</dd>
      <dt>Max Reboot Attempts</dt><dd>3 (enforced)</dd>
      <dt>Cooldown Duration</dt><dd>30 minutes</dd>
    </dl>
  `;
}

function renderActionInputs() {
  fillSelect(actionService, model.services.map((s) => s.id));
  fillSelect(actionNode, model.nodes.map((n) => n.id));
  fillSelect(healthNode, model.nodes.map((n) => n.id));
  fillSelect(forceNode, ['none', ...model.nodes.map((n) => n.id)]);
  
  // Phase 2-3 action inputs
  const remediationNode = document.getElementById('remediation-node');
  if (remediationNode) fillSelect(remediationNode, model.nodes.map((n) => n.id));
  
  const quarantineNode = document.getElementById('quarantine-node');
  if (quarantineNode) fillSelect(quarantineNode, model.nodes.map((n) => n.id));
}

function fillSelect(select, values) {
  const current = select.value;
  select.innerHTML = '';
  for (const value of values) {
    const opt = document.createElement('option');
    opt.value = value;
    opt.textContent = value;
    select.appendChild(opt);
  }
  if (values.includes(current)) select.value = current;
}

function badgeForStatus(status) {
  const s = String(status || '').toLowerCase();
  if (s === 'healthy' || s === 'online') return '<span class="badge ok">healthy</span>';
  if (s === 'down' || s === 'offline') return '<span class="badge down">down</span>';
  if (s === 'failover-active') return '<span class="badge info">failover-active</span>';
  if (s === 'degraded') return '<span class="badge info">degraded</span>';
  return '<span class="badge info">unknown</span>';
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function setCommand(text) {
  commandOutput.value = text;
}

tabs.forEach((tab) => {
  tab.addEventListener('click', () => {
    tabs.forEach((t) => t.classList.remove('active'));
    views.forEach((v) => v.classList.remove('active'));
    tab.classList.add('active');
    document.getElementById(`view-${tab.dataset.view}`).classList.add('active');
  });
});

refreshBtn.addEventListener('click', loadData);

btnAssign.addEventListener('click', () => {
  setCommand(`bin/supervisor.sh assign-role ${actionService.value} ${actionRole.value} ${actionNode.value}`);
});

btnHealth.addEventListener('click', () => {
  setCommand(`bin/supervisor.sh set-node-health ${healthNode.value} ${healthValue.value}`);
});

btnForce.addEventListener('click', () => {
  setCommand(`bin/supervisor.sh set-force-active ${forceNode.value}`);
});

btnCycle.addEventListener('click', () => {
  setCommand('bin/supervisor.sh run-cycle --execute');
});

// Phase 2-3 action handlers
const btnCleanupBackups = document.getElementById('btn-cleanup-backups');
if (btnCleanupBackups) {
  btnCleanupBackups.addEventListener('click', () => {
    setCommand('bin/cleanup_backups.sh /var/backups/core 6 data/state.json');
  });
}

const btnRemediateNode = document.getElementById('btn-remediate-node');
if (btnRemediateNode) {
  btnRemediateNode.addEventListener('click', () => {
    const remediationNode = document.getElementById('remediation-node');
    if (remediationNode) {
      setCommand(`bin/node_remediation.sh assess-and-remediate data/nodes.json data/state.json ${remediationNode.value}`);
    }
  });
}

const btnQuarantineNode = document.getElementById('btn-quarantine-node');
if (btnQuarantineNode) {
  btnQuarantineNode.addEventListener('click', () => {
    const quarantineNode = document.getElementById('quarantine-node');
    if (quarantineNode) {
      setCommand(`bin/node_remediation.sh quarantine data/nodes.json data/state.json ${quarantineNode.value}`);
    }
  });
}

const btnClusterInit = document.getElementById('btn-cluster-init');
if (btnClusterInit) {
  btnClusterInit.addEventListener('click', () => {
    setCommand('bin/ha_cluster.sh init core-cluster.json core');
  });
}

const btnClusterHealth = document.getElementById('btn-cluster-health');
if (btnClusterHealth) {
  btnClusterHealth.addEventListener('click', () => {
    setCommand('bin/ha_cluster.sh health core-cluster.json');
  });
}

loadData();
setInterval(loadData, 15000);
