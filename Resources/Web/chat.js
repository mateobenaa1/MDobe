const log = document.getElementById('log');
// Llamado desde Swift con la lista completa de mensajes.
function render(messages) {
  log.innerHTML = messages.map(m => {
    if (m.role === 'ai' && !m.text) return '<div class="msg ai typing">…</div>';
    if (m.role === 'info') return `<div class="info">${renderText(m.text, false)}</div>`;
    return `<div class="msg ${m.role}">${renderText(m.text, m.role === 'ai')}</div>`;
  }).join('');
  scrollTo(0, document.body.scrollHeight);
}

// Clic en una fórmula en bloque → copiar su LaTeX
document.addEventListener('click', e => {
  const block = e.target.closest('.katex-display');
  if (!block?.dataset.tex) return;
  window.webkit.messageHandlers.copy.postMessage(block.dataset.tex);
  const t = document.getElementById('toast');
  t.style.opacity = 1;
  setTimeout(() => t.style.opacity = 0, 1200);
});
