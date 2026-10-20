// Llamado desde Swift. Devuelve la altura del bloque en pt.
// width = 0 → ocupar todo el ancho (vista previa).
async function setContent(text, width, plain) {
  const b = document.getElementById('block');
  b.style.width = width ? width + 'px' : '100%';
  b.className = plain ? 'plain' : '';
  b.innerHTML = renderText(text, true, false);
  await document.fonts.ready; // las fuentes de KaTeX cambian la altura al cargar
  return Math.ceil(b.getBoundingClientRect().height);
}
