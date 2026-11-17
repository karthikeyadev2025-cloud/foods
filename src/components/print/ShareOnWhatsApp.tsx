import { MessageCircle } from 'lucide-react';
import { useState, type RefObject } from 'react';
import { Button } from '@/components/ui/button';
import { toast, toastError } from '@/hooks/use-toast';
import { docFilename, canShareFiles, shareDoc, sheetToPdf, waChatLink } from '@/lib/shareDoc';
import { waNumber } from '@/lib/whatsapp';

/**
 * Send this printed sheet on WhatsApp, as a PDF.
 *
 * It sits beside Print on every document that has a printed sheet, because
 * that is where somebody is standing when they decide to send it.
 *
 * WHAT IT CANNOT DO, said here so the next person does not go looking for the
 * setting: it cannot pick WhatsApp, pick the contact and press send on its
 * own. No browser permits that — a page that could send a file from somebody's
 * WhatsApp to anybody it chose would be a worm — so the last taps are the
 * person's. What it does is get the PDF and the message to the point where
 * those taps are all that is left.
 *
 * On a phone that means: press this, tap WhatsApp in the share sheet, tap the
 * customer, send. On a desktop browser that cannot share files, the PDF is
 * saved and the customer's chat opens with the message typed, so the file is
 * attached from Downloads.
 */
export function ShareOnWhatsApp({
  sheet,
  shop,
  kind,
  number,
  date,
  mobile,
  text,
}: {
  sheet: RefObject<HTMLDivElement | null>;
  shop: string | null;
  kind: string;
  number?: string | null;
  date?: string | null;
  mobile?: string | null;
  text: string;
}) {
  const [busy, setBusy] = useState(false);

  const go = async () => {
    const node = sheet.current;
    if (!node) {
      toastError(new Error('The sheet is not ready yet'), 'Could not make the PDF');
      return;
    }
    setBusy(true);
    try {
      const blob = await sheetToPdf(node);
      const filename = docFilename({ shop, kind, number, date });
      const outcome = await shareDoc({ blob, filename, text, number: waNumber(mobile) });

      if (outcome === 'saved-and-opened') {
        toast({
          title: 'PDF saved, WhatsApp opening',
          description: `Attach "${filename}" from your Downloads — this browser cannot hand the file over by itself.`,
        });
      }
      // 'shared' needs no message: the share sheet is on their screen, and
      // 'cancelled' means they closed it, which they know.
    } catch (err) {
      // The one thing that realistically breaks the capture is an image on the
      // sheet the browser will not let a canvas read — the shop's uploaded
      // logo or signature. Being told "could not make the PDF" and left there
      // is useless when the bill still has to go out, so the text version goes
      // instead and says so.
      toastError(err, 'Could not make the PDF — sending the details as text instead');
      window.open(waChatLink(waNumber(mobile), text), '_blank', 'noopener,noreferrer');
    } finally {
      setBusy(false);
    }
  };

  return (
    <Button
      size="sm"
      variant="outline"
      onClick={go}
      disabled={busy}
      title={
        canShareFiles()
          ? `Send this ${kind} on WhatsApp as a PDF`
          : `Save this ${kind} as a PDF and open WhatsApp — attach it from Downloads`
      }
    >
      <MessageCircle /> {busy ? 'Making the PDF…' : 'WhatsApp'}
    </Button>
  );
}
