const panel = document.getElementById('panel');
const list = document.getElementById('list');
const msg = document.getElementById('msg');
const refreshBtn = document.getElementById('refresh');
const radioToggle = document.getElementById('radio-toggle');
const settingsBtn = document.getElementById('settings-btn');
const closeBtn = document.getElementById('close-btn');

let currentState = null;
let pendingAddr = null;
let pendingRadio = false;

function iconSvg(isAudio) {
  return isAudio
    ? '<svg class="dev-ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3a9 9 0 0 0-9 9v7c0 1.1.9 2 2 2h3v-8H5v-1a7 7 0 0 1 14 0v1h-3v8h3c1.1 0 2-.9 2-2v-7a9 9 0 0 0-9-9z"/></svg>'
    : '<svg class="dev-ico" viewBox="0 0 24 24" aria-hidden="true"><path d="M17 1H7c-1.1 0-2 .9-2 2v18c0 1.1.9 2 2 2h10c1.1 0 2-.9 2-2V3c0-1.1-.9-2-2-2zm0 18H7V5h10v14z"/></svg>';
}

function showMessage(text) {
  if (!text) {
    msg.hidden = true;
    msg.textContent = '';
    return;
  }
  msg.hidden = false;
  msg.textContent = text;
}

function render(state) {
  currentState = state;
  pendingAddr = null;
  pendingRadio = false;
  refreshBtn.classList.remove('spinning');
  showMessage(state.error || '');

  const available = state.radio !== 'unavailable';
  const radioOn = state.radio === 'on';
  radioToggle.disabled = !available;
  radioToggle.setAttribute('aria-checked', String(radioOn));

  list.innerHTML = '';
  if (!available) {
    list.innerHTML = '<div class="empty">No Bluetooth adapter detected on this PC.</div>';
    return;
  }
  if (!radioOn) {
    list.innerHTML = '<div class="empty">Bluetooth is turned off.<br>Toggle the switch above to turn it on.</div>';
    return;
  }

  const devices = state.devices || [];
  if (!devices.length) {
    list.innerHTML = '<div class="empty">No paired Bluetooth devices.<br>Use Bluetooth settings to pair one.</div>';
    return;
  }

  for (const d of devices) {
    const row = document.createElement('div');
    row.className = 'dev' + (d.connected ? ' connected' : '');
    row.setAttribute('role', 'listitem');

    row.innerHTML = iconSvg(d.isAudio);

    const meta = document.createElement('div');
    meta.className = 'dev-meta';
    const name = document.createElement('div');
    name.className = 'dev-name';
    name.textContent = d.name;
    const sub = document.createElement('div');
    sub.className = 'dev-sub';
    sub.textContent = d.connected ? 'Connected' : (d.isAudio ? 'Audio · Paired' : 'Paired');
    meta.append(name, sub);
    row.appendChild(meta);

    if (d.canControl) {
      const btn = document.createElement('button');
      btn.className = 'dev-act';
      btn.textContent = d.connected ? 'Disconnect' : 'Connect';
      btn.addEventListener('click', () => {
        if (pendingAddr) return;
        pendingAddr = d.addr;
        btn.disabled = true;
        btn.textContent = d.connected ? 'Disconnecting…' : 'Connecting…';
        showMessage('');
        window.api.btCmd(`${d.connected ? 'disconnect' : 'connect'} ${d.addr}`);
      });
      row.appendChild(btn);
    }

    list.appendChild(row);
  }
}

refreshBtn.addEventListener('click', () => {
  refreshBtn.classList.add('spinning');
  showMessage('');
  window.api.btCmd('list');
});

radioToggle.addEventListener('click', () => {
  if (!currentState || currentState.radio === 'unavailable' || pendingRadio) return;
  pendingRadio = true;
  const nextOn = currentState.radio !== 'on';
  radioToggle.disabled = true;
  showMessage('');
  window.api.btCmd('radio ' + (nextOn ? 'on' : 'off'));
});

settingsBtn.addEventListener('click', () => window.api.btOpenSettings());
closeBtn.addEventListener('click', () => window.api.btClose());
document.addEventListener('keydown', e => {
  if (e.key === 'Escape') window.api.btClose();
});

if (window.api) {
  window.api.onBtTheme(t => {
    if (t && t.accent) panel.style.setProperty('--accent', t.accent);
  });
  window.api.onBtState(render);
  window.api.btCmd('list');
}
