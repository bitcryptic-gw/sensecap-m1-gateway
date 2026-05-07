'use strict';

// ── State ─────────────────────────────────────────────────────────────────────

const state = {
  token:       null,
  logLines:    [],
  logInterval: null,
  dashInterval: null,
  tokenRevealed: false,
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
    try { detail = (await r.json()).detail || detail; } catch { /* ignore */ }
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
  state.logInterval = null;
  state.dashInterval = null;

  if (name === 'dashboard') startDashboardAutoRefresh();
  if (name === 'logs')      startLogAutoRefresh();
  if (name === 'band')      loadBands();
  if (name === 'settings')  loadSettings();
}

// ── Dashboard ─────────────────────────────────────────────────────────────────

function startDashboardAutoRefresh() {
  loadDashboard();
  state.dashInterval = setInterval(loadDashboard, 30_000);
}

async function loadDashboard() {
  const [identity, status, beacon, sysinfo] = await Promise.allSettled([
    api('/api/identity'),
    api('/api/status'),
    api('/api/beacon'),
    api('/api/sysinfo'),
  ]);

  if (identity.status === 'fulfilled') renderIdentity(identity.value);
  if (status.status   === 'fulfilled') renderServices(status.value);
  if (beacon.status   === 'fulfilled') renderBeacon(beacon.value);
  if (sysinfo.status  === 'fulfilled') renderSysinfo(sysinfo.value);
}

function renderIdentity(d) {
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

function renderServices(d) {
  const el = document.getElementById('services-body');
  el.innerHTML = [d.pktfwd, d.gateway_rs].map(s => serviceRow(s)).join('');
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

function renderSysinfo(d) {
  const el = document.getElementById('sysinfo-body');
  const temp = d.cpu_temp.replace("temp=", "").replace("'C", " °C");

  // Parse free -m: "Mem:  total used free ..."
  let memLine = '';
  const memMatch = d.memory.match(/^Mem:\s+(\d+)\s+(\d+)\s+(\d+)/m);
  if (memMatch) {
    const [, total, used] = memMatch;
    const pct = Math.round((used / total) * 100);
    memLine = `${used} / ${total} MB <span class="dim">(${pct}%)</span>`;
  } else {
    memLine = `<span class="dim">${d.memory || 'unavailable'}</span>`;
  }

  // Parse df -h: second line has size/used/avail/use%
  let diskLine = '';
  const diskRows = d.disk.trim().split('\n');
  if (diskRows.length >= 2) {
    const parts = diskRows[1].trim().split(/\s+/);
    if (parts.length >= 5) {
      diskLine = `${parts[2]} used of ${parts[1]} <span class="dim">(${parts[4]})</span>`;
    }
  }
  if (!diskLine) diskLine = `<span class="dim">${d.disk || 'unavailable'}</span>`;

  el.innerHTML = kv([
    ['CPU temp', temp || 'unavailable'],
    ['Memory',   memLine],
    ['Disk /opt', diskLine],
  ]);
}

// ── Logs ──────────────────────────────────────────────────────────────────────

function startLogAutoRefresh() {
  loadLogs();
  state.logInterval = setInterval(loadLogs, 10_000);
}

async function loadLogs() {
  try {
    const data = await api('/api/logs');
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
  const filter  = document.querySelector('.filter-btn.active')?.dataset.filter ?? 'all';
  const output  = document.getElementById('log-output');
  const lines   = filter === 'all'
    ? state.logLines
    : state.logLines.filter(l => l.toLowerCase().includes(filter));
  output.textContent = lines.length ? lines.join('\n') : '(no matching log lines)';
  output.scrollTop = output.scrollHeight;
}

// ── Band ──────────────────────────────────────────────────────────────────────

async function loadBands() {
  try {
    const data = await api('/api/bands');
    const sel  = document.getElementById('band-select');
    sel.innerHTML = data.regions.map(r =>
      `<option value="${r}"${r === data.current ? ' selected' : ''}>${r}</option>`
    ).join('');
    document.getElementById('current-band').textContent = data.current || '—';
  } catch (e) {
    if (e.message !== 'unauthorized') showResult('band-result', e.message, true);
  }
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

// ── Settings ──────────────────────────────────────────────────────────────────

async function loadSettings() {
  try {
    const s = await api('/api/settings');
    document.getElementById('lan-toggle').checked = s.lan_access;
    document.getElementById('port-input').value   = s.port;
    updateLanHint(s.lan_access, s.bind_host);
  } catch (e) { /* ignore if tab just opened */ }
}

function updateLanHint(enabled, host) {
  const hint = document.getElementById('lan-hint');
  hint.textContent = enabled ? 'Binding 0.0.0.0 (LAN + Tailscale)' : `Binding ${host} (Tailscale only)`;
}

async function setLanAccess(enabled) {
  try {
    const r = await api('/api/settings/lan', 'POST', { enabled });
    updateLanHint(enabled, r.bind_host);
  } catch (e) {
    if (e.message !== 'unauthorized') alert(`Failed: ${e.message}`);
    // Revert toggle
    document.getElementById('lan-toggle').checked = !enabled;
  }
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
    // Update stored token so UI stays live until service restarts
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
    setTimeout(() => {
      document.getElementById('btn-copy-token').textContent = 'Copy to clipboard';
    }, 2000);
  } catch {
    alert('Copy failed — select and copy manually.');
  }
}

// ── Utilities ─────────────────────────────────────────────────────────────────

function kv(pairs) {
  return pairs.map(([k, v]) => `
    <div class="kv-row">
      <span class="kv-label">${k}</span>
      <span class="kv-value">${v}</span>
    </div>`).join('');
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
  el.className   = 'result-msg ' + (isError ? 'result-error' : 'result-ok');
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

  // Dashboard — restart buttons (delegated)
  document.getElementById('services-body').addEventListener('click', async e => {
    const btn = e.target.closest('.btn-restart');
    if (!btn) return;
    const service = btn.dataset.service;
    btn.disabled = true;
    btn.textContent = '…';
    try {
      await api(`/api/restart/${service}`, 'POST');
      setTimeout(loadDashboard, 2000);
    } catch (err) {
      if (err.message !== 'unauthorized') alert(`Restart failed: ${err.message}`);
    } finally {
      btn.disabled = false;
      btn.textContent = 'Restart';
    }
  });

  // Logs
  document.getElementById('btn-refresh-logs').addEventListener('click', loadLogs);
  document.querySelectorAll('.filter-btn').forEach(btn => {
    btn.addEventListener('click', () => {
      document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
      btn.classList.add('active');
      renderLogOutput();
    });
  });

  // Band
  document.getElementById('btn-apply-band').addEventListener('click', applyBand);

  // Settings — network
  document.getElementById('lan-toggle').addEventListener('change', e => {
    setLanAccess(e.target.checked);
  });
  document.getElementById('btn-save-port').addEventListener('click', savePort);

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
      // Service temporarily unreachable — still proceed
      hideModal();
      initApp();
    }
  }
}

document.addEventListener('DOMContentLoaded', init);
