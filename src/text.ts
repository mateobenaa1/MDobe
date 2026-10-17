import * as pdfjs from 'pdfjs-dist';

type Item = { str: string; start: number; end: number; x: number; y: number; w: number; h: number };
type PageText = { text: string; items: Item[] };

const cache = new WeakMap<pdfjs.PDFDocumentProxy, Map<number, PageText>>();
const collapse = (s: string) => s.replace(/\s+/g, ' ').trim();

// Texto de una página con la posición normalizada (0..1) de cada fragmento.
async function pageText(pdf: pdfjs.PDFDocumentProxy, page: number): Promise<PageText> {
  let map = cache.get(pdf);
  if (!map) cache.set(pdf, (map = new Map()));
  const hit = map.get(page);
  if (hit) return hit;

  const p = await pdf.getPage(page + 1);
  const vp = p.getViewport({ scale: 1 });
  const content = await p.getTextContent();
  const items: Item[] = [];
  let text = '';
  for (const it of content.items as any[]) {
    const str = collapse(it.str ?? '');
    if (!str) continue;
    const tx = pdfjs.Util.transform(vp.transform, it.transform);
    const h = Math.hypot(tx[2], tx[3]);
    if (text) text += ' ';
    items.push({ str, start: text.length, end: text.length + str.length, x: tx[4] / vp.width, y: (tx[5] - h) / vp.height, w: it.width / vp.width, h: (h * 1.2) / vp.height });
    text += str;
  }
  const result = { text, items };
  map.set(page, result);
  return result;
}

export async function documentText(pdf: pdfjs.PDFDocumentProxy, maxChars = 120_000) {
  let out = '';
  for (let i = 0; i < pdf.numPages && out.length < maxChars; i++) out += `\n\n--- Página ${i + 1} ---\n${(await pageText(pdf, i)).text}`;
  return out.slice(0, maxChars);
}

// Rectángulos (normalizados) que cubren la primera aparición de `needle` en la página.
export async function findText(pdf: pdfjs.PDFDocumentProxy, page: number, needle: string) {
  const { text, items } = await pageText(pdf, page);
  const q = collapse(needle).toLowerCase();
  const at = q ? text.toLowerCase().indexOf(q) : -1;
  if (at < 0) return [];
  const end = at + q.length;
  return items
    .filter((it) => it.end > at && it.start < end)
    .map((it) => {
      const len = it.end - it.start || 1;
      const from = Math.max(0, at - it.start) / len;
      const to = Math.min(len, end - it.start) / len;
      return { x: it.x + it.w * from, y: it.y, w: it.w * (to - from), h: it.h };
    });
}
