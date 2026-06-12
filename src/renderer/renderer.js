/* global serialAPI */

const els = {
  portSelect: document.getElementById('portSelect'),
  refreshBtn: document.getElementById('refreshBtn'),
  baudSelect: document.getElementById('baudSelect'),
  customBaud: document.getElementById('customBaud'),
  dataBits: document.getElementById('dataBitsSelect'),
  parity: document.getElementById('paritySelect'),
  stopBits: document.getElementById('stopBitsSelect'),
  flow: document.getElementById('flowSelect'),
  connectBtn: document.getElementById('connectBtn'),
  rxLineEnding: document.getElementById('rxLineEndingSelect'),
  viewAscii: document.getElementById('viewAscii'),
  viewHex: document.getElementById('viewHex'),
  viewBoth: document.getElementById('viewBoth'),
  timestamps: document.getElementById('timestampsChk'),
  autoscroll: document.getElementById('autoscrollChk'),
  showTx: document.getElementById('showTxChk'),
  rxCounter: document.getElementById('rxCounter'),
  txCounter: document.getElementById('txCounter'),
  saveLogBtn: document.getElementById('saveLogBtn'),
  clearBtn: document.getElementById('clearBtn'),
  output: document.getElementById('output'),
  lineEnding: document.getElementById('lineEndingSelect'),
  sendInput: document.getElementById('sendInput'),
  sendHex: document.getElementById('sendHexChk'),
  sendBtn: document.getElementById('sendBtn'),
  statusDot: document.getElementById('statusDot'),
  statusText: document.getElementById('statusText'),
  mcpInfo: document.getElementById('mcpInfo'),
  mcpToggleBtn: document.getElementById('mcpToggleBtn'),
  mcpBar: document.getElementById('mcpBar'),
  mcpEnabled: document.getElementById('mcpEnabledChk'),
  mcpPort: document.getElementById('mcpPortInput'),
  mcpApplyBtn: document.getElementById('mcpApplyBtn'),
  mcpStatusText: document.getElementById('mcpStatusText'),
  mcpCopyBtn: document.getElementById('mcpCopyBtn')
};

const MAX_LINES = 5000;
const LINE_ENDINGS = { '\\n': '\n', '\\r': '\r', '\\r\\n': '\r\n', '': '' };

let connected = false;
let viewMode = 'ascii'; // ascii | hex | both
let rxBytes = 0;
let txBytes = 0;
let rxLineBuffer = ''; // accumulates partial ASCII lines
let rxLineEl = null;   // current open RX line element
let heldCR = '';       // trailing \r held back until the next chunk decides if it pairs with \n
let rxLineEndingMode = 'auto'; // auto | lf | cr | crlf

const RX_SPLITTERS = { auto: /\r\n|\n|\r/, lf: /\n/, cr: /\r/, crlf: /\r\n/ };
let sendHistory = [];
let historyIndex = -1;
const logEntries = []; // { time, dir, text }

// ---------- helpers ----------

function timestamp() {
  const d = new Date();
  const pad = (n, w = 2) => String(n).padStart(w, '0');
  return `${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}.${pad(d.getMilliseconds(), 3)}`;
}

function toHex(bytes) {
  return Array.from(bytes, (b) => b.toString(16).padStart(2, '0').toUpperCase()).join(' ');
}

function toPrintable(text) {
  // Show control chars as dots (tab stays; line endings are already consumed
  // by the splitter, so any CR/LF still here is a stray worth seeing)
  return text.replace(/[\x00-\x08\x0a-\x1f\x7f]/g, '·');
}

function formatBytes(n) {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / (1024 * 1024)).toFixed(2)} MB`;
}

function trimOutput() {
  while (els.output.childElementCount > MAX_LINES) {
    els.output.removeChild(els.output.firstChild);
  }
}

function scrollToBottom() {
  if (els.autoscroll.checked) {
    els.output.scrollTop = els.output.scrollHeight;
  }
}

function makeLine(cls, dir, payloadText, hexText) {
  const line = document.createElement('span');
  line.className = `line ${cls}`;

  if (els.timestamps.checked) {
    const ts = document.createElement('span');
    ts.className = 'ts';
    ts.textContent = timestamp();
    line.appendChild(ts);
  }

  if (dir) {
    const dirEl = document.createElement('span');
    dirEl.className = 'dir';
    dirEl.textContent = dir;
    line.appendChild(dirEl);
  }

  const payload = document.createElement('span');
  payload.className = 'payload';
  payload.textContent = payloadText;
  line.appendChild(payload);

  if (hexText) {
    const hex = document.createElement('span');
    hex.className = 'hex';
    hex.textContent = `  [${hexText}]`;
    line.appendChild(hex);
  }

  line.appendChild(document.createTextNode('\n'));
  return line;
}

function appendSystem(text) {
  rxLineEl = null;
  els.output.appendChild(makeLine('sys', '--', text));
  logEntries.push({ time: timestamp(), dir: 'SYS', text });
  trimOutput();
  scrollToBottom();
}

function appendTx(text, hexText, agent = false) {
  rxLineEl = null;
  if (els.showTx.checked) {
    els.output.appendChild(makeLine(agent ? 'tx agent' : 'tx', agent ? 'AI>' : 'TX>', text, hexText));
    trimOutput();
    scrollToBottom();
  }
  logEntries.push({
    time: timestamp(),
    dir: agent ? 'TX(AI)' : 'TX',
    text: hexText ? `${text} [${hexText}]` : text
  });
}

// ---------- RX rendering ----------

function appendRxChunk(bytes) {
  rxBytes += bytes.length;
  els.rxCounter.textContent = `RX ${formatBytes(rxBytes)}`;

  const text = new TextDecoder('utf-8', { fatal: false }).decode(bytes);
  logEntries.push({ time: timestamp(), dir: 'RX', text: viewMode === 'hex' ? toHex(bytes) : toPrintable(text).replace(/\n/g, '\\n').replace(/\r/g, '\\r') });

  if (viewMode === 'hex') {
    rxLineEl = null;
    els.output.appendChild(makeLine('rx', 'RX<', toHex(bytes)));
    trimOutput();
    scrollToBottom();
    return;
  }

  if (viewMode === 'both') {
    rxLineEl = null;
    const printable = toPrintable(text.replace(/\r/g, '')).replace(/\n/g, '↵');
    els.output.appendChild(makeLine('rx', 'RX<', printable, toHex(bytes)));
    trimOutput();
    scrollToBottom();
    return;
  }

  // ASCII mode: split into lines, keep partial line open so chunks join naturally.
  // A CRLF pair can be split across two chunks — hold a trailing \r back until
  // the next chunk shows whether it pairs with \n, so no empty line appears.
  let chunk = text;
  if (rxLineEndingMode === 'auto' || rxLineEndingMode === 'crlf') {
    chunk = heldCR + chunk;
    heldCR = '';
    if (chunk.endsWith('\r')) {
      heldCR = '\r';
      chunk = chunk.slice(0, -1);
    }
  }
  if (chunk.length === 0) return;

  rxLineBuffer += chunk;
  const parts = rxLineBuffer.split(RX_SPLITTERS[rxLineEndingMode]);
  rxLineBuffer = parts.pop(); // last part is incomplete (or empty if chunk ended with newline)

  for (const part of parts) {
    if (rxLineEl) {
      rxLineEl.querySelector('.payload').textContent += toPrintable(part);
      rxLineEl = null;
    } else {
      els.output.appendChild(makeLine('rx', 'RX<', toPrintable(part)));
    }
  }

  if (rxLineBuffer.length > 0) {
    if (rxLineEl) {
      rxLineEl.querySelector('.payload').textContent += toPrintable(rxLineBuffer);
    } else {
      rxLineEl = makeLine('rx', 'RX<', toPrintable(rxLineBuffer));
      els.output.appendChild(rxLineEl);
    }
    rxLineBuffer = '';
  }

  trimOutput();
  scrollToBottom();
}

// ---------- port management ----------

async function refreshPorts() {
  const current = els.portSelect.value;
  const ports = await serialAPI.listPorts();
  els.portSelect.innerHTML = '';

  if (ports.length === 0) {
    const opt = document.createElement('option');
    opt.value = '';
    opt.textContent = 'No ports found';
    els.portSelect.appendChild(opt);
    return;
  }

  for (const p of ports) {
    const opt = document.createElement('option');
    opt.value = p.path;
    opt.textContent = p.manufacturer ? `${p.path} — ${p.manufacturer}` : p.path;
    els.portSelect.appendChild(opt);
  }

  if (current && ports.some((p) => p.path === current)) {
    els.portSelect.value = current;
  }
}

function getBaudRate() {
  if (els.baudSelect.value === 'custom') {
    return parseInt(els.customBaud.value, 10) || 0;
  }
  return parseInt(els.baudSelect.value, 10);
}

function setConnectedState(state) {
  connected = state;
  els.connectBtn.textContent = state ? 'Disconnect' : 'Connect';
  els.connectBtn.classList.toggle('connected', state);
  els.statusDot.className = `dot ${state ? 'online' : 'offline'}`;
  els.sendInput.disabled = !state;
  els.sendBtn.disabled = !state;

  const configEls = [els.portSelect, els.refreshBtn, els.baudSelect, els.customBaud,
    els.dataBits, els.parity, els.stopBits, els.flow];
  configEls.forEach((el) => { el.disabled = state; });

  if (state) {
    const baud = getBaudRate();
    els.statusText.textContent =
      `Connected — ${els.portSelect.value} @ ${baud} baud, ` +
      `${els.dataBits.value}${els.parity.value[0].toUpperCase()}${els.stopBits.value}`;
  } else {
    els.statusText.textContent = 'Disconnected';
  }
}

async function connect() {
  const portPath = els.portSelect.value;
  if (!portPath) {
    appendSystem('No port selected');
    return;
  }

  const baudRate = getBaudRate();
  if (!baudRate || baudRate < 1) {
    appendSystem('Invalid baud rate');
    return;
  }

  const result = await serialAPI.open({
    path: portPath,
    baudRate,
    dataBits: parseInt(els.dataBits.value, 10),
    parity: els.parity.value,
    stopBits: parseFloat(els.stopBits.value),
    flowControl: els.flow.value
  });

  if (result.ok) {
    setConnectedState(true);
    appendSystem(`Opened ${portPath} @ ${baudRate} baud`);
  } else {
    appendSystem(`Failed to open ${portPath}: ${result.error}`);
  }
}

async function disconnect() {
  await serialAPI.close();
  // 'serial:closed' event finalizes UI state
}

// ---------- sending ----------

async function send() {
  const raw = els.sendInput.value;
  if (raw.length === 0) return;

  const isHex = els.sendHex.checked;
  const lineEnding = isHex ? '' : (LINE_ENDINGS[els.lineEnding.value] ?? '\n');

  const result = await serialAPI.write({ data: raw, hex: isHex, lineEnding });

  if (result.ok) {
    txBytes += result.bytes;
    els.txCounter.textContent = `TX ${formatBytes(txBytes)}`;
    if (isHex) {
      const cleaned = raw.replace(/[^0-9a-fA-F]/g, '');
      const pretty = cleaned.match(/.{2}/g).join(' ').toUpperCase();
      appendTx(`${result.bytes} bytes`, pretty);
    } else {
      appendTx(raw);
    }
    if (sendHistory[sendHistory.length - 1] !== raw) sendHistory.push(raw);
    if (sendHistory.length > 100) sendHistory.shift();
    historyIndex = sendHistory.length;
    els.sendInput.value = '';
  } else {
    appendSystem(`Send failed: ${result.error}`);
  }
}

// ---------- view modes ----------

function setViewMode(mode) {
  viewMode = mode;
  rxLineEl = null;
  rxLineBuffer = '';
  heldCR = '';
  els.viewAscii.classList.toggle('active', mode === 'ascii');
  els.viewHex.classList.toggle('active', mode === 'hex');
  els.viewBoth.classList.toggle('active', mode === 'both');
}

// ---------- wire up ----------

els.refreshBtn.addEventListener('click', refreshPorts);

els.baudSelect.addEventListener('change', () => {
  els.customBaud.classList.toggle('hidden', els.baudSelect.value !== 'custom');
  if (els.baudSelect.value === 'custom') els.customBaud.focus();
});

els.connectBtn.addEventListener('click', () => (connected ? disconnect() : connect()));

els.rxLineEnding.addEventListener('change', async () => {
  rxLineEndingMode = els.rxLineEnding.value;
  rxLineEl = null;
  rxLineBuffer = '';
  heldCR = '';
  await serialAPI.setRxLineEnding(rxLineEndingMode);
});

els.viewAscii.addEventListener('click', () => setViewMode('ascii'));
els.viewHex.addEventListener('click', () => setViewMode('hex'));
els.viewBoth.addEventListener('click', () => setViewMode('both'));

els.clearBtn.addEventListener('click', () => {
  els.output.innerHTML = '';
  rxLineEl = null;
  rxLineBuffer = '';
  heldCR = '';
});

els.saveLogBtn.addEventListener('click', async () => {
  if (logEntries.length === 0) {
    appendSystem('Nothing to save yet');
    return;
  }
  const content = logEntries.map((e) => `[${e.time}] ${e.dir} ${e.text}`).join('\n') + '\n';
  const result = await serialAPI.saveLog(content);
  if (result.ok) appendSystem(`Log saved to ${result.filePath}`);
  else if (!result.canceled) appendSystem(`Save failed: ${result.error}`);
});

els.sendBtn.addEventListener('click', send);

els.sendInput.addEventListener('keydown', (e) => {
  if (e.key === 'Enter') {
    send();
  } else if (e.key === 'ArrowUp') {
    e.preventDefault();
    if (sendHistory.length > 0 && historyIndex > 0) {
      historyIndex -= 1;
      els.sendInput.value = sendHistory[historyIndex];
    }
  } else if (e.key === 'ArrowDown') {
    e.preventDefault();
    if (historyIndex < sendHistory.length - 1) {
      historyIndex += 1;
      els.sendInput.value = sendHistory[historyIndex];
    } else {
      historyIndex = sendHistory.length;
      els.sendInput.value = '';
    }
  }
});

serialAPI.onData((bytes) => appendRxChunk(bytes));

serialAPI.onError((message) => appendSystem(`Port error: ${message}`));

serialAPI.onClosed(() => {
  if (connected) {
    setConnectedState(false);
    appendSystem('Port closed');
  }
});

serialAPI.onAgentTx((info) => {
  txBytes += info.bytes;
  els.txCounter.textContent = `TX ${formatBytes(txBytes)}`;
  if (info.hex) {
    const cleaned = info.data.replace(/[^0-9a-fA-F]/g, '');
    const pretty = (cleaned.match(/.{2}/g) || []).join(' ').toUpperCase();
    appendTx(`${info.bytes} bytes`, pretty, true);
  } else {
    appendTx(info.data, null, true);
  }
});

function syncUiToConfig(options) {
  if (![...els.portSelect.options].some((o) => o.value === options.path)) {
    const opt = document.createElement('option');
    opt.value = options.path;
    opt.textContent = options.path;
    els.portSelect.appendChild(opt);
  }
  els.portSelect.value = options.path;

  const baudStr = String(options.baudRate);
  if ([...els.baudSelect.options].some((o) => o.value === baudStr)) {
    els.baudSelect.value = baudStr;
    els.customBaud.classList.add('hidden');
  } else {
    els.baudSelect.value = 'custom';
    els.customBaud.value = baudStr;
    els.customBaud.classList.remove('hidden');
  }

  els.dataBits.value = String(options.dataBits);
  els.parity.value = options.parity;
  els.stopBits.value = String(options.stopBits);
  els.flow.value = options.flowControl;

  setConnectedState(true);
}

serialAPI.onOpened((options) => {
  syncUiToConfig(options);
  appendSystem(`Port opened by agent: ${options.path} @ ${options.baudRate} baud`);
});

// ---------- MCP server config ----------

function renderMcpStatus(info) {
  if (info.url) {
    els.mcpInfo.textContent = `MCP ${info.url}`;
    els.mcpInfo.classList.add('on');
    els.mcpStatusText.textContent = `Running at ${info.url}`;
    els.mcpStatusText.className = 'mcp-status ok';
  } else if (info.enabled && info.error) {
    els.mcpInfo.textContent = 'MCP error';
    els.mcpInfo.classList.remove('on');
    els.mcpStatusText.textContent = `Failed to start: ${info.error}`;
    els.mcpStatusText.className = 'mcp-status err';
  } else {
    els.mcpInfo.textContent = 'MCP off';
    els.mcpInfo.classList.remove('on');
    els.mcpStatusText.textContent = 'Server disabled';
    els.mcpStatusText.className = 'mcp-status';
  }
  els.mcpEnabled.checked = !!info.enabled;
  if (document.activeElement !== els.mcpPort) els.mcpPort.value = info.port;
  els.mcpCopyBtn.disabled = !info.url;
}

async function showMcpInfo() {
  renderMcpStatus(await serialAPI.getMcpInfo());
}

els.mcpToggleBtn.addEventListener('click', () => {
  els.mcpBar.classList.toggle('hidden');
  if (!els.mcpBar.classList.contains('hidden')) showMcpInfo();
});

els.mcpApplyBtn.addEventListener('click', async () => {
  const info = await serialAPI.configureMcp({
    enabled: els.mcpEnabled.checked,
    port: parseInt(els.mcpPort.value, 10)
  });
  renderMcpStatus(info);
  appendSystem(info.url
    ? `MCP server running at ${info.url}`
    : info.error
      ? `MCP server error: ${info.error}`
      : 'MCP server stopped');
});

els.mcpCopyBtn.addEventListener('click', async () => {
  const info = await serialAPI.getMcpInfo();
  if (!info.url) return;
  await navigator.clipboard.writeText(
    `claude mcp add --transport http serial-monitor ${info.url}`
  );
  els.mcpCopyBtn.textContent = 'Copied!';
  setTimeout(() => { els.mcpCopyBtn.textContent = 'Copy connect command'; }, 1500);
});

// initial load
(async () => {
  await refreshPorts();
  // recover live connection state after a renderer (hot) reload
  const status = await serialAPI.getStatus();
  if (status.rxLineEnding) {
    rxLineEndingMode = status.rxLineEnding;
    els.rxLineEnding.value = status.rxLineEnding;
  }
  if (status.connected && status.config) {
    syncUiToConfig(status.config);
    appendSystem(`Reconnected to live session: ${status.config.path} @ ${status.config.baudRate} baud`);
  }
})();
showMcpInfo();
setTimeout(showMcpInfo, 1500); // MCP server starts async alongside the window
setInterval(() => { if (!connected) refreshPorts(); }, 3000);
