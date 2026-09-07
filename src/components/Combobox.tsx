import { useQuery } from '@tanstack/react-query';
import { useEffect, useId, useRef, useState, type KeyboardEvent, type ReactNode } from 'react';
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
  'aria-label': ariaLabel,
}: ComboboxProps<T>) {
  const [text, setText] = useState(value ? getLabel(value) : '');
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const listId = useId();
  const wrap = useRef<HTMLDivElement>(null);
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
      if (wrap.current && !wrap.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('mousedown', onDoc);
    return () => document.removeEventListener('mousedown', onDoc);
  }, []);

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
      {open && active && (
        <ul
          id={listId}
          role="listbox"
          className="absolute z-40 mt-1 max-h-64 w-full min-w-[20rem] overflow-auto rounded-md border bg-popover p-1 text-sm shadow-md"
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
        </ul>
      )}
    </div>
  );
}
