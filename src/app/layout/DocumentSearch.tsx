import { useQuery } from '@tanstack/react-query';
import { Search } from 'lucide-react';
import { useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { Input } from '@/components/ui/input';
import { Spinner } from '@/components/Spinner';
import { kindHref, kindLabel, searchDocuments, type DocumentHit } from '@/features/search/api';
import { useDebounced } from '@/hooks/use-debounced';
import { amount, dateDMY } from '@/lib/format';

/**
 * One search box, in the header, across every kind of bill.
 *
 * The case it exists for: a customer rings and says "number 41", and nobody
 * knows whether that is an invoice, a challan, a receipt or a quotation. Each
 * screen's own search box only ever knew its own kind, so the office opened
 * four screens to find out.
 *
 * Results are whatever the caller's role and plan already let them open, so a
 * hit is never a door that then refuses to open.
 */
export function DocumentSearch() {
  const navigate = useNavigate();
  const [text, setText] = useState('');
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const boxRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const term = useDebounced(text, 200);

  const hits = useQuery({
    queryKey: ['doc-search', term],
    queryFn: () => searchDocuments(term),
    enabled: term.trim().length > 0,
  });
  const rows: DocumentHit[] = hits.data ?? [];

  // Ctrl+K from anywhere. Deliberately not "/" alone — this app is nothing but
  // text boxes, and stealing a printable character would be maddening.
  useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      if ((ev.ctrlKey || ev.metaKey) && ev.key.toLowerCase() === 'k') {
        ev.preventDefault();
        inputRef.current?.focus();
        inputRef.current?.select();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);

  useEffect(() => {
    const onClick = (ev: MouseEvent) => {
      if (!boxRef.current?.contains(ev.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onClick);
    return () => document.removeEventListener('mousedown', onClick);
  }, []);

  useEffect(() => setActive(0), [term]);

  const go = (hit: DocumentHit) => {
    setOpen(false);
    setText('');
    navigate(kindHref(hit.kind, hit.doc_id, hit.party));
  };

  const onKeyDown = (ev: React.KeyboardEvent) => {
    if (ev.key === 'Escape') {
      setOpen(false);
      inputRef.current?.blur();
      return;
    }
    if (!rows.length) return;
    if (ev.key === 'ArrowDown') {
      ev.preventDefault();
      setActive((i) => (i + 1) % rows.length);
    } else if (ev.key === 'ArrowUp') {
      ev.preventDefault();
      setActive((i) => (i - 1 + rows.length) % rows.length);
    } else if (ev.key === 'Enter') {
      ev.preventDefault();
      const hit = rows[active];
      if (hit) go(hit);
    }
  };

  const showPanel = open && term.trim().length > 0;

  return (
    <div ref={boxRef} className="relative w-full max-w-md">
      <Search className="pointer-events-none absolute left-2 top-1/2 h-4 w-4 -translate-y-1/2 text-muted-foreground" aria-hidden />
      <Input
        ref={inputRef}
        className="h-8 pl-8"
        placeholder="Search anything — customer, supplier, product, bill"
        aria-label="Search all bills"
        value={text}
        onChange={(ev) => {
          setText(ev.target.value);
          setOpen(true);
        }}
        onFocus={() => setOpen(true)}
        onKeyDown={onKeyDown}
      />

      {showPanel && (
        <div className="absolute z-50 mt-1 max-h-96 w-full overflow-y-auto rounded-md border bg-card shadow-lg" role="listbox">
          {hits.isLoading ? (
            <div className="p-3"><Spinner /></div>
          ) : hits.error ? (
            <p role="alert" className="p-3 text-sm text-destructive">{(hits.error as Error).message}</p>
          ) : !rows.length ? (
            <p className="p-3 text-sm text-muted-foreground">
              Nothing found for “{term}”. You can search for a customer, supplier, product or member of staff, or for
              any bill by its number, phone, town, item, amount, vehicle, cheque number or notes.
            </p>
          ) : (
            rows.map((hit, i) => (
              <button
                key={`${hit.kind}-${hit.doc_id}`}
                type="button"
                role="option"
                aria-selected={i === active}
                className={`flex w-full items-center gap-3 border-b px-3 py-2 text-left text-sm last:border-b-0 ${i === active ? 'bg-accent' : 'hover:bg-accent'}`}
                onMouseEnter={() => setActive(i)}
                onClick={() => go(hit)}
              >
                <span className="w-24 shrink-0 text-xs uppercase tracking-wide text-muted-foreground">{kindLabel(hit.kind)}</span>
                <span className="w-20 shrink-0 font-medium">{hit.doc_no}</span>
                <span className="min-w-0 flex-1 truncate">
                  {hit.party ?? '—'}
                  {hit.town && <span className="text-muted-foreground"> · {hit.town}</span>}
                </span>
                <span className="shrink-0 text-xs text-muted-foreground">{hit.doc_date ? dateDMY(hit.doc_date) : (hit.state ?? '')}</span>
                <span className="w-24 shrink-0 text-right tabular-nums">{hit.amount == null ? '' : amount(hit.amount)}</span>
              </button>
            ))
          )}
        </div>
      )}
    </div>
  );
}
