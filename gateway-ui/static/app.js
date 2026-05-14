'use strict';

// ── State ─────────────────────────────────────────────────────────────────────

const state = {
  token:          null,
  logLines:       [],
  logInterval:    null,
  dashInterval:   null,
  netInterval:    null,
  tokenRevealed:  false,
  wingbitsAbort:  null,
};

// ── API ───────────────────────────────────────────────────────────────────────

async function api(path, method = 'GET', body = null) {
  const opts = {
    method,
    headers: { Authorization: `Bearer ${state.token}` },
  };
  if (body !== null) {
    opts.headers['Content-Type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  let r;
  try {
    r = await fetch(path, opts);
  } catch {
    throw new Error('Network error — service may be restarting');
  }
  if (r.status === 401) {
    localStorage.removeItem('gw_token');
    showModal(true);
    throw new Error('unauthorized');
  }
  if (!r.ok) {
    let detail = 'Request failed';
    try { detail = (await r.json()).detail || detail; } catch {}
    throw new Error(detail);
  }
  return r.json();
}

// ── Auth / Modal ──────────────────────────────────────────────────────────────

function showModal(isError = false) {
  document.getElementById('app').classList.add('hidden');
  document.getElementById('modal-overlay').classList.remove('hidden');
  document.getElementById('modal-error').classList.toggle('hidden', !isError);
  document.getElementById('modal-token').value = '';
  document.getElementById('modal-token').focus();
}

function hideModal() {
  document.getElementById('modal-overlay').classList.add('hidden');
  document.getElementById('app').classList.remove('hidden');
}

async function handleTokenSubmit() {
  const input = document.getElementById('modal-token');
  const token = input.value.trim();
  if (!token) return;

  const prev = state.token;
  state.token = token;

  try {
    await api('/api/identity');
    localStorage.setItem('gw_token', token);
    hideModal();
    initApp();
  } catch (e) {
    state.token = prev;
    if (e.message !== 'unauthorized') {
      document.getElementById('modal-error').textContent = e.message;
    }
    document.getElementById('modal-error').classList.remove('hidden');
  }
}

// ── Tab Navigation ────────────────────────────────────────────────────────────

function switchTab(name) {
  document.querySelectorAll('.tab-btn').forEach(b => {
    b.classList.toggle('active', b.dataset.tab === name);
  });
  document.querySelectorAll('.tab-panel').forEach(p => {
    p.classList.toggle('hidden', p.id !== `tab-${name}`);
    p.classList.toggle('active', p.id === `tab-${name}`);
  });

  clearInterval(state.logInterval);
  clearInterval(state.dashInterval);
  clearInterval(state.netInterval);
  state.logInterval = null;
  state.dashInterval = null;
  state.netInterval = null;

  if (state.wingbitsAbort) {
    state.wingbitsAbort.abort();
    state.wingbitsAbort = null;
  }

  if (name === 'dashboard')     startDashboardRefresh();
  if (name === 'applications')  loadApplications();
  if (name === 'network')       startNetworkRefresh();
  if (name === 'logs')          startLogAutoRefresh();
  if (name === 'settings')      loadSettings();
}

// ── Dashboard ─────────────────────────────────────────────────────────────────

function startDashboardRefresh() {
  loadDashboard();
  state.dashInterval = setInterval(loadDashboard, 30_000);
}

async function loadDashboard() {
  const [status, sysinfo] = await Promise.allSettled([
    api('/api/status'),
    api('/api/sysinfo'),
  ]);
  if (status.status  === 'fulfilled') renderDashServices(status.value);
  if (sysinfo.status === 'fulfilled') renderSysinfo(sysinfo.value, true);
}

function renderDashServices(d) {
  const services = ['pktfwd', 'gateway-rs', 'readsb', 'wingbits', 'tailscaled'];
  const el = document.getElementById('dash-services-body');
  el.innerHTML = services.map(name => {
    const s = d[name] || { state: 'not-installed' };
    let cls, dot;
    if (s.state === 'active') { cls = 'badge-green'; dot = '●'; }
    else if (s.state === 'not-installed') { cls = 'badge-dim'; dot = '○'; }
    else { cls = 'badge-yellow'; dot = '●'; }
    return `<span class="service-dot ${cls}">${dot} ${name}</span>`;
  }).join('');
}

// ── Applications: Helium + Wingbits ──────────────────────────────────────────

async function loadApplications() {
  const [identity, status, beacon, bands, wingbits] = await Promise.allSettled([
    api('/api/identity'),
    api('/api/status'),
    api('/api/beacon'),
    api('/api/bands'),
    api('/api/wingbits'),
  ]);

  if (identity.status === 'fulfilled') renderAppIdentity(identity.value);
  if (status.status   === 'fulfilled') renderHeliumServices(status.value);
  if (beacon.status   === 'fulfilled') renderBeacon(beacon.value);
  if (bands.status    === 'fulfilled') renderBands(bands.value);
  if (wingbits.status === 'fulfilled') renderWingbits(wingbits.value);
}

function renderAppIdentity(d) {
  const el = document.getElementById('identity-body');
  el.innerHTML = kv([
    ['Name',    d.name    || '<span class="dim">unavailable</span>'],
    ['Key', d.key ? `<code class="addr">${abbrev(d.key)}</code>` : '<span class="dim">unavailable</span>'],
    ['EUI',     d.eui     ? `<code>${d.eui}</code>` : '<span class="dim">—</span>'],
    ['Region',  d.region  ? `<span class="badge badge-info">${d.region}</span>` : '<span class="dim">—</span>'],
  ]);
  const sub = document.getElementById('header-name');
  if (d.name) sub.textContent = d.name;
}

function renderHeliumServices(d) {
  const el = document.getElementById('helium-services-body');
  el.innerHTML = [
    d.pktfwd || { unit: 'pktfwd.service', state: 'not-installed', since: '' },
    d['gateway-rs'] || { unit: 'gateway-rs.service', state: 'not-installed', since: '' },
  ].map(s => serviceRow(s)).join('');
}

function serviceRow(s) {
  const cls   = s.state === 'active' ? 'green' : s.state === 'failed' ? 'red' : 'dim';
  const label = s.state === 'active' ? '● active' : `● ${s.state}`;
  const short = s.unit.replace('.service', '');
  const since = s.since ? `<div class="since">since ${fmtTimestamp(s.since)}</div>` : '';
  return `
    <div class="service-row">
      <div class="service-info">
        <span class="service-name">${short}</span>
        <span class="badge badge-${cls}">${label}</span>
        ${since}
      </div>
      <button class="btn btn-sm btn-restart" data-service="${short}">Restart</button>
    </div>`;
}

function renderBeacon(d) {
  const el = document.getElementById('beacon-body');
  const lb = d.last_beacon
    ? fmtTimestamp(d.last_beacon.timestamp)
    : '<span class="dim">none recorded</span>';
  const nb = d.next_beacon
    ? fmtTimestamp(d.next_beacon)
    : '<span class="dim">unknown</span>';
  el.innerHTML = kv([
    ['Last beacon',      lb],
    ['Next beacon',      nb],
    ['Witnesses (24 h)', `<strong>${d.witness_count_24h}</strong>`],
  ]);
}

function renderBands(d) {
  const sel = document.getElementById('band-select');
  sel.innerHTML = d.regions.map(r =>
    `<option value="${r}"${r === d.current ? ' selected' : ''}>${r}</option>`
  ).join('');
  document.getElementById('current-band').textContent = d.current || '—';
}

async function applyBand() {
  const region = document.getElementById('band-select').value;
  const btn    = document.getElementById('btn-apply-band');
  btn.disabled = true;
  btn.textContent = 'Applying…';
  try {
    await api('/api/band', 'POST', { region });
    showResult('band-result', `Band set to ${region}`, false);
    document.getElementById('current-band').textContent = region;
  } catch (e) {
    if (e.message !== 'unauthorized') showResult('band-result', e.message, true);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Apply Band';
  }
}

// ── Applications: Wingbits ───────────────────────────────────────────────────

async function loadWingbits() {
  try {
    const d = await api('/api/wingbits');
    renderWingbits(d);
  } catch (e) {
    if (e.message !== 'unauthorized') {
      document.getElementById('wingbits-services-body').innerHTML =
        `<span class="dim">Error: ${e.message}</span>`;
    }
  }
}

function renderWingbits(d) {
  const el = document.getElementById('wingbits-services-body');
  el.innerHTML = [d.readsb, d.wingbits].map(s => wingbitsServiceRow(s)).join('');

  const allActive = d.readsb.state === 'active' && d.wingbits.state === 'active';
  const noneInstalled = d.readsb.state === 'not-installed' && d.wingbits.state === 'not-installed';
  const overall = document.getElementById('wingbits-overall');
  if (allActive) {
    overall.textContent = '● Active';
    overall.className = 'badge badge-green';
  } else if (noneInstalled) {
    overall.textContent = '● Not configured';
    overall.className = 'badge badge-dim';
  } else {
    overall.textContent = '● Degraded';
    overall.className = 'badge badge-yellow';
  }
}

function wingbitsServiceRow(s) {
  let cls, label;
  if (s.state === 'active') {
    cls = 'green'; label = '● Running';
  } else if (s.state === 'not-installed') {
    cls = 'dim'; label = '● Not installed';
  } else {
    cls = 'yellow'; label = '● Stopped';
  }
  const short = s.unit.replace('.service', '');
  const since = s.since ? `<div class="since">since ${fmtTimestamp(s.since)}</div>` : '';
  return `
    <div class="service-row">
      <div class="service-info">
        <span class="service-name">${short}</span>
        <span class="badge badge-${cls}">${label}</span>
        ${since}
      </div>
    </div>`;
}

function _wingbitsValidateUrl(url) {
  return /^https:\/\/gitlab\.com\/wingbits\/config\/-\/raw\//.test(url);
}

function _wingbitsUpdateBtn() {
  const url = document.getElementById('wingbits-url').value.trim();
  const btn = document.getElementById('btn-wingbits-run');
  const msg = document.getElementById('wingbits-url-msg');
  if (!url) {
    btn.disabled = true;
    msg.classList.add('hidden');
    document.getElementById('wingbits-url').classList.remove('invalid');
    return;
  }
  if (_wingbitsValidateUrl(url)) {
    btn.disabled = false;
    msg.classList.add('hidden');
    document.getElementById('wingbits-url').classList.remove('invalid');
  } else {
    btn.disabled = true;
    msg.textContent = 'URL must start with https://gitlab.com/wingbits/config/-/raw/';
    msg.className = 'wingbits-input-msg';
    document.getElementById('wingbits-url').classList.add('invalid');
  }
}

async function runWingbitsSetup() {
  const url = document.getElementById('wingbits-url').value.trim();
  if (!_wingbitsValidateUrl(url)) return;

  const btn = document.getElementById('btn-wingbits-run');
  const output = document.getElementById('wingbits-output');
  const banner = document.getElementById('wingbits-banner');
  const outputActions = document.getElementById('wingbits-output-actions');

  btn.disabled = true;
  btn.textContent = 'Running…';
  output.classList.remove('hidden');
  output.textContent = '';
  banner.classList.add('hidden');
  outputActions.classList.add('hidden');

  state.wingbitsAbort = new AbortController();

  try {
    const r = await fetch('/api/wingbits/setup', {
      method: 'POST',
      headers: { Authorization: `Bearer ${state.token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ url }),
      signal: state.wingbitsAbort.signal,
    });

    if (r.status === 409) { output.textContent = 'Setup already in progress.'; return; }
    if (r.status === 503) { const err = await r.json(); output.textContent = `Error: ${err.detail}`; return; }
    if (!r.ok) {
      let detail = 'Request failed';
      try { detail = (await r.json()).detail || detail; } catch {}
      output.textContent = `Error: ${detail}`; return;
    }

    const reader = r.body.getReader();
    const decoder = new TextDecoder();
    let buf = '';
    let exitCode = null;

    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += decoder.decode(value, { stream: true });
      const parts = buf.split('\n\n');
      buf = parts.pop();
      for (const part of parts) {
        for (const line of part.split('\n')) {
          if (line.startsWith('data: ')) {
            const data = line.slice(6);
            try {
              const obj = JSON.parse(data);
              if (obj.exit_code !== undefined) { exitCode = obj.exit_code; break; }
            } catch {}
            output.textContent += data + '\n';
            output.scrollTop = output.scrollHeight;
          }
        }
        if (exitCode !== null) break;
      }
    }

    if (exitCode === 0) {
      banner.textContent = '✓ Setup completed successfully';
      banner.className = 'wingbits-banner wingbits-banner-success';
    } else if (exitCode !== null) {
      banner.textContent = '✗ Setup failed (exit code ' + exitCode + ')';
      banner.className = 'wingbits-banner wingbits-banner-fail';
    }
    if (exitCode !== null) {
      banner.classList.remove('hidden');
      outputActions.classList.remove('hidden');
      loadWingbits();
    }
  } catch (e) {
    if (e.name !== 'AbortError') output.textContent += '\nError: ' + e.message;
  } finally {
    state.wingbitsAbort = null;
    btn.disabled = false;
    btn.textContent = 'Run Setup';
  }
}

function clearWingbitsOutput() {
  document.getElementById('wingbits-output').classList.add('hidden');
  document.getElementById('wingbits-output').textContent = '';
  document.getElementById('wingbits-banner').classList.add('hidden');
  document.getElementById('wingbits-output-actions').classList.add('hidden');
}

// ── System Info ──────────────────────────────────────────────────────────────

function renderSysinfo(d, showHostname) {
  const el = document.getElementById('sysinfo-body');
  const temp = d.cpu_temp.replace("temp=", "").replace("'C", " °C");

  let memLine = '';
  const memMatch = d.memory.match(/^Mem:\s+(\d+)\s+(\d+)\s+(\d+)/m);
  if (memMatch) {
    const [, total, used] = memMatch;
    const pct = Math.round((used / total) * 100);
    memLine = `${used} / ${total} MB <span class="dim">(${pct}%)</span>`;
  } else {
    memLine = `<span class="dim">${d.memory || 'unavailable'}</span>`;
  }

  let diskLine = '';
  const diskRows = d.disk.trim().split('\n');
  if (diskRows.length >= 2) {
    const parts = diskRows[1].trim().split(/\s+/);
    if (parts.length >= 5) {
      diskLine = `${parts[2]} used of ${parts[1]} <span class="dim">(${parts[4]})</span>`;
    }
  }
  if (!diskLine) diskLine = `<span class="dim">${d.disk || 'unavailable'}</span>`;

  const rows = [
    ['CPU temp', temp],
    ['Memory', memLine],
    ['Disk /opt', diskLine],
  ];
  if (showHostname && d.hostname) {
    rows.unshift(['Hostname', `<code>${d.hostname}</code>`]);
  }
  el.innerHTML = kv(rows);

  // Build version card
  const buildEl = document.getElementById('build-body');
  buildEl.innerHTML = kv([
    ['Image version', d.image_version || 'Development build'],
    ['Built', d.build_date || '—'],
  ]);
}

// ── Network — Interfaces ─────────────────────────────────────────────────────

function startNetworkRefresh() {
  loadNetwork();
  state.netInterval = setInterval(loadNetwork, 30_000);
}

async function loadNetwork() {
  const [ifaces, ts] = await Promise.allSettled([
    api('/api/network/interfaces'),
    api('/api/network/tailscale'),
  ]);
  if (ifaces.status === 'fulfilled') renderInterfaces(ifaces.value);
  if (ts.status     === 'fulfilled') renderTailscale(ts.value);
}

function renderInterfaces(d) {
  for (const name of ['eth0', 'wlan0']) {
    const info = d[name] || {};
    const el = document.getElementById(`iface-${name}`);
    const linkLabel = info.link === 'Up' ? '<span class="badge badge-green">● Up</span>'
      : info.link === 'N/A' ? '<span class="badge badge-dim">N/A</span>'
      : '<span class="badge badge-yellow">● Down</span>';
    const rows = [
      ['Link', linkLabel],
      ['MAC', info.mac ? `<code>${info.mac}</code>` : '<span class="dim">—</span>'],
      ['IPv4', info.ipv4 ? `<code>${info.ipv4}</code>` : '<span class="dim">—</span>'],
      ['IPv6', info.ipv6 ? `<code class="addr">${abbrev(info.ipv6)}</code>` : '<span class="dim">—</span>'],
    ];
    if (name === 'wlan0') {
      rows.splice(1, 0, ['SSID', info.ssid || 'N/A']);
    }
    el.innerHTML = kv(rows);
  }
}

// ── Network — Tailscale ──────────────────────────────────────────────────────

function renderTailscale(d) {
  const body = document.getElementById('tailscale-body');
  const routingCard = document.getElementById('tailscale-routing-card');

  if (d.status === 'not-installed') {
    body.innerHTML = '<div class="kv-row"><span class="kv-label">Status</span><span class="badge badge-dim">○ Not installed</span></div>' +
      '<p class="hint mt">Run <code>sudo /opt/gateway/scripts/install-tailscale.sh</code> to install.</p>';
    routingCard.classList.add('hidden');
    return;
  }
  if (d.status === 'stopped') {
    body.innerHTML = '<div class="kv-row"><span class="kv-label">Status</span><span class="badge badge-yellow">● Stopped</span></div>' +
      '<p class="hint mt">Start with <code>sudo systemctl start tailscaled</code>.</p>';
    routingCard.classList.add('hidden');
    return;
  }
  if (d.status !== 'connected') {
    body.innerHTML = `<div class="kv-row"><span class="kv-label">Status</span><span class="badge badge-yellow">● ${d.status}</span></div>`;
    routingCard.classList.add('hidden');
    return;
  }

  routingCard.classList.remove('hidden');

  const onlineLabel = d.online
    ? '<span class="badge badge-green">● Connected</span>'
    : '<span class="badge badge-yellow">● Offline</span>';

  const ips = (d.ips || []).map(ip => `<code>${ip}</code>`).join(', ') || '<span class="dim">—</span>';
  const hostname = d.hostname || '<span class="dim">—</span>';

  body.innerHTML = kv([
    ['Status', onlineLabel],
    ['Tailscale IP', ips],
    ['Hostname', hostname],
    ['IP forwarding', d.ip_forward ? '<span class="badge badge-green">Enabled</span>' : '<span class="badge badge-dim">Disabled</span>'],
    ['Advertised routes', d.advertised_routes || '<span class="dim">None</span>'],
  ]);
}

// ── Network — Tailscale Auth ─────────────────────────────────────────────────

function _tsKeyValidate(key) {
  return /^tskey(-auth)?-[A-Za-z0-9]+$/.test(key);
}

function _tsKeyUpdateBtn() {
  const key = document.getElementById('tailscale-key').value.trim();
  const btn = document.getElementById('btn-tailscale-connect');
  const msg = document.getElementById('tailscale-key-msg');
  if (!key) {
    btn.disabled = true;
    msg.classList.add('hidden');
    return;
  }
  if (_tsKeyValidate(key)) {
    btn.disabled = false;
    msg.classList.add('hidden');
  } else {
    btn.disabled = true;
    msg.textContent = 'Key must start with tskey- or tskey-auth-';
    msg.className = 'wingbits-input-msg';
  }
}

async function connectTailscale() {
  const key = document.getElementById('tailscale-key').value.trim();
  if (!_tsKeyValidate(key)) return;
  const btn = document.getElementById('btn-tailscale-connect');
  btn.disabled = true;
  btn.textContent = 'Connecting…';
  try {
    await api('/api/network/tailscale/auth', 'POST', { key });
    showResult('tailscale-auth-result', 'Connected ✓', false);
    document.getElementById('tailscale-key').value = '';
    setTimeout(loadNetwork, 2000);
  } catch (e) {
    if (e.message !== 'unauthorized') showResult('tailscale-auth-result', e.message, true);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Connect';
  }
}

// ── Network — Tailscale Routing ──────────────────────────────────────────────

async function applyTailscaleRouting() {
  const enabled = document.getElementById('tailscale-routing-toggle').checked;
  const subnets = document.getElementById('tailscale-subnets').value.trim();
  const btn = document.getElementById('btn-tailscale-routing');
  btn.disabled = true;
  btn.textContent = 'Applying…';
  try {
    await api('/api/network/tailscale/routing', 'POST', { enabled, subnets });
    showResult('tailscale-routing-result', 'Applied ✓', false);
    setTimeout(loadNetwork, 2000);
  } catch (e) {
    if (e.message !== 'unauthorized') showResult('tailscale-routing-result', e.message, true);
  } finally {
    btn.disabled = false;
    btn.textContent = 'Apply';
  }
}

// ── Logs ─────────────────────────────────────────────────────────────────────

function startLogAutoRefresh() {
  loadLogs();
  state.logInterval = setInterval(loadLogs, 10_000);
}

function getActiveLogUnits() {
  const pills = document.querySelectorAll('.log-pill.active');
  return Array.from(pills).map(p => p.dataset.unit).join(',');
}

async function loadLogs() {
  const units = getActiveLogUnits();
  try {
    const data = await api(`/api/logs?units=${encodeURIComponent(units)}`);
    state.logLines = data.lines;
    renderLogOutput();
    document.getElementById('log-status').textContent =
      `Updated ${new Date().toLocaleTimeString()}`;
  } catch (e) {
    if (e.message !== 'unauthorized') {
      document.getElementById('log-status').textContent = `Error: ${e.message}`;
    }
  }
}

function renderLogOutput() {
  const output = document.getElementById('log-output');
  output.textContent = state.logLines.length ? state.logLines.join('\n') : '(no matching log lines)';
  output.scrollTop = output.scrollHeight;
}

// ── Settings ─────────────────────────────────────────────────────────────────

async function loadSettings() {
  try {
    const s = await api('/api/settings');
    document.getElementById('port-input').value = s.port;
  } catch (e) {}
}

async function savePort() {
  const port = parseInt(document.getElementById('port-input').value, 10);
  try {
    await api('/api/settings/port', 'POST', { port });
    showResult('port-result', `Port saved — reconnect on :${port}`, false);
  } catch (e) {
    if (e.message !== 'unauthorized') showResult('port-result', e.message, true);
  }
}

async function revealToken() {
  const btn = document.getElementById('btn-reveal-token');
  if (state.tokenRevealed) {
    document.getElementById('token-display').textContent = '••••••••••••••••';
    btn.textContent = 'Reveal';
    state.tokenRevealed = false;
    return;
  }
  try {
    const r = await api('/api/settings/token');
    document.getElementById('token-display').textContent = r.full;
    btn.textContent = 'Hide';
    state.tokenRevealed = true;
  } catch (e) {
    if (e.message !== 'unauthorized') alert(`Error: ${e.message}`);
  }
}

async function regenToken() {
  if (!confirm('Regenerate bearer token?\n\nYour current session will end. Save the new token before reconnecting.')) return;
  try {
    const r = await api('/api/settings/token', 'POST');
    document.getElementById('new-token-value').textContent = r.token;
    document.getElementById('new-token-box').classList.remove('hidden');
    document.getElementById('btn-regen-token').disabled = true;
    state.token = r.token;
    localStorage.setItem('gw_token', r.token);
  } catch (e) {
    if (e.message !== 'unauthorized') alert(`Error: ${e.message}`);
  }
}

async function copyToken() {
  const val = document.getElementById('new-token-value').textContent;
  try {
    await navigator.clipboard.writeText(val);
    document.getElementById('btn-copy-token').textContent = 'Copied ✓';
    setTimeout(() => { document.getElementById('btn-copy-token').textContent = 'Copy to clipboard'; }, 2000);
  } catch {
    alert('Copy failed — select and copy manually.');
  }
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function kv(pairs) {
  return pairs.map(([k, v]) =>
    `<div class="kv-row"><span class="kv-label">${k}</span><span class="kv-value">${v}</span></div>`
  ).join('');
}

function abbrev(addr) {
  if (!addr || addr.length <= 16) return addr;
  return addr.slice(0, 8) + '…' + addr.slice(-6);
}

function fmtTimestamp(ts) {
  if (!ts) return '—';
  try {
    const d = new Date(ts.replace('+0000', 'Z').replace(' ', 'T'));
    if (isNaN(d)) return ts;
    return d.toLocaleString();
  } catch {
    return ts;
  }
}

function showResult(id, msg, isError) {
  const el = document.getElementById(id);
  el.textContent = msg;
  el.className = 'result-msg ' + (isError ? 'result-error' : 'result-ok');
  setTimeout(() => { el.textContent = ''; el.className = 'result-msg'; }, 5000);
}

// ── Event Wiring ──────────────────────────────────────────────────────────────

function wireEvents() {
  // Modal
  document.getElementById('modal-submit').addEventListener('click', handleTokenSubmit);
  document.getElementById('modal-token').addEventListener('keydown', e => {
    if (e.key === 'Enter') handleTokenSubmit();
  });

  // Tabs
  document.querySelectorAll('.tab-btn').forEach(btn => {
    btn.addEventListener('click', () => switchTab(btn.dataset.tab));
  });

  // Applications — restart buttons (delegated)
  document.getElementById('helium-services-body').addEventListener('click', async e => {
    const btn = e.target.closest('.btn-restart');
    if (!btn) return;
    const service = btn.dataset.service;
    btn.disabled = true;
    btn.textContent = '…';
    try {
      await api(`/api/restart/${service}`, 'POST');
      setTimeout(loadApplications, 2000);
    } catch (err) {
      if (err.message !== 'unauthorized') alert(`Restart failed: ${err.message}`);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Restart';
    }
  });

  // Applications — band
  document.getElementById('btn-apply-band').addEventListener('click', applyBand);

  // Applications — Wingbits setup
  document.getElementById('wingbits-url').addEventListener('input', _wingbitsUpdateBtn);
  document.getElementById('btn-wingbits-run').addEventListener('click', runWingbitsSetup);
  document.getElementById('btn-wingbits-clear').addEventListener('click', clearWingbitsOutput);

  // Network — Tailscale auth
  document.getElementById('tailscale-key').addEventListener('input', _tsKeyUpdateBtn);
  document.getElementById('btn-tailscale-connect').addEventListener('click', connectTailscale);

  // Network — Tailscale routing
  document.getElementById('btn-tailscale-routing').addEventListener('click', applyTailscaleRouting);

  // Network — Port
  document.getElementById('btn-save-port').addEventListener('click', savePort);

  // Logs
  document.getElementById('btn-refresh-logs').addEventListener('click', loadLogs);
  document.querySelectorAll('.log-pill').forEach(pill => {
    pill.addEventListener('click', () => {
      pill.classList.toggle('active');
      loadLogs();
    });
  });

  // Settings — auth
  document.getElementById('btn-reveal-token').addEventListener('click', revealToken);
  document.getElementById('btn-regen-token').addEventListener('click', regenToken);
  document.getElementById('btn-copy-token').addEventListener('click', copyToken);
}

// ── Init ──────────────────────────────────────────────────────────────────────

function initApp() {
  switchTab('dashboard');
}

async function init() {
  wireEvents();

  const stored = localStorage.getItem('gw_token');
  if (!stored) {
    showModal(false);
    return;
  }

  state.token = stored;
  try {
    await api('/api/identity');
    hideModal();
    initApp();
  } catch (e) {
    if (e.message === 'unauthorized') {
      showModal(false);
    } else {
      hideModal();
      initApp();
    }
  }
}

document.addEventListener('DOMContentLoaded', init);
