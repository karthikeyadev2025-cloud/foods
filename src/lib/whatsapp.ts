/**
 * Sending a bill on WhatsApp from the person's own phone.
 *
 * This is NOT the messaging module. That one queues a message through the
 * shop's WhatsApp Business sender, which needs the Full plan, a provider key,
 * the customer's opt-in and a message credit — and sends it by itself, later.
 * This is the thing the counter actually asked for: the bill is saved, the
 * shopkeeper is standing there, and the biller wants to hand it over now, from
 * the phone in his hand. It opens WhatsApp with the message already typed and
 * he presses send.
 *
 * Which means it costs nothing, works on Starter, needs no opt-in and no
 * provider — and it is his own WhatsApp account, not the shop's sender, so
 * the reply comes back to him.
 *
 * It carries TEXT, not the PDF: wa.me takes a message and nothing else. The
 * text therefore has to be the bill rather than a note about one, which is why
 * the lines are in it.
 */

/** Rupees as they are written on a bill: 12,480.00 */
function rupees(n: number): string {
  return new Intl.NumberFormat('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(n);
}

/**
 * A mobile number as wa.me wants it: country code, digits only, no plus.
 *
 * The database keeps the last ten digits (normalize_mobile in db/13) because
 * that is what identifies an Indian customer however it was typed. WhatsApp
 * needs the country code on the front, so ten digits get 91. A number that
 * already carries a code — 91…, 0091…, +91… — is left with the one it has,
 * and anything that is not a plausible number at all comes back null so the
 * button can be disabled instead of opening a chat with nobody.
 */
export function waNumber(mobile: string | null | undefined): string | null {
  const digits = (mobile ?? '').replace(/\D/g, '');
  if (!digits) return null;
  // 0091xxxxxxxxxx and 091xxxxxxxxxx — the way a landline habit writes it
  const trimmed = digits.replace(/^0+/, '');
  if (trimmed.length === 10) return `91${trimmed}`;
  // 91 + ten digits, or another country's code and number
  if (trimmed.length >= 11 && trimmed.length <= 15) return trimmed;
  return null;
}

export interface BillLine {
  code: string;
  name: string;
  boxes: number;
  rate: number;
  amount: number;
}

export interface BillMessage {
  orgName: string;
  orgPhone?: string | null;
  customerName: string;
  invoiceNo: string;
  invoiceDate: string;
  lines: BillLine[];
  total: number;
  received?: number;
  balance?: number;
  /** A draft is not a bill yet, and must not be sent as one. */
  isProforma?: boolean;
  note?: string | null;
}

/** How many lines go in the message before it is summarised instead. */
const MAX_LINES = 40;

/**
 * The bill as a WhatsApp message.
 *
 * Deliberately plain text with no formatting characters beyond a newline:
 * WhatsApp's own asterisks-for-bold are fine in a chat but they come out as
 * literal asterisks when the shop copies the text somewhere else, and a bill
 * is the last thing to be clever with.
 */
export function billMessage(b: BillMessage): string {
  const out: string[] = [];
  out.push(b.orgName);
  out.push(`${b.isProforma ? 'Estimate' : 'Bill'} ${b.invoiceNo} dated ${b.invoiceDate}`);
  out.push('');

  const shown = b.lines.slice(0, MAX_LINES);
  for (const l of shown) {
    const name = [l.code, l.name].filter(Boolean).join(' ');
    out.push(`${name} - ${l.boxes} box x ${rupees(l.rate)} = ${rupees(l.amount)}`);
  }
  if (b.lines.length > shown.length) {
    out.push(`... and ${b.lines.length - shown.length} more items`);
  }

  out.push('');
  out.push(`Total Rs ${rupees(b.total)}`);
  // Only worth saying when there is something to say: a bill paid in full on
  // the spot does not need two more lines about it.
  if (b.received !== undefined && b.received > 0) out.push(`Received Rs ${rupees(b.received)}`);
  if (b.balance !== undefined && b.balance > 0) out.push(`Balance Rs ${rupees(b.balance)}`);

  if (b.note) {
    out.push('');
    out.push(b.note);
  }
  out.push('');
  out.push(`Thank you, ${b.customerName}.`);
  if (b.orgPhone) out.push(b.orgName + ' - ' + b.orgPhone);

  return out.join('\n');
}

/**
 * The link that opens WhatsApp with the message ready to send.
 *
 * wa.me rather than api.whatsapp.com: it is the one that works both in the
 * phone app and in WhatsApp Web without the browser asking which to use.
 */
export function waLink(number: string, text: string): string {
  return `https://wa.me/${number}?text=${encodeURIComponent(text)}`;
}
