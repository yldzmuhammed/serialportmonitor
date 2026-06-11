const { app, BrowserWindow, ipcMain, dialog } = require('electron');
const path = require('path');
const fs = require('fs');
const { SerialPort } = require('serialport');

let mainWindow = null;
let activePort = null;

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

function closeActivePort() {
  return new Promise((resolve) => {
    if (activePort && activePort.isOpen) {
      activePort.close(() => { activePort = null; resolve(); });
    } else {
      activePort = null;
      resolve();
    }
  });
}

ipcMain.handle('serial:list', async () => {
  const ports = await SerialPort.list();
  return ports.map((p) => ({
    path: p.path,
    manufacturer: p.manufacturer || '',
    serialNumber: p.serialNumber || '',
    vendorId: p.vendorId || '',
    productId: p.productId || ''
  }));
});

ipcMain.handle('serial:open', async (_event, options) => {
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

      port.on('data', (data) => {
        if (mainWindow) mainWindow.webContents.send('serial:data', data);
      });

      port.on('error', (portErr) => {
        if (mainWindow) mainWindow.webContents.send('serial:error', portErr.message);
      });

      port.on('close', () => {
        if (activePort === port) activePort = null;
        if (mainWindow) mainWindow.webContents.send('serial:closed');
      });

      resolve({ ok: true });
    });
  });
});

ipcMain.handle('serial:close', async () => {
  await closeActivePort();
  return { ok: true };
});

ipcMain.handle('serial:write', async (_event, payload) => {
  if (!activePort || !activePort.isOpen) {
    return { ok: false, error: 'Port is not open' };
  }

  let buffer;
  if (payload.hex) {
    const cleaned = payload.data.replace(/[^0-9a-fA-F]/g, '');
    if (cleaned.length === 0 || cleaned.length % 2 !== 0) {
      return { ok: false, error: 'Invalid hex string (need an even number of hex digits)' };
    }
    buffer = Buffer.from(cleaned, 'hex');
  } else {
    buffer = Buffer.from(payload.data + payload.lineEnding, 'utf8');
  }

  return new Promise((resolve) => {
    activePort.write(buffer, (err) => {
      if (err) {
        resolve({ ok: false, error: err.message });
      } else {
        activePort.drain(() => resolve({ ok: true, bytes: buffer.length }));
      }
    });
  });
});

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

app.whenReady().then(() => {
  createWindow();
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
