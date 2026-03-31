/**
 * OTel Ops — Telemetry Observer
 * Shows all collectors and all signals at once. No clicking required.
 */

let collectors = {};
let currentRange = "all";

// ---- Theme Toggle ----

const themeToggle = document.getElementById("theme-toggle");
const root = document.documentElement;

function applyTheme(theme) {
  root.setAttribute("data-theme", theme);
  themeToggle.innerHTML = theme === "dark" ? "&#9788;" : "&#9790;";
  themeToggle.title = theme === "dark" ? "Switch to light mode" : "Switch to dark mode";
  localStorage.setItem("otel-ops-theme", theme);
}

themeToggle.addEventListener("click", () => {
  const current = root.getAttribute("data-theme") || "light";
  applyTheme(current === "dark" ? "light" : "dark");
});

// Restore saved preference or respect OS preference
const saved = localStorage.getItem("otel-ops-theme");
if (saved) {
  applyTheme(saved);
} else if (window.matchMedia("(prefers-color-scheme: dark)").matches) {
  applyTheme("dark");
}

const healthPill = document.getElementById("health-pill");
const tilesEl = document.getElementById("collector-tiles");
const rangeSelect = document.getElementById("time-range");
const refreshBtn = document.getElementById("btn-refresh");

const SIGNAL_COLORS = { logs: "#ffb566", metrics: "#be85ff", traces: "#35d6ff" };

// ---- Utilities ----

function formatNum(n) {
  if (n >= 1_000_000) return (n / 1_000_000).toFixed(1) + "M";
  if (n >= 1_000) return (n / 1_000).toFixed(1) + "K";
  return String(n);
}

function formatTime(iso) {
  if (!iso) return "";
  return new Date(iso).toLocaleTimeString("en-US", { hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function nanoToMs(start, end) {
  if (!start || !end) return 0;
  try { return Number((BigInt(end) - BigInt(start)) / 1000000n); } catch { return 0; }
}

// ---- Health ----

async function checkHealth() {
  try {
    const res = await fetch("/api/health");
    const data = await res.json();
    healthPill.textContent = data.status === "ok" ? "Connected" : "Misconfigured";
    healthPill.className = `status-pill ${data.status === "ok" ? "ok" : "error"}`;
  } catch (_) {
    healthPill.textContent = "Offline";
    healthPill.className = "status-pill error";
  }
}

// ---- Collectors ----

async function loadCollectors() {
  const res = await fetch("/api/collectors");
  collectors = await res.json();
}

// ---- Counts + Tiles ----

async function loadCounts() {
  try {
    const res = await fetch(`/api/counts?range=${currentRange}`);
    const data = await res.json();
    renderTiles(data);
  } catch (_) {}
}

function renderTiles(counts) {
  tilesEl.innerHTML = "";
  // Only show sidecar collector tiles (exclude direct)
  for (const [cid, c] of Object.entries(collectors)) {
    if (cid === "direct") continue;
    const cc = counts[cid] || {};
    const tile = document.createElement("div");
    tile.className = "collector-tile";
    const signals = c.signals.map(s => `<span class="tile-signal" style="color:${SIGNAL_COLORS[s]}">${s}</span>`).join(" ");
    const countItems = c.signals.map(s => {
      const n = cc[s] || 0;
      return `<div class="tile-count"><span class="tile-count-num">${formatNum(n)}</span><span class="tile-count-label">${s}</span></div>`;
    }).join("");
    tile.innerHTML = `
      <div class="tile-header"><div class="tile-name">${c.label}</div><div class="tile-signals">${signals}</div></div>
      <div class="tile-counts">${countItems}</div>
    `;
    tilesEl.appendChild(tile);
  }
  // Pulse all tiles to indicate refresh
  tilesEl.querySelectorAll(".collector-tile").forEach(t => {
    t.classList.remove("pulse");
    void t.offsetWidth;
    t.classList.add("pulse");
  });
}

// ---- Load All Sections ----

let sectionsBuilt = false;
const previousKeys = {};  // track seen items per column for new-row highlighting

function rowKey(signal, item) {
  if (signal === "traces") return item.trace_id || "";
  if (signal === "logs") return `${item.time}|${item.body || ""}|${item.severity_text || ""}`;
  return `${item.name || ""}|${item.time || ""}|${item.value || ""}`;
}

// For metrics we build keys after grouping, so we also need per-column grouped keys
function metricsGroupKeys(metrics) {
  const byName = {};
  metrics.forEach(m => {
    const name = m.name || "unknown";
    if (!byName[name]) byName[name] = 0;
    byName[name]++;
  });
  return new Set(Object.entries(byName).map(([name, count]) => `${name}|${count}`));
}

function buildSections() {
  const signals = ["traces", "logs", "metrics"];
  for (const signal of signals) {
    const sectionEl = document.getElementById(`${signal}-section`);
    if (!sectionEl) continue;
    sectionEl.innerHTML = "";

    // Exclude "direct" from sidecar signal sections
    const capable = Object.entries(collectors).filter(([cid, c]) => cid !== "direct" && c.signals.includes(signal));
    sectionEl.style.gridTemplateColumns = `repeat(${capable.length}, 1fr)`;

    for (const [cid, c] of capable) {
      const col = document.createElement("div");
      col.className = "collector-column";
      col.innerHTML = `
        <div class="col-header">
          <span class="col-name">${c.label}</span>
          <span class="col-table">${c.tables[signal]}</span>
        </div>
        <div class="col-content" id="col-${signal}-${cid}">
          <div class="empty-state small">Loading...</div>
        </div>
      `;
      sectionEl.appendChild(col);
    }
  }

  // Build Direct section
  buildDirectSection();
  sectionsBuilt = true;
}

function buildDirectSection() {
  const directEl = document.getElementById("direct-columns");
  if (!directEl) return;
  const direct = collectors["direct"];
  if (!direct) return;
  directEl.innerHTML = "";

  const signals = ["traces", "logs", "metrics"];
  for (const signal of signals) {
    if (!direct.signals.includes(signal)) continue;
    const col = document.createElement("div");
    col.className = "collector-column";
    col.innerHTML = `
      <div class="col-header">
        <span class="col-name">${signal.charAt(0).toUpperCase() + signal.slice(1)}</span>
        <span class="col-table">${direct.tables[signal]}</span>
      </div>
      <div class="col-content" id="col-${signal}-direct">
        <div class="empty-state small">Loading...</div>
      </div>
    `;
    directEl.appendChild(col);
  }
}

async function loadAllSignals() {
  if (!sectionsBuilt) buildSections();

  const signals = ["traces", "logs", "metrics"];
  for (const signal of signals) {
    // Sidecar collectors
    const capable = Object.entries(collectors).filter(([cid, c]) => cid !== "direct" && c.signals.includes(signal));
    for (const [cid, c] of capable) {
      fetchSignalData(signal, cid, c);
    }
    // Direct collector
    if (collectors["direct"] && collectors["direct"].signals.includes(signal)) {
      fetchSignalData(signal, "direct", collectors["direct"]);
    }
  }
}

async function fetchSignalData(signal, cid, c) {
  const contentEl = document.getElementById(`col-${signal}-${cid}`);
  if (!contentEl) return;
  try {
    const res = await fetch(`/api/${signal}/${cid}?range=${currentRange}&limit=20`);
    const data = await res.json();
    const items = data[signal] || [];
    if (items.length === 0) {
      contentEl.innerHTML = '<div class="empty-state small">No data</div>';
      return;
    }
    const colKey = `${signal}-${cid}`;
    const prevSet = previousKeys[colKey] || new Set();
    if (signal === "metrics") {
      const newKeys = metricsGroupKeys(items);
      previousKeys[colKey] = newKeys;
      renderMetricsColumn(contentEl, items, prevSet);
    } else {
      const newKeys = new Set(items.map(item => rowKey(signal, item)));
      previousKeys[colKey] = newKeys;
      if (signal === "traces") renderTracesColumn(contentEl, items, cid, prevSet);
      else if (signal === "logs") renderLogsColumn(contentEl, items, prevSet);
    }
  } catch (err) {
    contentEl.innerHTML = `<div class="empty-state small error">${err.message}</div>`;
  }
}

// ---- Render: Traces Column ----

function renderTracesColumn(el, traces, collector, prevSet) {
  const byTrace = {};
  traces.forEach(t => {
    const tid = t.trace_id || "?";
    if (!byTrace[tid]) byTrace[tid] = { spans: [], first: t };
    byTrace[tid].spans.push(t);
  });

  let html = '<div class="mini-table">';
  for (const [tid, group] of Object.entries(byTrace)) {
    const root = group.first;
    const durMs = nanoToMs(root.start_time_unix_nano, root.end_time_unix_nano);
    const spanCount = group.spans.length;
    const isNew = prevSet.size > 0 && !prevSet.has(tid);
    html += `
      <div class="mini-row clickable${isNew ? " new-row" : ""}" data-trace-id="${tid}" data-collector="${collector}">
        <div class="mini-row-main">
          <span class="mini-time">${formatTime(root.time)}</span>
          <span class="mini-name">${root.name || "span"}</span>
        </div>
        <div class="mini-row-meta">
          <span class="mini-badge traces">${spanCount} spans</span>
          <span class="mini-dur">${durMs}ms</span>
        </div>
      </div>
    `;
  }
  html += "</div>";
  el.innerHTML = html;

  el.querySelectorAll(".clickable").forEach(row => {
    row.addEventListener("click", () => openTraceTimeline(row.dataset.traceId, row.dataset.collector));
  });
}

// ---- Render: Logs Column ----

function renderLogsColumn(el, logs, prevSet) {
  let html = '<div class="mini-table">';
  logs.forEach((log, i) => {
    const sevClass = (log.severity_text || "").toLowerCase().includes("error") ? "critical"
      : (log.severity_text || "").toLowerCase().includes("warn") ? "warn" : "normal";
    const body = (log.body || "").slice(0, 80);
    const key = rowKey("logs", log);
    const isNew = prevSet.size > 0 && !prevSet.has(key);
    html += `
      <div class="mini-row${isNew ? " new-row" : ""}" data-idx="${i}">
        <div class="mini-row-main">
          <span class="mini-time">${formatTime(log.time)}</span>
          <span class="sev-badge ${sevClass}">${log.severity_text || "INFO"}</span>
          <span class="mini-body">${body}</span>
        </div>
      </div>
    `;
  });
  html += "</div>";
  el.innerHTML = html;

  el.querySelectorAll(".mini-row").forEach(row => {
    row.style.cursor = "pointer";
    row.addEventListener("click", () => {
      const idx = parseInt(row.dataset.idx, 10);
      openDetailModal("Log Record", logs[idx]);
    });
  });
}

// ---- Render: Metrics Column ----

function renderMetricsColumn(el, metrics, prevSet) {
  // Group by metric name for a compact view
  const byName = {};
  metrics.forEach(m => {
    const name = m.name || "unknown";
    if (!byName[name]) byName[name] = { type: m.metric_type, unit: m.unit, count: 0, values: [] };
    byName[name].count++;
    if (m.value != null) byName[name].values.push(Number(m.value));
    if (m.hist_count != null) byName[name].values.push(Number(m.hist_sum || 0));
  });

  let html = '<div class="mini-table">';
  for (const [name, info] of Object.entries(byName)) {
    const avg = info.values.length > 0 ? (info.values.reduce((a, b) => a + b, 0) / info.values.length).toFixed(1) : "-";
    // For metrics, key includes count so changed samples flash
    const mKey = `${name}|${info.count}`;
    const isNew = prevSet.size > 0 && !prevSet.has(mKey);
    html += `
      <div class="mini-row${isNew ? " new-row" : ""}">
        <div class="mini-row-main">
          <span class="mini-metric-name">${name}</span>
          <span class="mini-badge metrics">${info.type}</span>
        </div>
        <div class="mini-row-meta">
          <span class="mini-metric-val">${avg} ${info.unit || ""}</span>
          <span class="mini-metric-samples">${info.count} samples</span>
        </div>
      </div>
    `;
  }
  html += "</div>";
  el.innerHTML = html;

  el.querySelectorAll(".mini-row").forEach(row => {
    row.style.cursor = "pointer";
    row.addEventListener("click", () => {
      const name = row.querySelector(".mini-metric-name")?.textContent;
      const matched = metrics.filter(m => m.name === name);
      openDetailModal(`Metric: ${name}`, matched);
    });
  });
}

// ---- Trace Timeline Modal ----

const traceModal = document.getElementById("trace-modal");
const traceTitle = document.getElementById("trace-modal-title");
const traceTimeline = document.getElementById("trace-timeline");
const traceRaw = document.getElementById("trace-spans-raw");
document.getElementById("close-trace-modal").addEventListener("click", () => traceModal.classList.add("hidden"));
traceModal.addEventListener("click", e => { if (e.target === traceModal) traceModal.classList.add("hidden"); });

async function openTraceTimeline(traceId, collector) {
  traceTitle.textContent = `Trace: ${traceId}`;
  traceTimeline.innerHTML = '<div class="empty-state small">Loading...</div>';
  traceRaw.textContent = "";
  traceModal.classList.remove("hidden");
  try {
    const res = await fetch(`/api/trace/${collector}/${traceId}`);
    const data = await res.json();
    const spans = data.spans || [];
    if (!spans.length) { traceTimeline.innerHTML = '<div class="empty-state small">No spans</div>'; return; }
    renderTimeline(spans);
    traceRaw.textContent = JSON.stringify(spans, null, 2);
  } catch (err) {
    traceTimeline.innerHTML = `<div class="empty-state small error">${err.message}</div>`;
  }
}

function renderTimeline(spans) {
  // Build tree from parent_span_id
  const byId = {};
  const roots = [];
  spans.forEach(s => { byId[s.span_id] = { ...s, children: [] }; });
  spans.forEach(s => {
    const node = byId[s.span_id];
    if (s.parent_span_id && byId[s.parent_span_id]) {
      byId[s.parent_span_id].children.push(node);
    } else {
      roots.push(node);
    }
  });

  // Flatten tree in DFS order with depth
  const flat = [];
  function walk(node, depth) {
    flat.push({ ...node, depth });
    // Sort children by start time
    node.children.sort((a, b) => Number(BigInt(a.start_time_unix_nano || 0) - BigInt(b.start_time_unix_nano || 0)));
    node.children.forEach(c => walk(c, depth + 1));
  }
  roots.forEach(r => walk(r, 0));

  // Global time bounds
  let gStart = BigInt(flat[0].start_time_unix_nano || 0);
  let gEnd = BigInt(flat[0].end_time_unix_nano || 0);
  flat.forEach(s => {
    const st = BigInt(s.start_time_unix_nano || 0);
    const en = BigInt(s.end_time_unix_nano || 0);
    if (st < gStart) gStart = st;
    if (en > gEnd) gEnd = en;
  });
  const totalNs = Number(gEnd - gStart) || 1;
  const totalMs = (totalNs / 1_000_000).toFixed(1);

  // Time axis markers
  const markerCount = 5;
  let axisHtml = '<div class="timeline-axis">';
  for (let i = 0; i <= markerCount; i++) {
    const pct = (i / markerCount * 100).toFixed(1);
    const ms = (i / markerCount * totalNs / 1_000_000).toFixed(0);
    axisHtml += `<span class="axis-mark" style="left:${pct}%">${ms}ms</span>`;
  }
  axisHtml += '</div>';

  let html = `<div class="timeline-header">Total: ${totalMs}ms &middot; ${flat.length} spans</div>`;
  html += `<div class="timeline-axis-wrap">${axisHtml}</div>`;

  flat.forEach(s => {
    const st = Number(BigInt(s.start_time_unix_nano || 0) - gStart);
    const dur = Number(BigInt(s.end_time_unix_nano || 0) - BigInt(s.start_time_unix_nano || 0));
    const leftPct = (st / totalNs * 100).toFixed(2);
    const widthPct = Math.max(dur / totalNs * 100, 0.8).toFixed(2);
    const durMs = (dur / 1_000_000).toFixed(1);
    const indent = s.depth * 24;

    html += `<div class="timeline-row">
      <div class="timeline-label" style="padding-left:${indent}px">
        ${s.children && s.children.length > 0 ? '<span class="tree-icon">&#9662;</span>' : '<span class="tree-icon leaf">&#9676;</span>'}
        ${s.name || "span"}
      </div>
      <div class="timeline-bar-wrap">
        <div class="timeline-bar" style="left:${leftPct}%;width:${widthPct}%"></div>
      </div>
      <div class="timeline-dur">${durMs}ms</div>
    </div>`;
  });

  traceTimeline.innerHTML = html;
}

// ---- Detail Modal ----

const detailModal = document.getElementById("detail-modal");
const detailTitle = document.getElementById("detail-modal-title");
const detailContent = document.getElementById("detail-modal-content");
document.getElementById("close-detail-modal").addEventListener("click", () => detailModal.classList.add("hidden"));
detailModal.addEventListener("click", e => { if (e.target === detailModal) detailModal.classList.add("hidden"); });

function openDetailModal(title, data) {
  detailTitle.textContent = title;

  // If it's metric data (array with metric_type), render visually
  if (Array.isArray(data) && data.length > 0 && data[0].metric_type) {
    detailContent.innerHTML = renderMetricDetail(data);
  } else {
    detailContent.innerHTML = `<pre class="raw-json">${JSON.stringify(data, null, 2).replace(/</g, '&lt;')}</pre>`;
  }
  detailModal.classList.remove("hidden");
}

function renderMetricDetail(metrics) {
  const name = metrics[0].name || "unknown";
  const type = metrics[0].metric_type || "unknown";
  const unit = metrics[0].unit || "";
  const desc = metrics[0].description || "";

  let html = `<div class="metric-viz">`;
  html += `<div class="mv-header"><span class="mv-type">${type.toUpperCase()}</span> <span class="mv-unit">${unit ? `(${unit})` : ""}</span></div>`;
  if (desc) html += `<div class="mv-desc">${desc}</div>`;

  if (type === "histogram") {
    // Group by attributes (route) and show bars
    const byRoute = {};
    metrics.forEach(m => {
      let attrs = {};
      try { attrs = typeof m.attributes === "string" ? JSON.parse(m.attributes) : (m.attributes || {}); } catch {}
      const key = attrs.route || attrs.domain || "default";
      if (!byRoute[key]) byRoute[key] = { count: 0, sum: 0, min: Infinity, max: -Infinity, samples: [] };
      const g = byRoute[key];
      g.count += (m.hist_count || 0);
      g.sum += (m.hist_sum || 0);
      if (m.hist_min != null && m.hist_min < g.min) g.min = m.hist_min;
      if (m.hist_max != null && m.hist_max > g.max) g.max = m.hist_max;
      g.samples.push(m.hist_sum / (m.hist_count || 1));
    });

    const globalMax = Math.max(...Object.values(byRoute).map(g => g.max), 1);

    html += `<div class="mv-bars">`;
    for (const [route, g] of Object.entries(byRoute)) {
      const avg = g.count > 0 ? (g.sum / g.count).toFixed(1) : 0;
      const barPct = Math.max((g.max / globalMax) * 100, 2).toFixed(1);
      const minVal = g.min === Infinity ? 0 : g.min.toFixed(1);
      html += `
        <div class="mv-bar-row">
          <div class="mv-bar-label">${route}</div>
          <div class="mv-bar-track">
            <div class="mv-bar-fill" style="width:${barPct}%"></div>
          </div>
          <div class="mv-bar-stats">
            <span>avg <strong>${avg}</strong></span>
            <span>min <strong>${minVal}</strong></span>
            <span>max <strong>${g.max.toFixed(1)}</strong></span>
            <span>${g.count} samples</span>
          </div>
        </div>`;
    }
    html += `</div>`;
  } else {
    // Gauge or sum — show value list
    html += `<div class="mv-values">`;
    metrics.forEach(m => {
      const val = m.value != null ? Number(m.value).toFixed(1) : "—";
      let attrs = {};
      try { attrs = typeof m.attributes === "string" ? JSON.parse(m.attributes) : (m.attributes || {}); } catch {}
      const label = attrs.route || attrs.domain || attrs["service.name"] || "";
      html += `<div class="mv-val-row"><span class="mv-val-label">${label}</span><span class="mv-val-num">${val} ${unit}</span></div>`;
    });
    html += `</div>`;
  }

  // Show raw JSON in collapsible
  html += `<details class="mv-raw"><summary>Raw JSON</summary><pre>${JSON.stringify(metrics, null, 2)}</pre></details>`;
  html += `</div>`;
  return html;
}

// ---- Data Flow Modal ----

const dataflowModal = document.getElementById("dataflow-modal");
const btnDataflow = document.getElementById("btn-dataflow");
const closeDataflow = document.getElementById("close-dataflow");
const btnExpandAll = document.getElementById("btn-expand-all");
const dfStages = document.querySelectorAll(".df-stage");
let dfExpanded = false;

btnDataflow.addEventListener("click", () => { dataflowModal.classList.remove("hidden"); });
closeDataflow.addEventListener("click", () => { dataflowModal.classList.add("hidden"); });
dataflowModal.addEventListener("click", e => { if (e.target === dataflowModal) dataflowModal.classList.add("hidden"); });
btnExpandAll.addEventListener("click", () => {
  dfExpanded = !dfExpanded;
  dfStages.forEach(s => s.classList.toggle("expanded", dfExpanded));
  btnExpandAll.textContent = dfExpanded ? "Collapse" : "Expand";
});

// ---- Refresh ----

async function refreshAll() {
  await loadCounts();
  await loadAllSignals();
}

rangeSelect.addEventListener("change", e => { currentRange = e.target.value; refreshAll(); });
refreshBtn.addEventListener("click", refreshAll);

// ---- Boot ----

(async () => {
  await checkHealth();
  await loadCollectors();
  await refreshAll();
  setInterval(refreshAll, 5000);
})();
