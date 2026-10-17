import { PDFDocument, StandardFonts, rgb } from 'pdf-lib';

// Coordenadas normalizadas (0..1) respecto a la página, origen arriba-izquierda,
// así las anotaciones sobreviven a cualquier zoom.
export type Annotation =
  | { type: 'text'; page: number; x: number; y: number; text: string; size: number; color: string }
  | { type: 'ink'; page: number; points: [number, number][]; width: number; color: string }
  | { type: 'rect'; page: number; x: number; y: number; w: number; h: number; color: string; kind: 'highlight' | 'whiteout' };

export function drawAnnotation(ctx: CanvasRenderingContext2D, a: Annotation, W: number, H: number) {
  ctx.save();
  if (a.type === 'text') {
    ctx.fillStyle = a.color;
    ctx.font = `${a.size * H}px Helvetica, Arial, sans-serif`;
    ctx.textBaseline = 'top';
    a.text.split('\n').forEach((line, i) => ctx.fillText(line, a.x * W, a.y * H + i * a.size * H * 1.2));
  } else if (a.type === 'ink') {
    ctx.strokeStyle = a.color;
    ctx.lineWidth = a.width * W;
    ctx.lineCap = ctx.lineJoin = 'round';
    ctx.beginPath();
    a.points.forEach(([x, y], i) => (i ? ctx.lineTo(x * W, y * H) : ctx.moveTo(x * W, y * H)));
    ctx.stroke();
  } else {
    ctx.fillStyle = a.kind === 'whiteout' ? '#ffffff' : a.color;
    ctx.globalAlpha = a.kind === 'whiteout' ? 1 : 0.35;
    ctx.fillRect(a.x * W, a.y * H, a.w * W, a.h * H);
  }
  ctx.restore();
}

function toRgb(hex: string) {
  const n = parseInt(hex.slice(1), 16);
  return rgb(((n >> 16) & 255) / 255, ((n >> 8) & 255) / 255, (n & 255) / 255);
}

// Incrusta las anotaciones en el PDF original y devuelve los bytes nuevos.
export async function exportPdf(original: Uint8Array, annotations: Annotation[]): Promise<Uint8Array> {
  const doc = await PDFDocument.load(original, { ignoreEncryption: true });
  const font = await doc.embedFont(StandardFonts.Helvetica);
  const pages = doc.getPages();

  for (const a of annotations) {
    const page = pages[a.page];
    const { x: ox, y: oy, width: W, height: H } = page.getCropBox();
    const X = (x: number) => ox + x * W;
    const Y = (y: number) => oy + H - y * H; // pdf-lib usa origen abajo-izquierda
    const color = toRgb(a.color);

    if (a.type === 'text') {
      const size = a.size * H;
      a.text.split('\n').forEach((line, i) => {
        const safe = line.replace(/[^\x20-\xFF€]/g, '?'); // Helvetica estándar solo cubre WinAnsi
        page.drawText(safe, { x: X(a.x), y: Y(a.y) - size * (0.8 + i * 1.2), size, font, color });
      });
    } else if (a.type === 'ink') {
      for (let i = 1; i < a.points.length; i++) {
        const [x1, y1] = a.points[i - 1];
        const [x2, y2] = a.points[i];
        page.drawLine({ start: { x: X(x1), y: Y(y1) }, end: { x: X(x2), y: Y(y2) }, thickness: a.width * W, color, lineCap: 1 });
      }
    } else {
      page.drawRectangle({
        x: X(a.x), y: Y(a.y + a.h), width: a.w * W, height: a.h * H,
        color: a.kind === 'whiteout' ? rgb(1, 1, 1) : color,
        opacity: a.kind === 'whiteout' ? 1 : 0.35,
      });
    }
  }
  return doc.save();
}
