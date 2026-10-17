// Markdown + LaTeX (KaTeX). Compartido por el chat y los bloques de texto del PDF.
const MATH = /\$\$([\s\S]+?)\$\$|\\\[([\s\S]+?)\\\]|\\\(([\s\S]+?)\\\)|\$([^\s$](?:[^$\n]*?[^\s$])?)\$/g;

function escapeHTML(s) {
  return s.replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

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
