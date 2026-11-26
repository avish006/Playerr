const { contextBridge, ipcRenderer } = require('electron');
contextBridge.exposeInMainWorld('api', {
  onState: f => ipcRenderer.on('state', (_, s) => f(s)),
  onLayout: f => ipcRenderer.on('layout', (_, l) => f(l)),
  onLockState: f => ipcRenderer.on('lock-state', (_, locked) => f(locked)),
  onBtState: f => ipcRenderer.on('bt-state', (_, s) => f(s)),
  onBtTheme: f => ipcRenderer.on('bt-theme', (_, t) => f(t)),
  cmd: c => ipcRenderer.send('cmd', c),
  btCmd: c => ipcRenderer.send('bt-cmd', c),
  btToggle: accent => ipcRenderer.send('bt-toggle', accent),
  btOpenSettings: () => ipcRenderer.send('bt-open-settings'),
  btClose: () => ipcRenderer.send('bt-close'),
  drag: mode => ipcRenderer.send('drag', mode),   // 'move' | 'resize' | 'end'
  wheel: dy => ipcRenderer.send('wheel', dy),
  onPrepareMini: f => ipcRenderer.on('prepare-mini', (_, state) => f(state)),
  miniReady: revision => ipcRenderer.send('mini-ready', revision),
  toggleMini: () => ipcRenderer.send('toggle-mini'),
  toggleLock: () => ipcRenderer.send('toggle-lock'),
  menu: () => ipcRenderer.send('menu'),
});
