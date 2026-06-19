/* ═══════════════════════════════════════
   NetWatch Dashboard — app.js
   Polling, rendering, modals, sparklines
═══════════════════════════════════════ */

const POLL_INTERVAL = 15000;
let statusData  = null;
let hostsConfig = [];
let arpData     = {};
let pollTimer   = null;

/* ─── INIT ─── */
document.addEventListener('DOMContentLoaded', () => {
  startClock();
  setupEventDelegation();
  loadAll();
  pollTimer = setInterval(loadAll, POLL_INTERVAL);
});

function startClock() {
  const el = document.getElementById('clock');
  const tick = () => {
    el.textContent = new Date().toLocaleTimeString('es-AR',
      {hour:'2-digit', minute:'2-digit', second:'2-digit'});
  };
  tick();
  setInterval(tick, 1000);
}

/* ─── EVENT DELEGATION (evita problemas con onclick inline) ─── */
function setupEventDelegation() {
  document.getElementById('hostGrid').addEventListener('click', e => {
    const btn = e.target.closest('[data-action]');
    if (!btn) return;
    const action = btn.dataset.action;
    const ip     = btn.dataset.ip;
    const name   = btn.dataset.name || ip;
    const enabled = btn.dataset.enabled === 'true';

    if (action === 'tracert') openTracert(ip, name);
    if (action === 'toggle')  toggleHost(ip, enabled);
    if (action === 'remove')  removeHost(ip, name);
  });
}

/* ─── FETCH HELPER ─── */
async function fetchJSON(url, opts = {}) {
  const r = await fetch(url, opts);
  if (r.status === 401) { const e = new Error('Unauthorized'); e.status = 401; throw e; }
  const text = await r.text();
  if (!text.trim()) return {};
  return JSON.parse(text);
}

/* ─── LOAD ALL DATA ─── */
async function loadAll() {
  try {
    const [status, hosts, arp] = await Promise.all([
      fetchJSON('/api/status'),
      fetchJSON('/api/hosts'),
      fetchJSON('/api/arp')
    ]);
    statusData  = status;
    hostsConfig = Array.isArray(hosts) ? hosts : [];
    if (arp && arp.entries) {
      arp.entries.forEach(e => { arpData[e.ip] = e; });
    }
    render();
  } catch(e) {
    if (e.status === 401) window.location.href = '/login.html';
    console.error('Error cargando datos:', e);
  }
}

function refreshNow() {
  clearInterval(pollTimer);
  loadAll();
  pollTimer = setInterval(loadAll, POLL_INTERVAL);
}

/* ─── RENDER ─── */
function render() {
  if (!hostsConfig) return;

  const statusHosts = statusData && statusData.hosts ? statusData.hosts : [];

  // Get gateway subnet prefix (e.g. "192.168.41.")
  const gatewayIp = statusData && statusData.gatewayIp ? statusData.gatewayIp : '';
  const gatewaySubnet = gatewayIp ? gatewayIp.split('.').slice(0, 3).join('.') + '.' : null;

  // Mapeamos los hosts configurados enriqueciéndolos con los datos de ping actuales si existen
  const hosts = hostsConfig.map(hc => {
    // Determine internetAccess (true if forced true, false if forced false, otherwise check subnet match)
    let internetAccess = false;
    if (hc.internetAccess === true) {
      internetAccess = true;
    } else if (hc.internetAccess === false) {
      internetAccess = false;
    } else {
      const isInternetGroup = hc.group && hc.group.toLowerCase() === 'internet';
      internetAccess = !isInternetGroup && !!(gatewaySubnet && hc.ip.startsWith(gatewaySubnet));
    }

    const sh = statusHosts.find(s => s.ip === hc.ip);
    if (sh) {
      if (!hc.enabled) {
        return {
          ip: hc.ip, name: hc.name, group: hc.group,
          downtimeCount: hc.downtimeCount || 0,
          internetAccess: internetAccess,
          status: 'disabled',
          loss: null, avgLatency: null, minLatency: null, maxLatency: null
        };
      }
      return {
        ...sh,
        name: hc.name,
        group: hc.group,
        downtimeCount: hc.downtimeCount || 0,
        internetAccess: internetAccess,
        status: (sh.status === 'disabled') ? 'loading' : sh.status
      };
    } else {
      return {
        ip: hc.ip, name: hc.name, group: hc.group,
        downtimeCount: hc.downtimeCount || 0,
        internetAccess: internetAccess,
        status: hc.enabled ? 'loading' : 'disabled',
        loss: null, avgLatency: null, minLatency: null, maxLatency: null
      };
    }
  });

  // Stats
  const enabled = hosts.filter(h => h.status !== 'disabled');
  const online  = enabled.filter(h => h.status === 'online');
  const warning = enabled.filter(h => h.status === 'warning');
  const offline = enabled.filter(h => h.status === 'offline');

  document.getElementById('statTotal').textContent   = enabled.length;
  document.getElementById('statOnline').textContent  = online.length;
  document.getElementById('statWarning').textContent = warning.length;
  document.getElementById('statOffline').textContent = offline.length;

  // Alert banner
  const problems = [...offline, ...warning];
  const banner   = document.getElementById('alertBanner');
  if (problems.length > 0) {
    const detail = problems.map(h =>
      `${h.name} (${h.ip}): ${h.status === 'offline' ? 'SIN RESPUESTA' : h.loss + '% pérdida'}`
    ).join('  |  ');
    document.getElementById('alertDetail').textContent = detail;
    banner.classList.add('visible');
  } else {
    banner.classList.remove('visible');
  }

  // Timestamp
  if (statusData.timestamp) {
    const d = new Date(statusData.timestamp.replace('T', ' '));
    document.getElementById('lastUpdate').textContent =
      d.toLocaleTimeString('es-AR', {hour:'2-digit', minute:'2-digit', second:'2-digit'});
  }

  // Agrupar y ordenar
  const groupOrder = ['Infraestructura', 'Servidores', 'Internet'];
  const groups = {};
  hosts.forEach(h => {
    const g = h.group || 'General';
    if (!groups[g]) groups[g] = [];
    groups[g].push(h);
  });

  const sortedGroups = Object.keys(groups).sort((a, b) => {
    const ai = groupOrder.indexOf(a), bi = groupOrder.indexOf(b);
    if (ai >= 0 && bi >= 0) return ai - bi;
    if (ai >= 0) return -1; if (bi >= 0) return 1;
    return a.localeCompare(b);
  });

  // Calcular estado de Internet global
  const internetHosts = hosts.filter(h => h.group && h.group.toLowerCase() === 'internet');
  const activeInternet = internetHosts.filter(h => h.status === 'online' || h.status === 'warning');

  const globalInternetOnline = activeInternet.length > 0;
  const globalInternetLatency = (() => {
    if (!globalInternetOnline) return null;
    const latencies = activeInternet.filter(h => h.avgLatency !== null).map(h => h.avgLatency);
    return latencies.length > 0 ? Math.round(latencies.reduce((a,b)=>a+b, 0) / latencies.length) : null;
  })();

  const internetEl = document.getElementById('internetStatus');
  if (internetEl) {
    if (globalInternetOnline) {
      internetEl.innerHTML = `
        <span class="status-dot-mini online"></span>
        Internet: <span class="status-lat">${globalInternetLatency !== null ? globalInternetLatency + 'ms' : 'CONECTADO'}</span>
      `;
      internetEl.title = `Conexión activa. Hosts online: ${activeInternet.length}/${internetHosts.length}`;
    } else if (internetHosts.length === 0) {
      internetEl.innerHTML = `
        <span class="status-dot-mini" style="background:var(--text-3)"></span>
        Internet: <span style="color:var(--text-3)">Sin configurar</span>
      `;
      internetEl.title = "Agrega hosts en el group 'Internet' para medir conectividad.";
    } else {
      internetEl.innerHTML = `
        <span class="status-dot-mini offline"></span>
        Internet: <span style="color:var(--red); font-weight:700">SIN CONEXIÓN</span>
      `;
      internetEl.title = "Todos los hosts de diagnóstico de Internet están caídos.";
    }
  }

  const grid = document.getElementById('hostGrid');
  grid.innerHTML = '';

  if (hosts.length === 0) {
    grid.innerHTML = `<div class="loading-placeholder">
      <p>No hay hosts configurados.</p>
      <button class="btn-primary" style="margin-top:16px" onclick="openAddModal()">＋ Agregar primera IP</button>
    </div>`;
    return;
  }

  sortedGroups.forEach(group => {
    const label = document.createElement('div');
    label.className = 'group-label';
    label.textContent = group;
    grid.appendChild(label);

    const statusPriority = {offline:0, warning:1, loading:2, online:3, disabled:4};
    const sorted = groups[group].slice().sort((a,b) =>
      (statusPriority[a.status]??5) - (statusPriority[b.status]??5));

    sorted.forEach(host => grid.appendChild(buildCard(host, globalInternetOnline, globalInternetLatency)));
  });

  // Cargar sparklines después
  hosts.filter(h => h.status !== 'disabled' && h.status !== 'loading')
       .forEach(h => loadSparkline(h.ip));
}

/* ─── BUILD HOST CARD ─── */
function buildCard(host, globalInternetOnline, globalInternetLatency) {
  const card = document.createElement('div');
  card.className = `host-card status-${host.status}`;
  card.id = `card-${host.ip.replace(/\./g,'_')}`;

  const lossClass   = !host.loss ? 'ok' : host.loss < 50 ? 'med' : 'bad';
  const lossDisplay = host.loss === null || host.loss === undefined ? '—' : host.loss + '%';
  const lossWidth   = Math.min(100, host.loss || 0);
  const isDisabled  = host.status === 'disabled';
  const isLoading   = host.status === 'loading';

  const latColor = host.avgLatency === null ? 'var(--text-3)' :
    host.avgLatency < 5   ? 'var(--green)' :
    host.avgLatency < 50  ? 'var(--cyan)'  :
    host.avgLatency < 150 ? 'var(--amber)' : 'var(--red)';

  // Info ARP/Topología
  const arp = arpData[host.ip];
  const macHtml = arp ? `
    <div class="card-topo">
      <span class="topo-mac">🔌 ${arp.mac || '—'}</span>
      ${arp.vendor ? `<span class="topo-vendor">${escHtml(arp.vendor)}</span>` : ''}
      ${arp.hops  ? `<span class="topo-hops">${arp.hops === 1 ? '📍 Misma red' : `🔀 ${arp.hops} saltos`}</span>` : ''}
    </div>` : '';

  // Badge de Internet
  let internetBadgeHtml = '';
  if (host.internetAccess) {
    if (globalInternetOnline) {
      const latText = globalInternetLatency !== null ? `${globalInternetLatency}ms` : 'OK';
      internetBadgeHtml = `
        <div class="internet-badge-card" title="Este host tiene acceso a Internet (Conectado: ${latText})">
          🌐 Internet: <span style="color: var(--green); font-weight: 600;">${latText}</span>
        </div>
      `;
    } else {
      internetBadgeHtml = `
        <div class="internet-badge-card" title="Este host tiene acceso a Internet (Sin conexión)">
          🌐 Internet: <span style="color: var(--red); font-weight: 700;">🔴</span>
        </div>
      `;
    }
  }

  card.innerHTML = `
    <div class="card-head">
      <div class="card-info">
        <div class="card-name" title="${escHtml(host.name)}">${escHtml(host.name)}</div>
        <div class="card-ip">${escHtml(host.ip)}</div>
        <div class="card-group">
          ${escHtml(host.group || '')}
          ${host.downtimeCount ? `<span class="down-count-badge" title="Cantidad de caídas de conexión">⚠️ ${host.downtimeCount}</span>` : ''}
        </div>
      </div>
      <div style="display: flex; flex-direction: column; align-items: flex-end;">
        <div class="status-badge ${host.status}">
          <div class="status-dot ${host.status}"></div>
          ${statusLabel(host.status)}
        </div>
        ${internetBadgeHtml}
      </div>
    </div>

    ${macHtml}

    <div class="metrics-row">
      <div class="metric">
        <span class="metric-val" style="color:${latColor}">
          ${host.avgLatency !== null ? host.avgLatency + 'ms' : '—'}
        </span>
        <span class="metric-label">Latencia</span>
      </div>
      <div class="metric">
        <span class="metric-val" style="color:var(--text-2)">
          ${host.minLatency !== null ? host.minLatency + 'ms' : '—'}
        </span>
        <span class="metric-label">Mínima</span>
      </div>
      <div class="metric">
        <span class="metric-val" style="color:var(--text-2)">
          ${host.maxLatency !== null ? host.maxLatency + 'ms' : '—'}
        </span>
        <span class="metric-label">Máxima</span>
      </div>
    </div>

    <div class="loss-bar-wrap">
      <div class="loss-bar-head">
        <span class="loss-bar-label">Pérdida de paquetes</span>
        <span class="loss-bar-val ${lossClass}">${lossDisplay}</span>
      </div>
      <div class="loss-bar-bg">
        <div class="loss-bar-fill ${lossClass}" style="width:${lossWidth}%"></div>
      </div>
    </div>

    <div class="sparkline-wrap">
      <div class="sparkline-label">Historial de latencia</div>
      <svg class="sparkline" id="spark-${host.ip.replace(/\./g,'_')}"></svg>
    </div>

    <div class="card-actions">
      ${!isDisabled && !isLoading
        ? `<button class="card-btn tracert"
              data-action="tracert"
              data-ip="${escAttr(host.ip)}"
              data-name="${escAttr(host.name)}">🔍 Diagnosticar</button>`
        : '<button class="card-btn tracert" style="opacity:0.3" disabled>🔍 Diagnosticar</button>'
      }
      <button class="card-btn toggle"
              data-action="toggle"
              data-ip="${escAttr(host.ip)}"
              data-name="${escAttr(host.name)}"
              data-enabled="${!isDisabled}">
        ${isDisabled ? '▶ Activar' : '⏸ Pausar'}
      </button>
      <button class="card-btn remove"
              data-action="remove"
              data-ip="${escAttr(host.ip)}"
              data-name="${escAttr(host.name)}"
              title="Eliminar del monitoreo">✕</button>
    </div>
  `;

  return card;
}

function statusLabel(s) {
  return {
    online:'EN LÍNEA', warning:'CON PÉRDIDA', offline:'SIN RESPUESTA',
    disabled:'PAUSADO', loading:'MIDIENDO...'
  }[s] || s.toUpperCase();
}

/* ─── SPARKLINE ─── */
async function loadSparkline(ip) {
  try {
    const data = await fetchJSON(`/api/history?ip=${ip}`);
    if (!Array.isArray(data) || data.length < 2) return;
    const svg = document.getElementById(`spark-${ip.replace(/\./g,'_')}`);
    if (!svg) return;
    drawSparkline(svg, data.slice(-60));
  } catch(e) {}
}

function drawSparkline(svg, data) {
  const W = svg.parentElement.offsetWidth || 280;
  const H = 40;
  svg.setAttribute('viewBox', `0 0 ${W} ${H}`);

  const latencies = data.map(d => d.l || 0);
  const maxL = Math.max(...latencies, 5);

  const pts = data.map((d, i) => {
    const x = (i / Math.max(data.length - 1, 1)) * W;
    const y = H - 2 - (((d.l || 0) / maxL) * (H - 4));
    return `${x},${y}`;
  }).join(' ');

  let lossMarkers = '';
  data.forEach((d, i) => {
    if (d.p > 0) {
      const x = (i / Math.max(data.length - 1, 1)) * W;
      lossMarkers += `<rect x="${x-1.5}" y="0" width="3" height="${H}"
        fill="rgba(255,59,92,${0.2 + Math.min(d.p/100, 1) * 0.5})" rx="1"/>`;
    }
  });

  svg.innerHTML = `${lossMarkers}
    <polyline points="${pts}" fill="none" stroke="rgba(0,212,255,0.8)"
              stroke-width="1.5" stroke-linejoin="round" stroke-linecap="round"/>`;
}

/* ─── TRACERT MODAL ─── */
async function openTracert(ip, name) {
  document.getElementById('tracertTitle').textContent = `Diagnóstico — ${name} (${ip})`;
  document.getElementById('tracertBody').innerHTML = `
    <div style="text-align:center;padding:40px">
      <div class="spinner"></div>
      <p style="margin-top:12px;color:#8892a4">Ejecutando tracert hacia ${escHtml(ip)}...<br>
      <small style="color:#4a5a72">Puede tardar hasta 30 segundos</small></p>
    </div>`;
  openModal('tracertModal');
  try {
    const data = await fetchJSON(`/api/tracert?ip=${encodeURIComponent(ip)}`);
    renderTracert(data);
  } catch(e) {
    document.getElementById('tracertBody').innerHTML =
      `<p style="color:var(--red);padding:20px">Error: ${escHtml(e.message)}</p>`;
  }
}

function renderTracert(data) {
  if (!data || !data.hops) {
    document.getElementById('tracertBody').innerHTML =
      '<p style="color:var(--text-3);padding:20px">Sin datos de tracert.</p>';
    return;
  }

  const hops = Array.isArray(data.hops) ? data.hops : [];
  const ts   = data.timestamp ? `Ejecutado: ${data.timestamp.replace('T',' ')}` : '';

  // Detectar causa del corte
  let causHop = null;
  let hadResponse = false;
  for (const h of hops) {
    if (!h.timeout && h.ip) { hadResponse = true; }
    else if (h.timeout && hadResponse) { causHop = h.hop; break; }
  }

  const lastHop = hops[hops.length - 1];
  const reached = lastHop && !lastHop.timeout && lastHop.ip === data.ip;
  const allTimeout = hops.length > 0 && hops.every(h => h.timeout);

  let summaryHtml = '';
  if (allTimeout) {
    summaryHtml = `<div class="tracert-summary problem">
      <div class="tracert-summary-title">🔴 Host completamente inalcanzable</div>
      <div class="tracert-summary-text">El tráfico se pierde desde el primer salto.
      Posible causa: firewall bloqueando ICMP, cable desconectado o dispositivo apagado.</div>
    </div>`;
  } else if (causHop) {
    const prev = hops.find(h => h.hop === causHop - 1);
    summaryHtml = `<div class="tracert-summary problem">
      <div class="tracert-summary-title">🔴 Corte detectado en Salto ${causHop}</div>
      <div class="tracert-summary-text">El tráfico llega hasta el salto ${causHop - 1}
      (${escHtml(prev?.ip || 'desconocido')}) pero falla en el salto ${causHop}.
      Revisá el dispositivo o enlace en esa posición.</div>
    </div>`;
  } else if (reached) {
    summaryHtml = `<div class="tracert-summary ok">
      <div class="tracert-summary-title">🟢 Host alcanzado correctamente</div>
      <div class="tracert-summary-text">La ruta completa responde.
      El problema puede ser intermitente o ya fue resuelto.</div>
    </div>`;
  }

  const hopsHtml = hops.map(h => {
    const isCause = h.hop === causHop;
    const isDest  = !h.timeout && h.ip === data.ip;
    const tagHtml = isCause ? '<span class="hop-tag cause">⚡ CAUSA PROBABLE</span>'
                  : isDest  ? '<span class="hop-tag dest">🎯 DESTINO</span>' : '';
    if (h.timeout) {
      return `<div class="tracert-hop" style="${isCause ? 'background:rgba(255,59,92,0.08);border-color:rgba(255,59,92,0.2)' : ''}">
        <div class="hop-num timeout">${h.hop}</div>
        <span class="hop-arrow">→</span>
        <div class="hop-info">
          <div class="hop-ip" style="color:var(--text-3)">* * * (Sin respuesta)</div>
          <div class="hop-ms">Timeout</div>
        </div>${tagHtml}
      </div>`;
    }
    return `<div class="tracert-hop" style="${isDest ? 'background:rgba(0,212,255,0.05);border-color:rgba(0,212,255,0.15)' : ''}">
      <div class="hop-num ok">${h.hop}</div>
      <span class="hop-arrow">→</span>
      <div class="hop-info">
        <div class="hop-ip">${escHtml(h.ip || '?')}</div>
        <div class="hop-ms">${h.avgMs !== null ? h.avgMs + ' ms' : '—'}</div>
      </div>${tagHtml}
    </div>`;
  }).join('');

  document.getElementById('tracertBody').innerHTML = `
    <p class="tracert-ts">${escHtml(ts)}</p>
    ${summaryHtml}
    <div class="tracert-chain">${hopsHtml || '<p style="color:var(--text-3);text-align:center;padding:20px">Sin resultados.</p>'}</div>`;
}

/* ─── ADD HOST ─── */
function openAddModal() {
  ['addIp','addName','addGroup'].forEach(id => document.getElementById(id).value = '');
  document.getElementById('addInternet').value = 'auto';
  setModalMsg('addMsg', '', '');
  openModal('addModal');
  setTimeout(() => document.getElementById('addIp').focus(), 100);
}

async function submitAddHost() {
  const ip          = document.getElementById('addIp').value.trim();
  const name        = document.getElementById('addName').value.trim() || ip;
  const group       = document.getElementById('addGroup').value.trim() || 'General';
  const internetVal = document.getElementById('addInternet').value;
  
  if (!ip || !isValidIP(ip)) {
    setModalMsg('addMsg', 'Ingresá una IP válida (ej: 192.168.40.10)', 'error'); return;
  }

  const payload = { ip, name, group, enabled: true };
  if (internetVal === 'true') {
    payload.internetAccess = true;
  } else if (internetVal === 'false') {
    payload.internetAccess = false;
  }

  try {
    const r = await fetchJSON('/api/hosts', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify(payload)
    });
    if (r.success) {
      setModalMsg('addMsg', `✓ ${ip} agregado correctamente.`, 'success');
      setTimeout(() => { closeModal('addModal'); loadAll(); }, 1200);
    } else {
      setModalMsg('addMsg', r.error || 'Error al agregar.', 'error');
    }
  } catch(e) { setModalMsg('addMsg', 'Error de conexión.', 'error'); }
}

/* ─── BULK ADD ─── */
function openBulkModal() {
  document.getElementById('bulkText').value  = '';
  document.getElementById('bulkGroup').value = '';
  setModalMsg('bulkMsg', '', '');
  openModal('bulkModal');
  setTimeout(() => document.getElementById('bulkText').focus(), 100);
}

async function submitBulk() {
  const raw          = document.getElementById('bulkText').value;
  const defaultGroup = document.getElementById('bulkGroup').value.trim() || 'General';
  const lines        = raw.split('\n').map(l => l.trim()).filter(l => l && !l.startsWith('#'));
  const parsed       = [];
  for (const line of lines) {
    const parts = line.split(',').map(p => p.trim());
    const ip    = parts[0];
    if (!ip || !isValidIP(ip)) continue;
    parsed.push({ ip, name: parts[1] || ip, group: parts[2] || defaultGroup, enabled: true });
  }
  if (parsed.length === 0) {
    setModalMsg('bulkMsg', 'No se encontraron IPs válidas.', 'error'); return;
  }
  try {
    const r = await fetchJSON('/api/hosts/bulk', {
      method:'POST', headers:{'Content-Type':'application/json'},
      body: JSON.stringify({hosts: parsed})
    });
    if (r.success) {
      setModalMsg('bulkMsg', `✓ ${r.added} agregadas, ${r.skipped} omitidas (ya existían).`, 'success');
      setTimeout(() => { closeModal('bulkModal'); loadAll(); }, 2000);
    } else {
      setModalMsg('bulkMsg', r.error || 'Error en importación.', 'error');
    }
  } catch(e) { setModalMsg('bulkMsg', 'Error de conexión.', 'error'); }
}

/* ─── TOGGLE / REMOVE ─── */
async function toggleHost(ip, currentEnabled) {
  try {
    const r = await fetchJSON('/api/toggle', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ip, enabled: !currentEnabled})
    });
    if (r.success) loadAll();
    else alert('Error al cambiar estado: ' + (r.error || 'desconocido'));
  } catch(e) { console.error('toggleHost error:', e); }
}

async function removeHost(ip, name) {
  if (!confirm('Eliminar "' + name + '" (' + ip + ') del monitoreo?')) return;
  try {
    const r = await fetchJSON('/api/hosts/remove', {
      method: 'POST',
      headers: {'Content-Type':'application/json'},
      body: JSON.stringify({ip: ip})
    });
    if (r.success) loadAll();
    else alert('Error al eliminar: ' + (r.error || 'desconocido'));
  } catch(e) { console.error('removeHost error:', e); alert('Error: ' + e.message); }
}

/* ─── MODAL HELPERS ─── */
function openModal(id)  { document.getElementById(id).classList.add('open'); }
function closeModal(id) { document.getElementById(id).classList.remove('open'); }
function setModalMsg(id, text, type) {
  const el = document.getElementById(id);
  el.textContent = text;
  el.className   = text ? `modal-msg ${type}` : 'modal-msg';
}

/* ─── DOWNTIMES MODAL ─── */
async function openDowntimesModal() {
  document.getElementById('downtimesBody').innerHTML = `
    <div style="text-align:center;padding:40px">
      <div class="spinner"></div>
      <p style="margin-top:12px;color:#8892a4">Cargando historial de caídas...</p>
    </div>`;
  openModal('downtimesModal');
  try {
    const data = await fetchJSON('/api/downtimes');
    renderDowntimes(data);
  } catch(e) {
    document.getElementById('downtimesBody').innerHTML =
      `<p style="color:var(--red);padding:20px;text-align:center">Error de conexión al cargar historial.</p>`;
  }
}

function renderDowntimes(data) {
  const body = document.getElementById('downtimesBody');
  if (!Array.isArray(data) || data.length === 0) {
    body.innerHTML = '<div style="text-align:center;padding:40px;color:var(--text-3)">No se registran caídas de conexión en el historial.</div>';
    return;
  }

  const sorted = data.slice().reverse();

  let html = `
    <table class="downtime-table" style="width:100%; border-collapse:collapse; text-align:left;">
      <thead>
        <tr style="border-bottom: 2px solid var(--card-border); color: var(--text-2); font-size:12px; font-weight:600">
          <th style="padding:10px 8px">Host / IP</th>
          <th style="padding:10px 8px">Inicio de Caída</th>
          <th style="padding:10px 8px">Restablecimiento</th>
          <th style="padding:10px 8px; text-align:right">Duración</th>
        </tr>
      </thead>
      <tbody>
  `;

  sorted.forEach(e => {
    const isOngoing = !e.upTime;
    const ongoingHtml = isOngoing ? '<span class="status-badge offline" style="padding:2px 8px; display:inline-flex; font-size:10px">EN CURSO ⚠️</span>' : escHtml(formatDateTime(e.upTime));
    const durationHtml = isOngoing ? '—' : formatDuration(e.duration);

    html += `
      <tr style="border-bottom: 1px solid rgba(255,255,255,0.05); font-size:13px; color: var(--text-2); ${isOngoing ? 'background:rgba(255,59,92,0.03)' : ''}">
        <td style="padding:12px 8px">
          <div style="font-weight:600; color:var(--text-1)">${escHtml(e.name || 'Desconocido')}</div>
          <div style="font-family:'JetBrains Mono',monospace; font-size:11px; color:var(--cyan)">${escHtml(e.ip)}</div>
        </td>
        <td style="padding:12px 8px; font-family:'JetBrains Mono',monospace">${escHtml(formatDateTime(e.downTime))}</td>
        <td style="padding:12px 8px; font-family:'JetBrains Mono',monospace">${ongoingHtml}</td>
        <td style="padding:12px 8px; text-align:right; font-weight:500; color:${isOngoing ? 'var(--red)' : 'var(--text-3)'}">${durationHtml}</td>
      </tr>
    `;
  });

  html += '</tbody></table>';
  body.innerHTML = html;
}

function formatDateTime(iso) {
  if (!iso) return '—';
  try {
    const d = new Date(iso.replace('T', ' '));
    return d.toLocaleString('es-AR', {day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit', second:'2-digit'});
  } catch(e) { return iso; }
}

function formatDuration(sec) {
  if (sec === null || sec === undefined) return '—';
  if (sec < 60) return `${sec}s`;
  const min = Math.floor(sec / 60);
  const rSec = sec % 60;
  if (min < 60) return `${min}m ${rSec}s`;
  const hr = Math.floor(min / 60);
  const rMin = min % 60;
  return `${hr}h ${rMin}m`;
}

/* ─── UTILS ─── */
function escHtml(s) {
  return String(s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;')
    .replace(/>/g,'&gt;').replace(/"/g,'&quot;');
}
function escAttr(s) {
  return String(s).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}
function isValidIP(ip) {
  return /^(\d{1,3}\.){3}\d{1,3}$/.test(ip) &&
    ip.split('.').every(n => +n >= 0 && +n <= 255);
}

document.addEventListener('keydown', e => {
  if (e.key === 'Escape')
    ['addModal','bulkModal','tracertModal','manageModal','downtimesModal'].forEach(closeModal);
  if (e.key === 'F5') { e.preventDefault(); refreshNow(); }
});
