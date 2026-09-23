import { useState, type ReactNode } from 'react';
import { Combobox } from '@/components/Combobox';
import { usePermissions } from '@/features/auth/hooks';
import { searchCustomers, type CustomerRow } from '../api';
import { NewCustomerDialog } from './NewCustomerDialog';

/**
 * The customer box, with "+ New customer" built in.
 *
 * Eight screens were each repeating the same six props to the combobox, which
 * meant eight places to remember when the create option was added and eight
 * chances to forget one. The search, the label and the permission check live
 * here now; a screen passes what is different about it.
 */
export function CustomerPicker({
  id,
  value,
  onChange,
  placeholder = 'Type name, mobile or town…',
  autoFocus,
  disabled,
  eager = true,
  onPicked,
  renderOption,
  'aria-label': ariaLabel,
}: {
  id?: string;
  value: CustomerRow | null;
  onChange: (c: CustomerRow | null) => void;
  placeholder?: string;
  autoFocus?: boolean;
  disabled?: boolean;
  eager?: boolean;
  onPicked?: (c: CustomerRow) => void;
  renderOption?: (c: CustomerRow) => ReactNode;
  'aria-label'?: string;
}) {
  // null = closed. '' is a real state: "new customer, nothing typed yet".
  const [newName, setNewName] = useState<string | null>(null);
  const canCreate = usePermissions().canEdit('customers');

  return (
    <>
      <Combobox<CustomerRow>
        id={id}
        value={value}
        onChange={onChange}
        search={searchCustomers}
        queryKey="customers"
        getKey={(c) => c.id ?? ''}
        getLabel={(c) => `${c.name ?? ''}${c.town ? ` — ${c.town}` : ''}`}
        renderOption={renderOption ?? ((c) => (
          <span>
            <span className="font-medium">{c.name}</span>
            <span className="text-muted-foreground">
              {c.town ? ` · ${c.town}` : ''}
              {c.mobile1 ? ` · ${c.mobile1}` : ''}
            </span>
          </span>
        ))}
        placeholder={placeholder}
        autoFocus={autoFocus}
        disabled={disabled}
        eager={eager}
        onPicked={onPicked}
        aria-label={ariaLabel}
        // A screen that cannot be edited cannot create either — the option
        // would open a dialog whose save the database would refuse.
        onCreate={!disabled && canCreate ? (t) => setNewName(t) : undefined}
        createLabel="New customer"
      />
      <NewCustomerDialog
        open={newName !== null}
        initialName={newName ?? ''}
        onClose={() => setNewName(null)}
        onCreated={(c) => {
          onChange(c);
          onPicked?.(c);
        }}
      />
    </>
  );
}
