import type { PDFDocumentProxy } from 'pdfjs-dist';
import type { Annotation } from './annotations';
import { documentText, findText } from './text';

export interface AIContext {
  getPdf(): PDFDocumentProxy | null;
  getBytes(): Uint8Array | null;
  getFileName(): string;
  exportCurrent(): Promise<Uint8Array>;
  addAnnotation(a: Annotation): void;
}

type Action =
  | { type: 'highlight'; page: number; text: string }
  | { type: 'note'; page: number; text: string; note: string }
  | { type: 'replace'; page: number; text: string; replacement: string }
  | { type: 'add_text'; page: number; x: number; y: number; text: string };
type Turn = { role: 'user' | 'model'; text: string };

const SYSTEM = `Eres el asistente de MDobe, un editor de PDF. El usuario tiene abierto el PDF adjunto.
Responde siempre en español y SOLO con JSON: {"reply": string, "actions": Action[]}.
"reply" es tu respuesta para el usuario (texto plano, sin markdown). Si el usuario pide cambios en el PDF, añade acciones:
- {"type":"highlight","page":N,"text":"texto exacto a resaltar"}
- {"type":"note","page":N,"text":"texto exacto donde anclar","note":"comentario"}
- {"type":"replace","page":N,"text":"texto exacto a sustituir","replacement":"texto nuevo"}
- {"type":"add_text","page":N,"x":0-1,"y":0-1,"text":"..."}  (x,y relativos a la página desde arriba-izquierda)
"page" empieza en 1. "text" debe copiarse literalmente del PDF y ser corto (una frase o menos). Si no hay cambios, "actions": [].`;

const store = {
  get: (k: string) => { try { return localStorage.getItem(k) ?? ''; } catch { return ''; } },
  set: (k: string, v: string) => { try { localStorage.setItem(k, v); } catch { /* sin almacenamiento */ } },
};

const toBase64 = (bytes: Uint8Array) =>
  new Promise<string>((resolve) => {
    const r = new FileReader();
    r.onload = () => resolve((r.result as string).split(',')[1]);
    r.readAsDataURL(new Blob([bytes as BlobPart]));
  });

export function initAI(ctx: AIContext) {
  const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
  const panel = $('ai');
  const log = $('aiLog');
  const input = $<HTMLTextAreaElement>('aiInput');
  const keyInput = $<HTMLInputElement>('aiKey');
  const modelInput = $<HTMLInputElement>('aiModel');
  let history: Turn[] = [];
  let docText = '';

  keyInput.value = store.get('mdobe.geminiKey');
  modelInput.value = store.get('mdobe.geminiModel') || 'gemini-flash-latest';
  keyInput.addEventListener('change', () => store.set('mdobe.geminiKey', keyInput.value.trim()));
  modelInput.addEventListener('change', () => store.set('mdobe.geminiModel', modelInput.value.trim()));
  if (!keyInput.value) $<HTMLDetailsElement>('aiSettings').open = true;

  $('aiToggle').addEventListener('click', () => panel.classList.toggle('open'));
  $('aiClose').addEventListener('click', () => panel.classList.remove('open'));

  const say = (who: 'user' | 'ai' | 'info', text: string) => {
    const div = document.createElement('div');
    div.className = `msg ${who}`;
    div.textContent = text;
    log.append(div);
    log.scrollTop = log.scrollHeight;
    return div;
  };

  // ---------- Gemini integrado ----------
  async function ask(question: string) {
    const pdf = ctx.getPdf();
    const bytes = ctx.getBytes();
    const key = keyInput.value.trim();
    if (!pdf || !bytes) return say('info', 'Abre primero un PDF.');
    if (!key) {
      $<HTMLDetailsElement>('aiSettings').open = true;
      return say('info', 'Pega tu clave gratuita de Gemini en Ajustes (aistudio.google.com → Get API key).');
    }
    say('user', question);
    const wait = say('ai', 'Pensando…');

    // Gemini acepta el PDF directamente (hasta ~20 MB); si es más grande, mandamos solo el texto.
    const docPart = bytes.length < 15e6
      ? { inlineData: { mimeType: 'application/pdf', data: await toBase64(bytes) } }
      : { text: `Texto del PDF:\n${await documentText(pdf)}` };
    const contents = history.map((t, i) => ({ role: t.role, parts: i === 0 ? [docPart, { text: t.text }] : [{ text: t.text }] }));
    contents.push({ role: 'user', parts: history.length ? [{ text: question }] : [docPart, { text: question }] });

    try {
      const res = await fetch(`https://generativelanguage.googleapis.com/v1beta/models/${modelInput.value.trim()}:generateContent`, {
        method: 'POST',
        headers: { 'content-type': 'application/json', 'x-goog-api-key': key },
        body: JSON.stringify({
          systemInstruction: { parts: [{ text: SYSTEM }] },
          contents,
          generationConfig: { responseMimeType: 'application/json' },
        }),
      });
      const data = await res.json();
      if (!res.ok) throw new Error(data.error?.message ?? res.statusText);
      const raw: string = data.candidates?.[0]?.content?.parts?.map((p: any) => p.text ?? '').join('') ?? '';
      const parsed = JSON.parse(raw) as { reply?: string; actions?: Action[] };
      wait.textContent = parsed.reply || '(sin respuesta)';
      history.push({ role: 'user', text: question }, { role: 'model', text: raw });
      const applied = await applyActions(parsed.actions ?? []);
      if (parsed.actions?.length) say('info', `✓ ${applied} de ${parsed.actions.length} cambios aplicados (↶ para deshacer). Guarda para conservarlos.`);
    } catch (err) {
      wait.className = 'msg info';
      wait.textContent = `Error: ${(err as Error).message}`;
    }
  }

  async function applyActions(actions: Action[]) {
    const pdf = ctx.getPdf()!;
    let ok = 0;
    for (const a of actions) {
      const page = (a.page ?? 1) - 1;
      if (page < 0 || page >= pdf.numPages) continue;
      if (a.type === 'add_text') {
        ctx.addAnnotation({ type: 'text', page, x: a.x, y: a.y, text: a.text, size: 0.015, color: '#d32f2f' });
        ok++;
        continue;
      }
      const rects = await findText(pdf, page, a.text);
      if (!rects.length) continue;
      ok++;
      if (a.type === 'highlight') {
        rects.forEach((r) => ctx.addAnnotation({ type: 'rect', page, ...r, color: '#ffeb3b', kind: 'highlight' }));
      } else if (a.type === 'note') {
        const r = rects[rects.length - 1];
        rects.forEach((q) => ctx.addAnnotation({ type: 'rect', page, ...q, color: '#ffeb3b', kind: 'highlight' }));
        ctx.addAnnotation({ type: 'text', page, x: r.x, y: r.y + r.h, text: `Nota: ${a.note}`, size: 0.012, color: '#d32f2f' });
      } else if (a.type === 'replace') {
        rects.forEach((r) => ctx.addAnnotation({ type: 'rect', page, ...r, color: '#ffffff', kind: 'whiteout' }));
        const r = rects[0];
        ctx.addAnnotation({ type: 'text', page, x: r.x, y: r.y, text: a.replacement, size: r.h / 1.25, color: '#000000' });
      }
    }
    return ok;
  }

  const send = () => {
    const q = input.value.trim();
    if (!q) return;
    input.value = '';
    ask(q);
  };
  $('aiSend').addEventListener('click', send);
  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' && !e.shiftKey) {
      e.preventDefault();
      send();
    }
  });

  // ---------- ChatGPT (usa tu plan Plus, sin API) ----------
  const prompt = () =>
    `${input.value.trim() || 'Explícame este documento.'}\n\nDocumento "${ctx.getFileName()}":\n${docText}`;

  $('gptShare').addEventListener('click', async () => {
    if (!ctx.getBytes()) return say('info', 'Abre primero un PDF.');
    const file = new File([(await ctx.exportCurrent()) as BlobPart], ctx.getFileName(), { type: 'application/pdf' });
    if (navigator.canShare?.({ files: [file] })) {
      try {
        await navigator.share({ files: [file], text: input.value.trim() || undefined });
      } catch { /* cancelado */ }
    } else say('info', 'Este navegador no puede compartir archivos. Usa "Copiar y abrir ChatGPT".');
  });

  $('gptCopy').addEventListener('click', () => {
    if (!docText) return say('info', ctx.getBytes() ? 'Preparando el texto del PDF, prueba en un segundo.' : 'Abre primero un PDF.');
    // Todo síncrono para no perder el "gesto del usuario" (Safari bloquea portapapeles y ventanas si no).
    navigator.clipboard.writeText(prompt()).then(
      () => say('info', 'Copiado. Pégalo en ChatGPT (⌘V / mantener pulsado → Pegar).'),
      () => say('info', 'No se pudo copiar al portapapeles.'),
    );
    window.open('https://chatgpt.com/', '_blank');
  });

  return {
    // Llamar al abrir un PDF nuevo
    async onDocument() {
      history = [];
      docText = '';
      log.innerHTML = '';
      const pdf = ctx.getPdf();
      if (pdf) docText = await documentText(pdf);
    },
  };
}
