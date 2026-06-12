const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('serialAPI', {
  listPorts: () => ipcRenderer.invoke('serial:list'),
  open: (options) => ipcRenderer.invoke('serial:open', options),
  close: () => ipcRenderer.invoke('serial:close'),
  write: (payload) => ipcRenderer.invoke('serial:write', payload),
  setSignals: (signals) => ipcRenderer.invoke('serial:setSignals', signals),
  saveLog: (content) => ipcRenderer.invoke('log:save', content),
  getMcpInfo: () => ipcRenderer.invoke('mcp:info'),
  configureMcp: (config) => ipcRenderer.invoke('mcp:configure', config),

  onData: (callback) => {
    ipcRenderer.on('serial:data', (_event, data) => callback(new Uint8Array(data)));
  },
  onError: (callback) => {
    ipcRenderer.on('serial:error', (_event, message) => callback(message));
  },
  onClosed: (callback) => {
    ipcRenderer.on('serial:closed', () => callback());
  },
  onAgentTx: (callback) => {
    ipcRenderer.on('serial:agent-tx', (_event, info) => callback(info));
  },
  onOpened: (callback) => {
    ipcRenderer.on('serial:opened', (_event, options) => callback(options));
  }
});
