/**
 * OTel Ops — Telemetry Observer
 * Shows all collectors and all signals at once. No clicking required.
 */

let collectors = {};
let currentRange = "all";

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
    healthPill.style.color = data.status === "ok" ? "#9cf6b5" : "#ff8ca9";
  } catch (_) {
    healthPill.textContent = "Offline";
    healthPill.style.color = "#ff8ca9";
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
  for (const [cid, c] of Object.entries(collectors)) {
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
}

// ---- Load All Sections ----

async function loadAllSignals() {
  const signals = ["traces", "logs", "metrics"];
  for (const signal of signals) {
    const sectionEl = document.getElementById(`${signal}-section`);
    if (!sectionEl) continue;
    sectionEl.innerHTML = "";

    // Find all collectors that have this signal
    const capable = Object.entries(collectors).filter(([_, c]) => c.signals.includes(signal));
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

      // Fetch data
      fetchSignalData(signal, cid, c);
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
    if (signal === "traces") renderTracesColumn(contentEl, items, cid);
    else if (signal === "logs") renderLogsColumn(contentEl, items);
    else if (signal === "metrics") renderMetricsColumn(contentEl, items);
  } catch (err) {
    contentEl.innerHTML = `<div class="empty-state small error">${err.message}</div>`;
  }
}

// ---- Render: Traces Column ----

function renderTracesColumn(el, traces, collector) {
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
    html += `
      <div class="mini-row clickable" data-trace-id="${tid}" data-collector="${collector}">
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

function renderLogsColumn(el, logs) {
  let html = '<div class="mini-table">';
  logs.forEach((log, i) => {
    const sevClass = (log.severity_text || "").toLowerCase().includes("error") ? "critical"
      : (log.severity_text || "").toLowerCase().includes("warn") ? "warn" : "normal";
    const body = (log.body || "").slice(0, 80);
    html += `
      <div class="mini-row" data-idx="${i}">
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

function renderMetricsColumn(el, metrics) {
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
    html += `
      <div class="mini-row">
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
  detailContent.textContent = JSON.stringify(data, null, 2);
  detailModal.classList.remove("hidden");
}

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
  setInterval(loadCounts, 15000);
})();
