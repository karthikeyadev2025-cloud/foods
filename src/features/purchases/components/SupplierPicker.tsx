import { useState, type ReactNode } from 'react';
import { Combobox } from '@/components/Combobox';
import { usePermissions } from '@/features/auth/hooks';
import { searchSuppliers, type SupplierRow } from '../api';
import { NewSupplierDialog } from './NewSupplierDialog';

/** The supplier box, with "+ New supplier" built in. See CustomerPicker. */
export function SupplierPicker({
  id,
  value,
  onChange,
  placeholder = 'Supplier…',
  autoFocus,
  disabled,
  eager = true,
  onPicked,
  renderOption,
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
  renderOption?: (s: SupplierRow) => ReactNode;
  'aria-label'?: string;
}) {
  const [newName, setNewName] = useState<string | null>(null);
  // Suppliers are owned by the purchases module, not by one of their own.
  const canCreate = usePermissions().canEdit('purchases');

  return (
    <>
      <Combobox<SupplierRow>
        id={id}
        value={value}
        onChange={onChange}
        search={searchSuppliers}
        queryKey="suppliers"
        getKey={(s) => s.id ?? ''}
        getLabel={(s) => s.name ?? ''}
        renderOption={renderOption ?? ((s) => (
          <span>
            <span className="font-medium">{s.name}</span>
            <span className="text-muted-foreground">
              {s.town ? ` · ${s.town}` : ''}
              {s.mobile1 ? ` · ${s.mobile1}` : ''}
            </span>
          </span>
        ))}
        placeholder={placeholder}
        autoFocus={autoFocus}
        disabled={disabled}
        eager={eager}
        onPicked={onPicked}
        aria-label={ariaLabel}
        onCreate={!disabled && canCreate ? (t) => setNewName(t) : undefined}
        createLabel="New supplier"
      />
      <NewSupplierDialog
        open={newName !== null}
        initialName={newName ?? ''}
        onClose={() => setNewName(null)}
        onCreated={(s) => {
          onChange(s);
          onPicked?.(s);
        }}
      />
    </>
  );
}
