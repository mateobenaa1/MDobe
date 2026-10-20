// Markdown + LaTeX (KaTeX). Compartido por el chat y los bloques de texto del PDF.
const MATH = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$([^\s$](?:[^$\n]*?[^\s$])?)\$/g;

function escapeHTML(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

// El texto viene de la IA (y del PDF que lee): no se deja pasar HTML propio ni enlaces javascript:.
// Solo sobreviven etiquetas de formato sin atributos (p. ej. <br> en tablas, <sub>, <sup>).
const SAFE_TAG = /&lt;(\/?)(br|sub|sup|b|i|em|strong|u|s|del|ins|mark|small|kbd|hr)\s*(\/?)&gt;/gi;
const SAFE_URL = /^(https?:|mailto:|mdobe:|#)/i;
marked.use({
  renderer: {
    html({ text }) { return escapeHTML(text).replace(SAFE_TAG, '<$1$2$3>'); },
    link({ href, tokens }) { return SAFE_URL.test(href.trim()) ? false : this.parser.parseInline(tokens); },
    image({ href, text }) { return SAFE_URL.test(href.trim()) || /^data:image\//i.test(href) ? false : escapeHTML(text); },
  },
});

// La matemática se aparta antes de Markdown (que estropearía _ y \) y se vuelve a poner ya renderizada.
function renderText(text, markdown = true, linkPages = true) {
  const math = [];
  let src = text.replace(MATH, (m, d1, d2, i1, i2) => {
    const display = d1 !== undefined || d2 !== undefined;
    math.push({ tex: (d1 ?? d2 ?? i1 ?? i2).trim(), display });
    return `@@M${math.length - 1}@@`;
  });
  // «página 8» → enlace a esa página del PDF
  if (linkPages) src = src.replace(/\b(p[áa]gina|p[áa]g\.)\s+(\d+)/gi, (m, w, n) => `[${m}](mdobe://page/${n})`);
  const html = markdown ? marked.parse(src, { breaks: true }) : escapeHTML(src).replace(/\n/g, '<br>');
  return html.replace(/@@M(\d+)@@/g, (m, i) => {
    const { tex, display } = math[+i];
    const out = katex.renderToString(tex, { displayMode: display, throwOnError: false, output: 'html' });
    return display ? out.replace('class="katex-display"', `class="katex-display" data-tex="${escapeHTML(tex)}"`) : out;
  });
}
