/**
 * Sending a printed document — the bill itself, as a PDF — on WhatsApp.
 *
 * WHAT A WEB PAGE CAN AND CANNOT DO HERE, because the difference decides the
 * whole design and it is not negotiable:
 *
 *   * A page CAN build the PDF and hand it to the operating system's share
 *     sheet, with the message already written. The share sheet is where
 *     WhatsApp appears.
 *
 *   * A page CANNOT choose WhatsApp for the person, cannot choose the
 *     recipient, and cannot press send. No browser allows it, deliberately:
 *     a page that could silently send a file from somebody's WhatsApp to
 *     anybody it liked would be a worm. So the last two taps are theirs.
 *
 *   * The wa.me link CAN open the right customer's chat with the message
 *     typed — but it carries text only. A link cannot attach a file.
 *
 * Nothing can do both. So: where the browser can share files, that is used,
 * because the PDF is the point. Where it cannot — most desktop browsers — the
 * PDF is saved and the customer's chat is opened with the message ready, and
 * the file is attached from the Downloads folder.
 */

/** Can this browser put a file into the share sheet? */
export function canShareFiles(file?: File): boolean {
  const nav = typeof navigator === 'undefined' ? undefined : (navigator as Navigator & { canShare?: (d: unknown) => boolean });
  if (!nav?.share || !nav.canShare) return false;
  try {
    return file ? nav.canShare({ files: [file] }) : nav.canShare({ files: [] });
  } catch {
    return false;
  }
}

/**
 * A filename a shopkeeper can find again on a phone six weeks later.
 *
 * Shop, document, number, date — in that order, because a phone's Downloads
 * list sorts by name and the shop's own bills should sit together.
 */
export function docFilename(parts: { shop?: string | null; kind: string; number?: string | null; date?: string | null }): string {
  const slug = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '');
  const bits = [parts.shop ? slug(parts.shop) : '', slug(parts.kind), parts.number ? slug(parts.number) : '', parts.date ?? '']
    .filter(Boolean)
    .join('-');
  return `${bits || 'document'}.pdf`;
}

/**
 * The printed sheet as a PDF.
 *
 * Rasterised from the sheet that is already on the screen rather than redrawn,
 * so the PDF is the document they print — the same paper size, the same
 * template, the same columns the owner chose in the print designer. Redrawing
 * it in PDF code would be a second layout to keep in step with the first, and
 * the two would drift the first time somebody changed a column.
 *
 * The page is the captured sheet's own shape, not forced to A4: a thermal roll
 * stays a tall narrow page instead of being letterboxed onto a sheet of
 * mostly whitespace.
 *
 * Both libraries are imported here, when the button is pressed, so they are
 * not in the bundle everybody downloads to look at a bill.
 */
export async function sheetToPdf(node: HTMLElement): Promise<Blob> {
  const [{ toPng }, { jsPDF }] = await Promise.all([import('html-to-image'), import('jspdf')]);

  // 2x so the text is crisp when the shopkeeper pinches to zoom on a phone.
  const dataUrl = await toPng(node, {
    pixelRatio: 2,
    backgroundColor: '#ffffff',
    // The sheet is sized in mm for paper; its on-screen box is what to capture.
    width: node.scrollWidth,
    height: node.scrollHeight,
  });

  const px = { w: node.scrollWidth, h: node.scrollHeight };
  // CSS pixels to PDF points, so a 210mm sheet comes out 210mm wide.
  const pt = { w: (px.w * 72) / 96, h: (px.h * 72) / 96 };
  const pdf = new jsPDF({
    unit: 'pt',
    format: [pt.w, pt.h],
    orientation: pt.w > pt.h ? 'landscape' : 'portrait',
    compress: true,
  });
  pdf.addImage(dataUrl, 'PNG', 0, 0, pt.w, pt.h, undefined, 'FAST');
  return pdf.output('blob');
}

/** Opens WhatsApp with the message typed. Text only — a link cannot attach. */
export function waChatLink(number: string | null, text: string): string {
  const q = `?text=${encodeURIComponent(text)}`;
  return number ? `https://wa.me/${number}${q}` : `https://wa.me/${q}`;
}

/** Writes the blob to the Downloads folder. */
function saveToDownloads(blob: Blob, filename: string): void {
  const url = URL.createObjectURL(blob);
  try {
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.click();
  } finally {
    // Safari has not finished reading the blob when click() returns, and
    // revoking straight away gives an empty file.
    setTimeout(() => URL.revokeObjectURL(url), 10_000);
  }
}

export type ShareOutcome = 'shared' | 'saved-and-opened' | 'cancelled';

/**
 * Share the PDF, or fall back to saving it and opening the chat.
 *
 * Returns what actually happened, so the screen can tell the person what to do
 * next instead of leaving them guessing which of the two they got.
 */
export async function shareDoc(input: {
  blob: Blob;
  filename: string;
  text: string;
  /** The customer's number, country code and digits only. Used by the fallback. */
  number?: string | null;
  /** Injected in tests, and the reason this function needs no DOM to test. */
  open?: (url: string) => void;
  save?: (blob: Blob, filename: string) => void;
}): Promise<ShareOutcome> {
  const file = new File([input.blob], input.filename, { type: 'application/pdf' });

  if (canShareFiles(file)) {
    try {
      await navigator.share({ files: [file], text: input.text });
      return 'shared';
    } catch (err) {
      // AbortError is the person closing the share sheet, which is a decision
      // and not a fault — it must not fall through to downloading a file they
      // just declined to send.
      if (err instanceof Error && err.name === 'AbortError') return 'cancelled';
      // Anything else (a browser that claimed it could share and then would
      // not) falls through to the fallback below rather than failing.
    }
  }

  const save = input.save ?? saveToDownloads;
  save(input.blob, input.filename);
  const open = input.open ?? ((u: string) => window.open(u, '_blank', 'noopener,noreferrer'));
  open(waChatLink(input.number ?? null, input.text));
  return 'saved-and-opened';
}
