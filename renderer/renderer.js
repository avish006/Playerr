function createOverlay(root, api, layoutElement) {
  const $ = id => root.querySelector('#' + id);
  const app = $('app'), track = $('track'), art = $('art');
  let st = { pos: 0, dur: 0, playing: false, at: performance.now() };
  let scrubbing = false;
  let currentArt = null, artRequest = 0, artRetry, currentTrack = null;

  const fmt = ms => { const s = Math.max(0, Math.floor(ms / 1000)); return Math.floor(s / 60) + ':' + String(s % 60).padStart(2, '0'); };

  const GREEN = '#1ed760', CLEAR = 'rgba(0,0,0,0)';
  // Choose one dominant hue; use a neutral only when the cover has no usable colour.
  function palette(img) {
    const N = 24, c = document.createElement('canvas'); c.width = c.height = N;
    const x = c.getContext('2d', { willReadFrequently: true }); x.drawImage(img, 0, 0, N, N);
    const d = x.getImageData(0, 0, N, N).data;
    const bins = Array.from({ length: 12 }, () => ({ w: 0, r: 0, g: 0, b: 0 }));
    const light = { w: 0, r: 0, g: 0, b: 0 }, all = { w: 0, r: 0, g: 0, b: 0 };
    for (let i = 0; i < d.length; i += 4) {
      if (!d[i + 3]) continue;
      const r = d[i], g = d[i + 1], b = d[i + 2];
      const mx = Math.max(r, g, b), mn = Math.min(r, g, b), v = mx / 255, s = mx ? (mx - mn) / mx : 0;
      all.w++; all.r += r; all.g += g; all.b += b;
      if (s > .22 && v > .2) {
        let h = mx === r ? ((g - b) / (mx - mn)) % 6 : mx === g ? (b - r) / (mx - mn) + 2 : (r - g) / (mx - mn) + 4;
        if (h < 0) h += 6;
        const bin = bins[Math.min(11, Math.floor(h * 2))], w = s * v;
        bin.w += w; bin.r += r * w; bin.g += g * w; bin.b += b * w;
      } else if (v > .6) { light.w++; light.r += r; light.g += g; light.b += b; }
    }
    const rgb = o => [o.r / o.w, o.g / o.w, o.b / o.w];
    const dominant = bins.reduce((best, bin) => bin.w > best.w ? bin : best);
    if (dominant.w) return rgb(dominant);
    return all.w ? rgb(light.w > 20 ? light : all) : null;
  }

  function resetArt() {
    art.style.backgroundImage = '';
    app.classList.remove('has-art');
    app.style.setProperty('--accent', GREEN);
    app.style.setProperty('--ambient', CLEAR);
  }

  function setArt(url, trackChanged = false) {
    if (url === currentArt && !trackChanged) return;
    currentArt = url;
    const request = ++artRequest;
    clearTimeout(artRetry);
    if (trackChanged || !url) resetArt();
    if (!url) return;

    function load(attempt) {
      const img = new Image();
      img.onload = () => {
        if (request !== artRequest) return;
        art.style.backgroundImage = `url("${url}")`;
        let color;
        try { color = palette(img); } catch { return; }
        if (!color) return;
        const fit = target => {
          const factor = Math.min(1.5, target / Math.max(...color, 1));
          return color.map(value => Math.round(value * factor)).join(', ');
        };
        app.style.setProperty('--ambient', `rgba(${fit(220)}, .55)`);
        app.style.setProperty('--accent', `rgb(${fit(235)})`);
        app.classList.add('has-art');
      };
      img.onerror = () => {
        if (request === artRequest && attempt < 3) {
          artRetry = setTimeout(() => load(attempt + 1), 450 * attempt);
        }
      };
      if (url.startsWith('https:')) img.crossOrigin = 'anonymous';
      img.src = url;
    }

    load(1);
  }

  const repeatButtons = root.querySelectorAll('#ctrl .repeat');
  let repeatMode = null;
  function updateRepeat(mode) {
    if (repeatMode === mode) return;
    repeatMode = mode;
    for (const button of repeatButtons) {
      const name = button.getAttribute('aria-label');
      const selected = button.dataset.c === `repeat-${mode}`;
      button.disabled = !mode;
      button.setAttribute('aria-pressed', String(selected));
      button.title = !mode ? `${name} · Select the Spotify tab to enable repeat` : selected ? `Turn off ${name}` : name;
    }
  }

  api.onState(s => {
    updateRepeat(s.repeat ?? null);
    if (s.error) { $('title').textContent = "Can't read media controls"; $('artist').textContent = s.error; return; }
    if (s.none) {
      $('title').textContent = 'Nothing playing'; $('artist').textContent = 'Play a song in Spotify';
      currentTrack = null;
      app.classList.remove('playing');
      st.playing = false;
      st.dur = 0;
      setArt(null);
      return;
    }
    $('title').textContent = s.title || 'Unknown track';
    $('artist').textContent = s.artist || s.album || '';
    const trackKey = s.trackKey ?? JSON.stringify([s.title, s.artist, s.album]);
    const trackChanged = trackKey !== currentTrack;
    if (trackChanged || s.art !== undefined) setArt(s.art ?? null, trackChanged);
    currentTrack = trackKey;
    app.classList.toggle('playing', s.playing);
    if (!scrubbing) st = { pos: s.pos, dur: s.dur, playing: s.playing, at: performance.now() };
  });
  api.onLayout(({ scale, mini }) => {
    app.style.setProperty('--s', scale);
    layoutElement.classList.toggle('mini', mini);
  });

  api.onPrepareMini(({ mini, revision }) => {
    layoutElement.classList.toggle('mini', mini);
    // Paint the mode change while the window still clips the card to its old bounds.
    requestAnimationFrame(() => requestAnimationFrame(() => api.miniReady(revision)));
  });

  // smooth progress between the ~0.5s updates
  setInterval(() => {
    if (scrubbing) return;
    const pos = Math.min(st.dur, st.pos + (st.playing ? performance.now() - st.at : 0));
    $('fill').style.width = (st.dur ? pos / st.dur * 100 : 0) + '%';
    $('cur').textContent = fmt(pos); $('dur').textContent = fmt(st.dur);
  }, 200);

  // buttons
  root.querySelectorAll('#ctrl button').forEach(b => b.addEventListener('click', () => api.cmd(b.dataset.c)));

  // seek slider (drag to scrub, release to seek)
  const ratio = e => { const r = track.getBoundingClientRect(); return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)); };
  track.addEventListener('pointerdown', e => { if (!st.dur) return; scrubbing = true; track.setPointerCapture(e.pointerId); scrub(e); });
  track.addEventListener('pointermove', e => { if (scrubbing) scrub(e); });
  track.addEventListener('pointerup', e => {
    if (!scrubbing) return;
    scrubbing = false;
    const pos = Math.round(ratio(e) * st.dur);
    st = { ...st, pos, at: performance.now() };
    api.cmd('seek ' + pos);
  });
  function scrub(e) { const r = ratio(e); $('fill').style.width = r * 100 + '%'; $('cur').textContent = fmt(r * st.dur); }

  // drag the window anywhere that isn't a control; double-click toggles CD-only mode
  const isControl = t => t.closest('button, #track, #grip');
  app.addEventListener('pointerdown', e => {
    if (e.button !== 0 || isControl(e.target)) return;
    app.setPointerCapture(e.pointerId); api.drag('move', e);
  });
  $('grip').addEventListener('pointerdown', e => { if (e.button !== 0) return; $('grip').setPointerCapture(e.pointerId); api.drag('resize', e); });
  ['pointerup', 'pointercancel', 'lostpointercapture'].forEach(t => {
    app.addEventListener(t, () => api.drag('end'));
    $('grip').addEventListener(t, () => api.drag('end'));
  });
  app.addEventListener('dblclick', e => { if (!isControl(e.target)) api.toggleMini(); });
  app.addEventListener('wheel', e => { if (e.ctrlKey) { e.preventDefault(); api.wheel(e.deltaY); } }, { passive: false });
  app.addEventListener('contextmenu', e => { if (api.menu) { e.preventDefault(); api.menu(); } });


}

if (location.protocol === 'file:' && window.api) createOverlay(document, window.api, document.body);
