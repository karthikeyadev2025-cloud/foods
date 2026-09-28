import { useMemo, useState } from 'react';
import { Combobox } from '@/components/Combobox';
import { usePermissions } from '@/features/auth/hooks';
import { amount } from '@/lib/format';
import { type SupplierRow } from '../api';
import { searchParties, type PartyOption } from '../parties';
import { NewSupplierDialog } from './NewSupplierDialog';

/**
 * The party box on every purchase screen, with "+ New supplier" built in — and
 * searching the CUSTOMERS list as well, because the shop buys from and sells to
 * the same people ("they done both supply and purchase").
 *
 * A supplier goes straight onto the bill. A customer is offered as somebody to
 * add as a supplier, pre-filled from what is already known about them: a
 * purchase posts to the payable ledger, and a payable needs a supplier row to
 * hang off. One click, and no name re-typed into a second spelling.
 */
export function SupplierPicker({
  id,
  value,
  onChange,
  placeholder = 'Supplier or customer name…',
  autoFocus,
  disabled,
  eager = true,
  onPicked,
  'aria-label': ariaLabel,
}: {
  id?: string;
  value: SupplierRow | null;
  onChange: (s: SupplierRow | null) => void;
  placeholder?: string;
  autoFocus?: boolean;
  disabled?: boolean;
  eager?: boolean;
  onPicked?: (s: SupplierRow) => void;
  'aria-label'?: string;
}) {
  // null = closed. '' is a real state: "new supplier, nothing typed yet".
  const [newName, setNewName] = useState<string | null>(null);
  // The customer being turned into a supplier, if that is how this started.
  const [fromCustomer, setFromCustomer] = useState<PartyOption['customer']>(null);
  // Suppliers are owned by the purchases module, not by one of their own.
  const canCreate = usePermissions().canEdit('purchases');

  const selected = useMemo<PartyOption | null>(
    () =>
      value
        ? {
            key: `s:${value.id}`,
            kind: 'supplier',
            supplier: value,
            customer: null,
            name: value.name ?? '',
            town: value.town ?? null,
            mobile1: value.mobile1 ?? null,
            payable: Number(value.payable ?? 0),
          }
        : null,
    [value],
  );

  const open = (name: string, customer: PartyOption['customer']) => {
    setFromCustomer(customer);
    setNewName(name);
  };

  return (
    <>
      <Combobox<PartyOption>
        id={id}
        // The box shows the chosen supplier; the option list is the wider
        // search. Memoised because the combobox re-reads its text whenever this
        // changes identity, and a fresh object every render would fight the
        // typing on a screen that re-renders on every keystroke.
        value={selected}
        onChange={(p) => {
          if (!p) return onChange(null);
          // A customer is not a supplier yet, so nothing is put on the bill
          // until the dialog has made one.
          if (p.kind === 'customer') return open(p.name, p.customer);
          onChange(p.supplier);
          if (p.supplier) onPicked?.(p.supplier);
        }}
        search={searchParties}
        queryKey="purchase-parties"
        getKey={(p) => p.key}
        getLabel={(p) => p.name}
        renderOption={(p) => (
          <span>
            <span className="font-medium">{p.name}</span>
            <span className="text-muted-foreground">
              {p.town ? ` · ${p.town}` : ''}
              {p.kind === 'supplier' ? ` · payable ₹${amount(p.payable)}` : ''}
            </span>
            {p.kind === 'customer' && (
              <span className="ml-1 rounded-sm bg-muted px-1 text-xs text-muted-foreground">customer — add as supplier</span>
            )}
          </span>
        )}
        placeholder={placeholder}
        autoFocus={autoFocus}
        disabled={disabled}
        eager={eager}
        aria-label={ariaLabel}
        onCreate={!disabled && canCreate ? (t) => open(t, null) : undefined}
        createLabel="New supplier"
      />
      <NewSupplierDialog
        open={newName !== null}
        initialName={newName ?? ''}
        from={fromCustomer ? { name: fromCustomer.name ?? '', mobile1: fromCustomer.mobile1 ?? null, town: fromCustomer.town ?? null } : null}
        onClose={() => {
          setNewName(null);
          setFromCustomer(null);
        }}
        onCreated={(s) => {
          onChange(s);
          onPicked?.(s);
        }}
      />
    </>
  );
}
