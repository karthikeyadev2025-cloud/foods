import { useQuery } from '@tanstack/react-query';
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Input } from '@/components/ui/input';
import { useDebounced } from '@/hooks/use-debounced';
import { cn } from '@/lib/utils';

export interface ComboboxProps<T> {
  id?: string;
  value: T | null;
  onChange: (v: T | null) => void;
  /** Server search; called with the debounced text. */
  search: (q: string) => Promise<T[]>;
  /** Cache key prefix for the search results. */
  queryKey: string;
  getKey: (t: T) => string;
  getLabel: (t: T) => string;
  renderOption?: (t: T) => ReactNode;
  placeholder?: string;
  autoFocus?: boolean;
  disabled?: boolean;
  className?: string;
  /** Called after a pick, e.g. to move focus to the next field. */
  onPicked?: (t: T) => void;
  /** Search as soon as the box is focused, even with no text. */
  eager?: boolean;
  /**
   * Offer to create what was typed, as the last entry in the list. Called with
   * the text as it stands — a picker that can only find things stops the work
   * dead the first time somebody needs something that is not there yet.
   */
  onCreate?: (text: string) => void;
  /** What that entry says, e.g. "New product". */
  createLabel?: string;
  'aria-label'?: string;
}

/**
 * Keyboard-first async combobox: type to search, ↑/↓ to move, Enter to pick,
 * Esc to close. Built on a plain input so it works with fast bill entry
 * (CODE → Tab → Boxes → Tab → Rate → Enter).
 */
export function Combobox<T>({
  id,
  value,
  onChange,
  search,
  queryKey,
  getKey,
  getLabel,
  renderOption,
  placeholder,
  autoFocus,
  disabled,
  className,
  onPicked,
  eager = false,
  onCreate,
  createLabel = 'New',
  'aria-label': ariaLabel,
}: ComboboxProps<T>) {
  const [text, setText] = useState(value ? getLabel(value) : '');
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const listId = useId();
  const wrap = useRef<HTMLDivElement>(null);
  /*
    Where to draw the list.

    It used to be positioned `absolute` inside this wrapper, which put it
    inside the line table — and every table in the app sits in a
    `overflow-auto` scroller (components/ui/table.tsx). An absolutely
    positioned child of a scroller is CLIPPED by it, so on the entry row at
    the foot of a bill the list was cut off after a line or two, or vanished
    entirely behind the table's edge. That is the "dropdown is hidden" the
    shop reported, and no amount of z-index fixes it: the box is not behind
    anything, it is being cut.

    So it is drawn in a portal on <body>, positioned `fixed` against the
    input's own rectangle, where nothing can clip it. It flips above the input
    when there is no room below, and follows the input while scrolling.
  */
  const [box, setBox] = useState<{ top: number; left: number; width: number; above: boolean } | null>(null);
  const q = useDebounced(text, 150);
  const active = open && (eager || q.trim().length > 0);

  const results = useQuery({
    queryKey: [queryKey, 'search', q],
    queryFn: () => search(q.trim()),
    enabled: active,
    staleTime: 15_000,
  });
  const options = active ? (results.data ?? []) : [];

  // Reflect external value changes (reset after adding a line, edit load).
  useEffect(() => {
    setText(value ? getLabel(value) : '');
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [value]);

  useEffect(() => {
    const onDoc = (e: MouseEvent) => {
      const target = e.target as Node;
      if (wrap.current?.contains(target)) return;
      // The list is drawn on <body> now, so a click on an option is no longer
      // "inside" this wrapper. Without this it would count as clicking away
      // and close the list out from under the pick.
      if (target instanceof Element && target.closest('[data-combobox-list]')) return;
      setOpen(false);
    };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, []);

  const place = useCallback(() => {
    const input = wrap.current?.querySelector('input');
    if (!input) return;
    const r = input.getBoundingClientRect();
    const below = window.innerHeight - r.bottom;
    const above = below < 280 && r.top > below;
    setBox({
      top: above ? r.top : r.bottom,
      left: r.left,
      // Never narrower than the input, and wide enough for a product name.
      width: Math.max(r.width, 320),
      above,
    });
  }, []);

  useLayoutEffect(() => {
    if (!open || !active) return;
    place();
    // `true` catches scrolling in the table's own scroller, not just the page.
    window.addEventListener('scroll', place, true);
    window.addEventListener('resize', place);
    return () => {
      window.removeEventListener('scroll', place, true);
      window.removeEventListener('resize', place);
    };
  }, [open, active, place, options.length]);

  const pick = (t: T) => {
    onChange(t);
    setText(getLabel(t));
    setOpen(false);
    onPicked?.(t);
  };

  const onKey = (e: KeyboardEvent<HTMLInputElement>) => {
    if (!open && (e.key === 'ArrowDown' || e.key === 'ArrowUp')) {
      setOpen(true);
      return;
    }
    if (!open) return;
    if (e.key === 'ArrowDown') {
      e.preventDefault();
      setHi((h) => Math.min(options.length - 1, h + 1));
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      setHi((h) => Math.max(0, h - 1));
    } else if (e.key === 'Enter') {
      const t = options[hi];
      if (t) {
        e.preventDefault();
        pick(t);
      }
    } else if (e.key === 'Escape') {
      setOpen(false);
    } else if (e.key === 'Tab') {
      // Tab with exactly one match picks it — fast entry never needs the mouse.
      if (options.length === 1 && options[0]) pick(options[0]);
    }
  };

  return (
    <div ref={wrap} className={cn('relative', className)}>
      <Input
        id={id}
        role="combobox"
        aria-expanded={open}
        aria-controls={listId}
        aria-autocomplete="list"
        aria-label={ariaLabel}
        autoComplete="off"
        placeholder={placeholder}
        autoFocus={autoFocus}
        disabled={disabled}
        value={text}
        onChange={(e) => {
          setText(e.target.value);
          setHi(0);
          setOpen(true);
          if (value) onChange(null);
        }}
        onFocus={() => {
          if (eager || text) setOpen(true);
        }}
        onKeyDown={onKey}
      />
      {open && active && box && createPortal(
        <ul
          id={listId}
          role="listbox"
          data-combobox-list
          style={{
            position: 'fixed',
            top: box.above ? undefined : box.top + 4,
            bottom: box.above ? window.innerHeight - box.top + 4 : undefined,
            left: box.left,
            width: box.width,
          }}
          className="z-[100] max-h-64 overflow-auto rounded-md border bg-popover p-1 text-sm shadow-lg"
        >
          {results.isLoading ? (
            <li className="px-2 py-1.5 text-muted-foreground">Searching…</li>
          ) : options.length === 0 ? (
            <li className="px-2 py-1.5 text-muted-foreground">No matches</li>
          ) : (
            options.map((t, i) => (
              <li
                key={getKey(t)}
                role="option"
                aria-selected={i === hi}
                className={cn('cursor-pointer rounded-sm px-2 py-1.5', i === hi && 'bg-accent text-accent-foreground')}
                onMouseEnter={() => setHi(i)}
                onMouseDown={(e) => {
                  e.preventDefault();
                  pick(t);
                }}
              >
                {renderOption ? renderOption(t) : getLabel(t)}
              </li>
            ))
          )}
          {/*
            Deliberately NOT one of the options: it is not keyboard-highlighted
            and Enter never lands on it, so fast entry — code, Tab, boxes — can
            never create a product by accident.
          */}
          {onCreate && !results.isLoading && (
            <li
              className="mt-1 cursor-pointer rounded-sm border-t px-2 py-1.5 pt-2 text-primary"
              onMouseDown={(ev) => {
                ev.preventDefault();
                setOpen(false);
                onCreate(text);
              }}
            >
              + {createLabel}
              {text.trim() ? <span className="text-muted-foreground"> — “{text.trim()}”</span> : null}
            </li>
          )}
        </ul>,
        document.body,
      )}
    </div>
  );
}
