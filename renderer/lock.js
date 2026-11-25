const button = document.querySelector('button');

button.addEventListener('click', () => api.toggleLock());
api.onLockState(locked => {
  button.setAttribute('aria-pressed', String(locked));
  button.title = locked ? 'Click-through on. Click to use player controls.' : 'Click-through off. Click to let clicks pass through.';
});
