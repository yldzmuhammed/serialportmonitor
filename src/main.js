const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const { SerialPort } = require('serialport');
const { startMcpServer } = require('./mcp-server');

const CAPTURE_MAX_ENTRIES = 5000;
const DEFAULT_MCP_PORT = parseInt(process.env.SERIAL_MCP_PORT || '8765', 10);

let mainWindow = null;
let activePort = null;
let activeConfig = null;
let mcpHttpServer = null;
let mcpInfo = { url: null, error: null };

// ---------- persisted settings ----------

function settingsPath() {
  return path.join(app.getPath('userData'), 'settings.json');
}

function loadSettings() {
  const defaults = { mcpEnabled: true, mcpPort: DEFAULT_MCP_PORT };
  try {
    return { ...defaults, ...JSON.parse(fs.readFileSync(settingsPath(), 'utf8')) };
  } catch {
    return defaults;
  }
}

let settings = null; // loaded once app is ready (needs userData path)

function saveSettings() {
  try {
    fs.writeFileSync(settingsPath(), JSON.stringify(settings, null, 2), 'utf8');
  } catch {
    // non-fatal: settings just won't persist
  }
}

// ---------- capture buffer ----------
// Shared by the UI log and the MCP read_data tool. The MCP side only ever
// reads this — observation never touches the port.

const captureBuffer = [];
let captureSeq = 0;
let rxTotal = 0;
let txTotal = 0;

const HEX_MAX_BYTES = 256;

function recordEntry(dir, buffer) {
  captureSeq += 1;
  const hexPart = buffer.subarray(0, HEX_MAX_BYTES);
  captureBuffer.push({
    seq: captureSeq,
    dir,
    ts: new Date().toISOString(),
    text: buffer.toString('utf8').replace(/\r?\n$/, ''),
    hex: hexPart.toString('hex').replace(/(..)/g, '$1 ').trim()
      + (buffer.length > HEX_MAX_BYTES ? ` … (+${buffer.length - HEX_MAX_BYTES} bytes)` : '')
  });
  if (captureBuffer.length > CAPTURE_MAX_ENTRIES) {
    captureBuffer.splice(0, captureBuffer.length - CAPTURE_MAX_ENTRIES);
  }
}

// RX line assembly: serial data arrives in arbitrary USB-sized fragments, so
// chunks are glued together and recorded one complete line per entry. A flush
// timer catches non-line-based protocols and trailing partial lines.
const RX_FLUSH_MS = 300;
const RX_ASSEMBLY_MAX = 4096;
let rxAssembly = Buffer.alloc(0);
let rxFlushTimer = null;

function flushRxAssembly() {
  if (rxFlushTimer) { clearTimeout(rxFlushTimer); rxFlushTimer = null; }
  if (rxAssembly.length) {
    recordEntry('rx', rxAssembly);
    rxAssembly = Buffer.alloc(0);
  }
}

function captureRx(data) {
  rxAssembly = rxAssembly.length ? Buffer.concat([rxAssembly, data]) : data;

  let idx;
  while ((idx = rxAssembly.indexOf(0x0a)) !== -1) {
    recordEntry('rx', rxAssembly.subarray(0, idx + 1));
    rxAssembly = rxAssembly.subarray(idx + 1);
  }

  if (rxAssembly.length >= RX_ASSEMBLY_MAX) flushRxAssembly();

  if (rxFlushTimer) clearTimeout(rxFlushTimer);
  rxFlushTimer = rxAssembly.length ? setTimeout(flushRxAssembly, RX_FLUSH_MS) : null;
}

// ---------- window ----------

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 750,
    minWidth: 800,
    minHeight: 500,
    title: 'Serial Port Monitor',
    backgroundColor: '#1e1e2e',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  mainWindow.on('closed', () => { mainWindow = null; });
}

// ---------- serial port ----------

function closeActivePort() {
  flushRxAssembly();
  return new Promise((resolve) => {
    if (activePort && activePort.isOpen) {
      activePort.close(() => { activePort = null; activeConfig = null; resolve(); });
    } else {
      activePort = null;
      activeConfig = null;
      resolve();
    }
  });
}

async function listPorts() {
  const ports = await SerialPort.list();
  return ports.map((p) => ({
    path: p.path,
    manufacturer: p.manufacturer || '',
    serialNumber: p.serialNumber || '',
    vendorId: p.vendorId || '',
    productId: p.productId || ''
  }));
}

async function openPort(options) {
  await closeActivePort();

  return new Promise((resolve) => {
    const port = new SerialPort(
      {
        path: options.path,
        baudRate: options.baudRate,
        dataBits: options.dataBits,
        parity: options.parity,
        stopBits: options.stopBits,
        rtscts: options.flowControl === 'rtscts',
        xon: options.flowControl === 'xonxoff',
        xoff: options.flowControl === 'xonxoff',
        autoOpen: false
      }
    );

    port.open((err) => {
      if (err) {
        resolve({ ok: false, error: err.message });
        return;
      }

      activePort = port;
      activeConfig = { ...options };
      rxTotal = 0;
      txTotal = 0;
      rxAssembly = Buffer.alloc(0);

      port.on('data', (data) => {
        rxTotal += data.length;
        captureRx(data);
        if (mainWindow) mainWindow.webContents.send('serial:data', data);
      });

      port.on('error', (portErr) => {
        if (mainWindow) mainWindow.webContents.send('serial:error', portErr.message);
      });

      port.on('close', () => {
        if (activePort === port) { activePort = null; activeConfig = null; }
        if (mainWindow) mainWindow.webContents.send('serial:closed');
      });

      resolve({ ok: true });
    });
  });
}

function buildWriteBuffer(payload) {
  if (payload.hex) {
    const cleaned = payload.data.replace(/[^0-9a-fA-F]/g, '');
    if (cleaned.length === 0 || cleaned.length % 2 !== 0) {
      return { error: 'Invalid hex string (need an even number of hex digits)' };
    }
    return { buffer: Buffer.from(cleaned, 'hex') };
  }
  return { buffer: Buffer.from(payload.data + (payload.lineEnding || ''), 'utf8') };
}

function doWrite(payload) {
  if (!activePort || !activePort.isOpen) {
    return Promise.resolve({ ok: false, error: 'Port is not open' });
  }

  const { buffer, error } = buildWriteBuffer(payload);
  if (error) return Promise.resolve({ ok: false, error });

  return new Promise((resolve) => {
    activePort.write(buffer, (err) => {
      if (err) {
        resolve({ ok: false, error: err.message });
      } else {
        activePort.drain(() => {
          txTotal += buffer.length;
          recordEntry('tx', buffer);
          resolve({ ok: true, bytes: buffer.length });
        });
      }
    });
  });
}

// ---------- MCP server lifecycle ----------

async function applyMcpConfig() {
  if (mcpHttpServer) {
    mcpHttpServer.close();
    if (mcpHttpServer.closeAllConnections) mcpHttpServer.closeAllConnections();
    mcpHttpServer = null;
  }

  if (!settings.mcpEnabled) {
    mcpInfo = { url: null, error: null };
    return;
  }

  const started = await startMcpServer(mcpApi, settings.mcpPort);
  if (started.server) {
    mcpHttpServer = started.server;
    mcpInfo = { url: started.url, error: null };
  } else {
    mcpInfo = { url: null, error: started.error };
  }
}

function mcpStatus() {
  return {
    enabled: settings.mcpEnabled,
    port: settings.mcpPort,
    url: mcpInfo.url,
    error: mcpInfo.error
  };
}

// ---------- IPC ----------

ipcMain.handle('serial:list', () => listPorts());
ipcMain.handle('serial:open', (_event, options) => openPort(options));

// Lets a freshly (re)loaded renderer recover the live connection state,
// e.g. after a hot reload in dev mode.
ipcMain.handle('serial:status', () => ({
  connected: !!(activePort && activePort.isOpen),
  config: activeConfig
}));

ipcMain.handle('serial:close', async () => {
  await closeActivePort();
  return { ok: true };
});

ipcMain.handle('serial:write', (_event, payload) => doWrite(payload));

ipcMain.handle('serial:setSignals', async (_event, signals) => {
  if (!activePort || !activePort.isOpen) {
    return { ok: false, error: 'Port is not open' };
  }
  return new Promise((resolve) => {
    activePort.set(signals, (err) => {
      resolve(err ? { ok: false, error: err.message } : { ok: true });
    });
  });
});

ipcMain.handle('mcp:info', () => mcpStatus());

ipcMain.handle('mcp:configure', async (_event, config) => {
  const port = parseInt(config.port, 10);
  if (config.enabled && (!port || port < 1 || port > 65535)) {
    return { ...mcpStatus(), error: 'Invalid port number' };
  }
  settings.mcpEnabled = !!config.enabled;
  if (port) settings.mcpPort = port;
  saveSettings();
  await applyMcpConfig();
  return mcpStatus();
});

ipcMain.handle('log:save', async (_event, content) => {
  if (!mainWindow) return { ok: false, error: 'No window' };
  const stamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19);
  const { canceled, filePath } = await dialog.showSaveDialog(mainWindow, {
    title: 'Save session log',
    defaultPath: `serial-log-${stamp}.txt`,
    filters: [{ name: 'Text files', extensions: ['txt', 'log'] }]
  });
  if (canceled || !filePath) return { ok: false, canceled: true };
  try {
    fs.writeFileSync(filePath, content, 'utf8');
    return { ok: true, filePath };
  } catch (err) {
    return { ok: false, error: err.message };
  }
});

// ---------- MCP server API ----------

const mcpApi = {
  listPorts,

  getStatus() {
    return {
      connected: !!(activePort && activePort.isOpen),
      port: activeConfig ? activeConfig.path : null,
      settings: activeConfig
        ? {
            baudRate: activeConfig.baudRate,
            dataBits: activeConfig.dataBits,
            parity: activeConfig.parity,
            stopBits: activeConfig.stopBits,
            flowControl: activeConfig.flowControl
          }
        : null,
      rxBytes: rxTotal,
      txBytes: txTotal,
      buffer: {
        entries: captureBuffer.length,
        oldest_seq: captureBuffer.length ? captureBuffer[0].seq : null,
        latest_seq: captureBuffer.length ? captureBuffer[captureBuffer.length - 1].seq : null
      }
    };
  },

  readData({ since_seq = 0, max_entries = 200, direction = 'both' } = {}) {
    let entries = captureBuffer.filter((e) => e.seq > since_seq);
    if (direction !== 'both') entries = entries.filter((e) => e.dir === direction);

    const truncated = entries.length > max_entries;
    if (truncated) entries = entries.slice(entries.length - max_entries);

    return {
      latest_seq: captureSeq,
      truncated,
      note: captureBuffer.length && since_seq > 0 && since_seq < captureBuffer[0].seq - 1
        ? 'Some entries older than the buffer window were dropped'
        : undefined,
      entries
    };
  },

  async openPort(args) {
    const options = {
      path: args.path,
      baudRate: args.baud_rate || 115200,
      dataBits: args.data_bits || 8,
      parity: args.parity || 'none',
      stopBits: args.stop_bits || 1,
      flowControl: args.flow_control || 'none'
    };
    const result = await openPort(options);
    if (result.ok && mainWindow) {
      mainWindow.webContents.send('serial:opened', options);
    }
    return result.ok ? { ok: true, opened: options } : result;
  },

  async closePort() {
    const wasOpen = !!(activePort && activePort.isOpen);
    await closeActivePort();
    if (wasOpen && mainWindow) mainWindow.webContents.send('serial:closed');
    return { ok: true, was_open: wasOpen };
  },

  async sendData(args) {
    const lineEndings = { none: '', lf: '\n', cr: '\r', crlf: '\r\n' };
    const result = await doWrite({
      data: args.data,
      hex: !!args.hex,
      lineEnding: lineEndings[args.line_ending || 'none']
    });

    if (result.ok && mainWindow) {
      mainWindow.webContents.send('serial:agent-tx', {
        data: args.data,
        hex: !!args.hex,
        bytes: result.bytes
      });
    }
    return result;
  }
};

// ---------- app lifecycle ----------

app.whenReady().then(async () => {
  settings = loadSettings();
  createWindow();
  await applyMcpConfig();

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow();
  });
});

app.on('window-all-closed', () => {
  closeActivePort().then(() => {
    if (process.platform !== 'darwin') app.quit();
  });
});

app.on('before-quit', () => {
  closeActivePort();
});
