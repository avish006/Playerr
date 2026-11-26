const { app, BrowserWindow, Tray, Menu, screen, ipcMain, globalShortcut, nativeImage, shell } = require('electron');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

// Design size (px at scale 1). The whole UI scales with the window.
const DESIGN = { full: { w: 400, h: 184 }, mini: { w: 160, h: 160 } };
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));
let cfg = { scale: 1, mini: false, opacity: 1, x: null, y: null };
let win, lockWin, btWin, tray, helper, btHelper, drag, quitting = false;
let locked = true;
let lastMediaState = null;
let lastBtState = null;
let lastAccent = '#1ed760';
let btPollTimer = null;
let btClosedAt = 0;
let pendingMini = null, miniRevision = 0;
const cfgFile = () => path.join(app.getPath('userData'), 'config.json');
const save = () => { try { fs.writeFileSync(cfgFile(), JSON.stringify(cfg)); } catch {} };
const dims = () => DESIGN[cfg.mini ? 'mini' : 'full'];
const size = () => ({ width: Math.round(dims().w * cfg.scale), height: Math.round(dims().h * cfg.scale) });
const remember = () => { const b = win.getBounds(); cfg.x = b.x; cfg.y = b.y; save(); };

function defaultPos() {
  const wa = screen.getPrimaryDisplay().workArea, n = size();   // bottom-right corner
  return { x: wa.x + wa.width - n.width - 16, y: wa.y + wa.height - n.height - 16 };
}
function place(anchor) {
  const o = win.getBounds(), n = size();
  let { x, y } = o;
  if (anchor === 'center') {
    x += Math.round((o.width - n.width) / 2);
    y += Math.round((o.height - n.height) / 2);
  } else if (anchor === 'right') {
    x += o.width - n.width;
  }
  win.setBounds({ x, y, ...n });
  positionLockButton();
  win.webContents.send('layout', { scale: cfg.scale, mini: cfg.mini });
}
function toggleMini() {
  stopDrag();
  closeBtPopup();
  pendingMini = { mini: !(pendingMini?.mini ?? cfg.mini), revision: ++miniRevision };
  win.webContents.send('prepare-mini', pendingMini);
}

ipcMain.on('mini-ready', (event, revision) => {
  if (event.sender !== win?.webContents || !pendingMini || pendingMini.revision !== revision) return;
  const { mini } = pendingMini;
  pendingMini = null;
  if (mini === cfg.mini) return;
  cfg.mini = mini;
  place('right');
  remember();
});
function toggleLock() {
  stopDrag();
  locked = !locked;
  win.setIgnoreMouseEvents(locked);
  lockWin.webContents.send('lock-state', locked);
}
function reset() { pendingMini = null; cfg.scale = 1; cfg.mini = false; place(); const p = defaultPos(); win.setPosition(p.x, p.y); positionLockButton(); remember(); }

function lockButtonBounds() {
  const { x, y, width } = win.getBounds();
  const edge = Math.round(clamp(24 * cfg.scale, 24, 34));
  const inset = Math.round(clamp(6 * cfg.scale, 4, 12)) - (cfg.mini ? 4 : 0);
  return { x: x + width - edge - inset, y: y + inset, width: edge, height: edge };
}

function positionLockButton() {
  if (!lockWin || lockWin.isDestroyed()) return;
  const previous = lockWin.getBounds(), next = lockButtonBounds();
  if (Object.keys(next).some(key => next[key] !== previous[key])) lockWin.setBounds(next);
}

function createLockButton() {
  // An owned window keeps the button clickable even when the player ignores all mouse input.
  lockWin = new BrowserWindow({
    ...lockButtonBounds(), parent: win, show: false, transparent: true, frame: false,
    hasShadow: false, skipTaskbar: true, focusable: false, resizable: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
  });
  lockWin.setAlwaysOnTop(true, 'screen-saver');
  lockWin.setOpacity(cfg.opacity);
  lockWin.webContents.on('did-finish-load', () => lockWin.webContents.send('lock-state', locked));
  lockWin.once('ready-to-show', () => lockWin.showInactive());
  lockWin.loadFile(path.join(__dirname, 'renderer', 'lock.html'));
}

function buildMenu() {
  const muted = Boolean(lastMediaState?.muted);
  const volLabel = lastMediaState?.vol != null ? `Volume (${muted ? 'Muted' : lastMediaState.vol + '%'})` : 'Volume';
  const connectedBt = (lastBtState?.devices || []).filter(d => d.connected).map(d => d.name);
  const btLabel = connectedBt.length ? `Bluetooth (${connectedBt[0]})` : (lastBtState?.radio === 'off' ? 'Bluetooth (Off)' : 'Bluetooth…');
  return Menu.buildFromTemplate([
    { label: volLabel, submenu: [
        { label: muted ? 'Unmute' : 'Mute', click: () => sendHelperCmd('mute') },
        { type: 'separator' },
        ...[100, 75, 50, 25, 10].map(v => ({
          label: v + '%', type: 'radio', checked: !muted && Math.abs((lastMediaState?.vol ?? -1) - v) <= 5,
          click: () => sendHelperCmd('vol ' + v)
        }))
      ] },
    { label: btLabel, click: () => toggleBtPopup() },
    { type: 'separator' },
    { label: 'Opacity', submenu: [100, 85, 70, 55, 40].map(p => ({
        label: p + '%', type: 'radio', checked: Math.round(cfg.opacity * 100) === p,
        click: () => { cfg.opacity = p / 100; win.setOpacity(cfg.opacity); lockWin.setOpacity(cfg.opacity); save(); } })) },
    { label: 'CD only (double-click)', type: 'checkbox', checked: cfg.mini, click: toggleMini },
    { label: 'Lock & click-through (Ctrl+Alt+L)', type: 'checkbox', checked: locked, click: toggleLock },
    { label: 'Reset size & position', click: reset },
    { type: 'separator' },
    { label: 'Quit', click: () => app.quit() },
  ]);
}

function sendHelperCmd(line) {
  if (helper?.stdin.writable) helper.stdin.write(line + '\n');
}

function sendBtCmd(line) {
  if (btHelper?.stdin.writable) btHelper.stdin.write(line + '\n');
}

function btPopupBounds() {
  const b = win.getBounds();
  const display = screen.getDisplayMatching(b);
  const wa = display.workArea;
  const w = 286, h = 280, gap = 8;
  const x = clamp(b.x, wa.x + 8, wa.x + wa.width - w - 8);
  const fitsAbove = b.y - h - gap >= wa.y + 4;
  const y = fitsAbove ? b.y - h - gap : Math.min(wa.y + wa.height - h - 8, b.y + b.height + gap);
  return { x: Math.round(x), y: Math.round(y), width: w, height: h };
}

function closeBtPopup() {
  if (btPollTimer) { clearInterval(btPollTimer); btPollTimer = null; }
  if (btWin && !btWin.isDestroyed()) {
    btClosedAt = Date.now();
    btWin.close();
  }
  btWin = null;
}

function toggleBtPopup(accent) {
  if (typeof accent === 'string' && accent) lastAccent = accent;
  if (btWin && !btWin.isDestroyed()) { closeBtPopup(); return; }
  // Prevent click-blur-then-click race when clicking the player's Bluetooth button to close.
  if (Date.now() - btClosedAt < 220) return;
  btWin = new BrowserWindow({
    ...btPopupBounds(), parent: win, show: false, transparent: true, frame: false,
    hasShadow: false, skipTaskbar: true, focusable: true, resizable: false,
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
  });
  btWin.setAlwaysOnTop(true, 'screen-saver');
  btWin.webContents.on('did-finish-load', () => {
    if (!btWin || btWin.isDestroyed()) return;
    btWin.webContents.send('bt-theme', { accent: lastAccent });
    if (lastBtState) btWin.webContents.send('bt-state', lastBtState);
  });
  btWin.once('ready-to-show', () => {
    if (!btWin || btWin.isDestroyed()) return;
    btWin.show();
    btWin.focus();
  });
  btWin.on('blur', () => closeBtPopup());
  btWin.on('closed', () => {
    if (btPollTimer) { clearInterval(btPollTimer); btPollTimer = null; }
    btClosedAt = Date.now();
    btWin = null;
  });
  btWin.loadFile(path.join(__dirname, 'renderer', 'bluetooth.html'));
  sendBtCmd('list');
  btPollTimer = setInterval(() => sendBtCmd('list'), 8000);
}

function createWindow() {
  const n = size();
  let { x, y } = cfg;
  const onScreen = x != null && screen.getAllDisplays().some(d => {
    const cx = x + n.width / 2, cy = y + n.height / 2, b = d.bounds;
    return cx >= b.x && cx <= b.x + b.width && cy >= b.y && cy <= b.y + b.height;
  });
  if (!onScreen) ({ x, y } = defaultPos());
  win = new BrowserWindow({
    x, y, ...n, transparent: true, frame: false, hasShadow: false, alwaysOnTop: true,
    skipTaskbar: true, focusable: false, resizable: true, maximizable: false, fullscreenable: false,
    icon: path.join(__dirname, 'assets', 'icon.png'),
    webPreferences: { preload: path.join(__dirname, 'preload.js'), contextIsolation: true },
  });
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setIgnoreMouseEvents(locked);
  win.setOpacity(cfg.opacity);
  win.webContents.setVisualZoomLevelLimits(1, 1);
  win.on('move', () => { positionLockButton(); if (btWin && !btWin.isDestroyed()) btWin.setBounds(btPopupBounds()); });
  win.on('resize', () => { positionLockButton(); if (btWin && !btWin.isDestroyed()) btWin.setBounds(btPopupBounds()); });
  win.loadFile(path.join(__dirname, 'renderer', 'index.html'));
  win.webContents.on('did-finish-load', () => {
    win.webContents.send('layout', { scale: cfg.scale, mini: cfg.mini });
    if (lastMediaState) win.webContents.send('state', lastMediaState);
    if (lastBtState) win.webContents.send('bt-state', lastBtState);
  });
  createLockButton();
}

// Dragging/resizing is driven by the real cursor position, which is smoother and DPI-safe.
function stopDrag() { if (drag) { clearInterval(drag); drag = null; remember(); } }
ipcMain.on('drag', (_, mode) => {
  stopDrag();
  if (locked || pendingMini || (mode !== 'move' && mode !== 'resize')) return;
  const c0 = screen.getCursorScreenPoint(), b0 = win.getBounds(), d = dims();
  drag = setInterval(() => {
    const c = screen.getCursorScreenPoint();
    if (mode === 'move') {
      win.setBounds({ x: b0.x + c.x - c0.x, y: b0.y + c.y - c0.y, width: b0.width, height: b0.height });
      positionLockButton();
    }
    else { cfg.scale = clamp((b0.width + c.x - c0.x) / d.w, 0.5, 3); place(); }
  }, 12);
});
ipcMain.on('wheel', (_, dy) => { if (pendingMini) return; cfg.scale = clamp(cfg.scale * (dy < 0 ? 1.06 : 1 / 1.06), 0.5, 3); place('center'); remember(); });
ipcMain.on('toggle-mini', toggleMini);
ipcMain.on('toggle-lock', event => { if (event.sender === lockWin?.webContents) toggleLock(); });
ipcMain.on('menu', () => buildMenu().popup({ window: win }));
ipcMain.on('cmd', (event, line) => {
  if (event.sender !== win?.webContents || typeof line !== 'string') return;
  if (/^(toggle|next|prev|repeat-(all|one)|seek \d+|vol (?:100|[1-9]?\d)|mute)$/.test(line)) {
    sendHelperCmd(line);
  }
});
ipcMain.on('bt-toggle', (event, accent) => {
  if (event.sender !== win?.webContents) return;
  toggleBtPopup(accent);
});
ipcMain.on('bt-cmd', (event, line) => {
  if (event.sender !== btWin?.webContents || typeof line !== 'string') return;
  if (/^(list|radio (on|off)|(connect|disconnect) [0-9A-Fa-f]{12})$/.test(line)) {
    sendBtCmd(line);
  }
});
ipcMain.on('bt-open-settings', event => {
  if (event.sender !== btWin?.webContents) return;
  shell.openExternal('ms-settings:bluetooth').catch(() => {});
});
ipcMain.on('bt-close', event => {
  if (event.sender !== btWin?.webContents) return;
  closeBtPopup();
});

function startHelper() {
  if (process.platform !== 'win32') return;   // uses Windows media controls
  helper = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', path.join(__dirname, 'smtc.ps1')], { windowsHide: true });
  let buf = '';
  helper.stdout.setEncoding('utf8');
  helper.stdout.on('data', chunk => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line || !win || win.isDestroyed()) continue;
      try {
        const state = JSON.parse(line);
        if (!state || typeof state !== 'object') continue;
        const prevAudioOut = lastMediaState?.audioOut;
        const previousArt = state.trackKey === lastMediaState?.trackKey ? lastMediaState?.art : null;
        lastMediaState = state.none ? state : { art: previousArt ?? null, ...state };
        win.webContents.send('state', state);
        if (state.audioOut !== undefined && state.audioOut !== prevAudioOut) {
          sendBtCmd('list');
        }
      } catch {}
    }
  });
  helper.stdin.on('error', () => {});
  let lastErr = 0;
  helper.stderr.setEncoding('utf8');
  helper.stderr.on('data', d => {            // show helper errors on the overlay instead of failing silently
    console.error('[smtc]', d);
    if (String(d).trim().startsWith('art:')) return;   // cover problems: terminal only
    if (win && !win.isDestroyed() && Date.now() - lastErr > 1500) {
      lastErr = Date.now();
      win.webContents.send('state', { error: String(d).trim().split('\n')[0].slice(0, 90) });
    }
  });
  helper.on('error', error => console.error('[smtc]', error.message));
  helper.on('close', () => { helper = null; if (!quitting) setTimeout(startHelper, 2000); });
}

function startBtHelper() {
  if (process.platform !== 'win32') return;
  btHelper = spawn('powershell.exe', ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', path.join(__dirname, 'bluetooth.ps1')], { windowsHide: true });
  let buf = '';
  btHelper.stdout.setEncoding('utf8');
  btHelper.stdout.on('data', chunk => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).trim(); buf = buf.slice(i + 1);
      if (!line) continue;
      try {
        const bt = JSON.parse(line);
        if (!bt || typeof bt !== 'object') continue;
        lastBtState = bt;
        if (win && !win.isDestroyed()) win.webContents.send('bt-state', bt);
        if (btWin && !btWin.isDestroyed()) btWin.webContents.send('bt-state', bt);
      } catch {}
    }
  });
  btHelper.stdin.on('error', () => {});
  btHelper.stderr.setEncoding('utf8');
  btHelper.stderr.on('data', d => console.error('[bt]', d));
  btHelper.on('error', error => console.error('[bt]', error.message));
  btHelper.on('close', () => { btHelper = null; if (!quitting) setTimeout(startBtHelper, 3000); });
}

if (!app.requestSingleInstanceLock()) app.quit();
app.whenReady().then(() => {
  try {
    const { locked: previousLock, ...settings } = JSON.parse(fs.readFileSync(cfgFile(), 'utf8'));
    Object.assign(cfg, settings);
  } catch {}
  createWindow();
  tray = new Tray(nativeImage.createFromPath(path.join(__dirname, 'assets', 'icon.png')).resize({ width: 16, height: 16 }));
  tray.setToolTip('Vinyl Float Standalone');
  tray.on('click', () => tray.popUpContextMenu(buildMenu()));
  tray.on('right-click', () => tray.popUpContextMenu(buildMenu()));
  globalShortcut.register('Control+Alt+L', toggleLock);
  startHelper();
  startBtHelper();
});
app.on('will-quit', () => {
  quitting = true;
  globalShortcut.unregisterAll();
  if (helper) { helper.stdin.end(); helper.kill(); }
  if (btHelper) { btHelper.stdin.end(); btHelper.kill(); }
});
app.on('window-all-closed', () => app.quit());
