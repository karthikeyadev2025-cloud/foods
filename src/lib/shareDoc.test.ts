import { afterEach, describe, expect, it, vi } from 'vitest';
import { canShareFiles, docFilename, shareDoc, waChatLink } from './shareDoc';

/**
 * The decision this file makes is which of two different things to do, and
 * getting it wrong is silent: the shopkeeper either gets the PDF or does not,
 * and nothing on the screen would say which.
 */

const PDF = () => new Blob(['%PDF-1.4 fake'], { type: 'application/pdf' });

function withNavigator(nav: Partial<Navigator> & Record<string, unknown>) {
  vi.stubGlobal('navigator', nav);
}

afterEach(() => {
  vi.unstubAllGlobals();
  vi.restoreAllMocks();
});

describe('can this browser share a file', () => {
  it('no, when the browser has no share at all (most desktops)', () => {
    withNavigator({});
    expect(canShareFiles()).toBe(false);
  });

  it('no, when it can share but not files (older Android)', () => {
    withNavigator({ share: vi.fn(), canShare: () => false });
    expect(canShareFiles()).toBe(false);
  });

  it('no, when canShare throws rather than answering', () => {
    withNavigator({ share: vi.fn(), canShare: () => { throw new Error('nope'); } });
    expect(canShareFiles()).toBe(false);
  });

  it('yes, when it can take files', () => {
    withNavigator({ share: vi.fn(), canShare: () => true });
    expect(canShareFiles()).toBe(true);
  });
});

describe('what actually happens', () => {
  it('shares the file where the browser can — the PDF is the point', async () => {
    const share = vi.fn().mockResolvedValue(undefined);
    withNavigator({ share, canShare: () => true });
    const open = vi.fn();

    const out = await shareDoc({ blob: PDF(), filename: 'bill.pdf', text: 'Bill 0041', number: '919849686746', open });

    expect(out).toBe('shared');
    expect(share).toHaveBeenCalledOnce();
    const arg = share.mock.calls[0]?.[0] as { files: File[]; text: string };
    expect(arg.files[0]?.name).toBe('bill.pdf');
    expect(arg.files[0]?.type).toBe('application/pdf');
    expect(arg.text).toBe('Bill 0041');
    // and it must NOT also download the file and open a chat
    expect(open).not.toHaveBeenCalled();
  });

  it('does nothing further when the person closes the share sheet', async () => {
    const abort = Object.assign(new Error('cancelled'), { name: 'AbortError' });
    withNavigator({ share: vi.fn().mockRejectedValue(abort), canShare: () => true });
    const open = vi.fn();

    const save = vi.fn();
    const out = await shareDoc({ blob: PDF(), filename: 'bill.pdf', text: 'Bill 0041', open, save });

    expect(out).toBe('cancelled');
    expect(save).not.toHaveBeenCalled();
    // Declining to send is a decision. Downloading the file anyway would leave
    // a bill in Downloads that they chose not to send.
    expect(open).not.toHaveBeenCalled();
  });

  it('saves the PDF and opens the chat where files cannot be shared', async () => {
    withNavigator({});
    const open = vi.fn();

    const save = vi.fn();
    const out = await shareDoc({ blob: PDF(), filename: 'bill.pdf', text: 'Bill 0041', number: '919849686746', open, save });

    expect(out).toBe('saved-and-opened');
    // the PDF is written out under the name the shop will look for...
    expect(save).toHaveBeenCalledOnce();
    expect(save.mock.calls[0]?.[1]).toBe('bill.pdf');
    // ...and the customer's own chat is opened with the message ready
    expect(open).toHaveBeenCalledOnce();
    expect(open.mock.calls[0]?.[0]).toContain('https://wa.me/919849686746?text=');
  });

  it('falls back when a browser claims it can share and then will not', async () => {
    withNavigator({ share: vi.fn().mockRejectedValue(new Error('NotAllowedError')), canShare: () => true });
    const open = vi.fn();

    const save = vi.fn();
    const out = await shareDoc({ blob: PDF(), filename: 'bill.pdf', text: 'Bill 0041', open, save });

    expect(out).toBe('saved-and-opened');
    expect(save).toHaveBeenCalledOnce();
    expect(open).toHaveBeenCalledOnce();
  });
});

describe('the chat link', () => {
  it('opens the customer when the number is known', () => {
    expect(waChatLink('919849686746', 'hello')).toBe('https://wa.me/919849686746?text=hello');
  });

  it('opens WhatsApp with no recipient when it is not', () => {
    expect(waChatLink(null, 'hello')).toBe('https://wa.me/?text=hello');
  });
});

describe('the filename', () => {
  it('is findable in a phone Downloads list weeks later', () => {
    expect(docFilename({ shop: 'JYOTHI FOODS', kind: 'invoice', number: '0041', date: '2026-11-17' }))
      .toBe('jyothi-foods-invoice-0041-2026-11-17.pdf');
  });

  it('copes with whatever the shop is called', () => {
    expect(docFilename({ shop: 'M/s. Ravi & Co.', kind: 'quotation', number: 'Q-7' }))
      .toBe('m-s-ravi-co-quotation-q-7.pdf');
  });

  it('never produces a nameless file', () => {
    expect(docFilename({ kind: '' })).toBe('document.pdf');
    expect(docFilename({ shop: null, kind: 'invoice', number: null, date: null })).toBe('invoice.pdf');
  });
});
