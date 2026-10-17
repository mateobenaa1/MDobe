import * as pdfjs from 'pdfjs-dist';
import workerUrl from 'pdfjs-dist/build/pdf.worker.min.mjs?url';
import { Annotation, drawAnnotation, exportPdf } from './annotations';

pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

type Tool = 'none' | 'text' | 'draw' | 'highlight' | 'whiteout';
type PageView = { el: HTMLDivElement; base: HTMLCanvasElement; overlay: HTMLCanvasElement; rendered: boolean };

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const viewer = $<HTMLElement>('viewer');
const colorInput = $<HTMLInputElement>('color');

let pdf: pdfjs.PDFDocumentProxy | null = null;
let loading: pdfjs.PDFDocumentLoadingTask | null = null;
let bytes: Uint8Array | null = null;
let fileName = 'documento.pdf';
let zoom = 1;
let tool: Tool = 'none';
let annotations: Annotation[] = [];
let views: PageView[] = [];
let observer: IntersectionObserver | null = null;

// ---------- Abrir ----------
async function openPdf(data: ArrayBuffer, name: string) {
  bytes = new Uint8Array(data);
  fileName = name;
  annotations = [];
  loading?.destroy();
  loading = pdfjs.getDocument({ data: bytes.slice() }); // copia: pdf.js transfiere el buffer al worker
  pdf = await loading.promise;
  $('docName').textContent = name;
  document.title = `${name} — MDobe`;
  ($('save') as HTMLButtonElement).disabled = false;
  await layout();
}

async function layout() {
  if (!pdf) return;
  observer?.disconnect();
  viewer.innerHTML = '';
  views = [];
  const first = await pdf.getPage(1);
  const fit = Math.min(1.5, (viewer.clientWidth - 32) / first.getViewport({ scale: 1 }).width);
  const scale = fit * zoom;
  $('zoomLabel').textContent = `${Math.round(zoom * 100)}%`;

  observer = new IntersectionObserver(
    (entries) => entries.forEach((e) => e.isIntersecting && renderPage(views.findIndex((v) => v.el === e.target), scale)),
    { root: viewer, rootMargin: '600px 0px' },
  );

  for (let i = 0; i < pdf.numPages; i++) {
    const page = await pdf.getPage(i + 1);
    const vp = page.getViewport({ scale });
    const el = document.createElement('div');
    el.className = 'page';
    el.style.width = `${vp.width}px`;
    el.style.height = `${vp.height}px`;
    const base = document.createElement('canvas');
    const overlay = document.createElement('canvas');
    overlay.className = 'overlay';
    el.append(base, overlay);
    viewer.append(el);
    const view = { el, base, overlay, rendered: false };
    views.push(view);
    attachPointer(i, view);
    observer.observe(el);
  }
}

async function renderPage(i: number, scale: number) {
  const v = views[i];
  if (!pdf || !v || v.rendered) return;
  v.rendered = true;
  const page = await pdf.getPage(i + 1);
  const dpr = Math.min(window.devicePixelRatio || 1, 2); // limitado para no reventar la RAM del iPad
  const vp = page.getViewport({ scale: scale * dpr });
  for (const c of [v.base, v.overlay]) {
    c.width = vp.width;
    c.height = vp.height;
    c.style.width = v.el.style.width;
    c.style.height = v.el.style.height;
  }
  await page.render({ canvas: v.base, viewport: vp }).promise;
  redraw(i);
}

function redraw(i: number) {
  const v = views[i];
  if (!v?.rendered) return;
  const ctx = v.overlay.getContext('2d')!;
  ctx.clearRect(0, 0, v.overlay.width, v.overlay.height);
  annotations.filter((a) => a.page === i).forEach((a) => drawAnnotation(ctx, a, v.overlay.width, v.overlay.height));
}

// ---------- Herramientas ----------
function attachPointer(page: number, v: PageView) {
  let current: Annotation | null = null;
  let start: [number, number] = [0, 0];

  const pos = (e: PointerEvent): [number, number] => {
    const r = v.overlay.getBoundingClientRect();
    return [(e.clientX - r.left) / r.width, (e.clientY - r.top) / r.height];
  };

  v.overlay.addEventListener('pointerdown', (e) => {
    if (tool === 'none') return;
    e.preventDefault();
    const p = pos(e);
    const color = colorInput.value;
    if (tool === 'text') {
      const text = prompt('Texto:');
      if (text) push({ type: 'text', page, x: p[0], y: p[1], text, size: 0.018, color });
      return;
    }
    v.overlay.setPointerCapture(e.pointerId);
    start = p;
    current =
      tool === 'draw'
        ? { type: 'ink', page, points: [p], width: 0.003, color }
        : { type: 'rect', page, x: p[0], y: p[1], w: 0, h: 0, color, kind: tool };
    annotations.push(current);
  });

  v.overlay.addEventListener('pointermove', (e) => {
    if (!current) return;
    const p = pos(e);
    if (current.type === 'ink') current.points.push(p);
    else if (current.type === 'rect') {
      current.x = Math.min(start[0], p[0]);
      current.y = Math.min(start[1], p[1]);
      current.w = Math.abs(p[0] - start[0]);
      current.h = Math.abs(p[1] - start[1]);
    }
    redraw(page);
  });

  const end = () => {
    if (current?.type === 'rect' && (current.w < 0.002 || current.h < 0.002)) annotations.pop();
    current = null;
    redraw(page);
  };
  v.overlay.addEventListener('pointerup', end);
  v.overlay.addEventListener('pointercancel', end);
}

function push(a: Annotation) {
  annotations.push(a);
  redraw(a.page);
}

document.querySelectorAll<HTMLButtonElement>('#tools button').forEach((b) =>
  b.addEventListener('click', () => {
    tool = b.dataset.tool as Tool;
    viewer.dataset.tool = tool;
    document.querySelectorAll('#tools button').forEach((x) => x.classList.toggle('active', x === b));
  }),
);

$('undo').addEventListener('click', () => {
  const a = annotations.pop();
  if (a) redraw(a.page);
});

// ---------- Zoom ----------
const setZoom = (z: number) => {
  zoom = Math.max(0.25, Math.min(4, z));
  layout();
};
$('zoomIn').addEventListener('click', () => setZoom(zoom * 1.25));
$('zoomOut').addEventListener('click', () => setZoom(zoom / 1.25));

// ---------- Guardar ----------
$('save').addEventListener('click', async () => {
  if (!bytes) return;
  const out = await exportPdf(bytes, annotations);
  const blob = new Blob([out as BlobPart], { type: 'application/pdf' });
  const file = new File([blob], fileName, { type: 'application/pdf' });
  // En iPad/Android abre el menú compartir (Guardar en Archivos, Drive...); en Mac descarga.
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file] });
      return;
    } catch (err) {
      if ((err as Error).name === 'AbortError') return;
    }
  }
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = fileName;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 10_000);
});

// ---------- Entradas de archivo ----------
$<HTMLInputElement>('file').addEventListener('change', async (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  if (f) openPdf(await f.arrayBuffer(), f.name);
});

viewer.addEventListener('dragover', (e) => {
  e.preventDefault();
  viewer.classList.add('drag');
});
viewer.addEventListener('dragleave', () => viewer.classList.remove('drag'));
viewer.addEventListener('drop', async (e) => {
  e.preventDefault();
  viewer.classList.remove('drag');
  const f = e.dataTransfer?.files[0];
  if (f?.type === 'application/pdf') openPdf(await f.arrayBuffer(), f.name);
});

// Cuando MDobe se abre como app predeterminada de PDF (Chrome/Edge)
(window as any).launchQueue?.setConsumer(async (params: any) => {
  const handle = params.files?.[0];
  if (handle) {
    const f: File = await handle.getFile();
    openPdf(await f.arrayBuffer(), f.name);
  }
});

let resizeTimer = 0;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(layout, 250);
});
