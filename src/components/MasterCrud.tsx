import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ArrowDown, ArrowUp, Download, GripVertical, Pencil, Plus, Sparkles, Trash2 } from 'lucide-react';
import { useMemo, useState, type ReactNode } from 'react';
import { useForm, type DefaultValues, type FieldValues, type Path } from 'react-hook-form';
import type { ZodType, ZodTypeDef } from 'zod';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { Textarea } from '@/components/ui/textarea';
import { toast, toastError } from '@/hooks/use-toast';
import { exportToExcel } from '@/lib/export';
import { cn } from '@/lib/utils';

export interface Option {
  value: string;
  label: string;
}

export interface FieldDef<F extends FieldValues> {
  name: Path<F>;
  label: string;
  type?: 'text' | 'number' | 'checkbox' | 'select' | 'textarea';
  options?: readonly Option[];
  placeholder?: string;
  help?: string;
  step?: string | number;
  /** Render at half width so two short fields share a row. */
  half?: boolean;
  autoFocus?: boolean;
  /** Read-only when editing an existing row (e.g. a natural key). */
  lockOnEdit?: boolean;
}

export interface ColumnDef<R> {
  key: string;
  label: string;
  render?: (row: R) => ReactNode;
  align?: 'left' | 'right';
  exportValue?: (row: R) => string | number | boolean | null;
}

export interface MasterConfig<R extends { id: string }, F extends FieldValues> {
  /** Query-cache key, unique per table. */
  key: string;
  title: string;
  singular: string;
  description?: ReactNode;
  exportName: string;
  columns: ColumnDef<R>[];
  fields: FieldDef<F>[];
  schema: ZodType<F, ZodTypeDef, F>;
  defaults: DefaultValues<F>;
  toForm: (row: R) => DefaultValues<F>;
  rowLabel: (row: R) => string;
  list: () => Promise<R[]>;
  create: (values: F) => Promise<unknown>;
  update: (id: string, values: F) => Promise<unknown>;
  remove?: (id: string) => Promise<unknown>;
  /** "Add the standard set" — rows the client can accept in one click and then edit. */
  suggestions?: { label: string; rows: F[]; isPresent: (existing: R[], suggested: F) => boolean };
  /** Drag (or arrow) to reorder; receives every row id in the new order. Shown only when the list is unfiltered. */
  reorder?: (ids: string[]) => Promise<unknown>;
  canEdit: boolean;
  canDelete: boolean;
}

const masterQueryKey = (key: string) => ['setup', key] as const;

function cellValue<R>(row: R, key: string): unknown {
  return (row as Record<string, unknown>)[key];
}

function defaultRender(v: unknown): ReactNode {
  if (v === null || v === undefined) return <span className="text-muted-foreground">—</span>;
  if (typeof v === 'boolean') return v ? 'Yes' : 'No';
  return String(v);
}

/**
 * List + search + Excel export + create/edit dialog + delete, driven entirely by
 * a MasterConfig. Every Setup lookup uses this so they all behave the same.
 */
export function MasterCrud<R extends { id: string }, F extends FieldValues>({
  config,
  compact = false,
}: {
  config: MasterConfig<R, F>;
  compact?: boolean;
}) {
  const queryClient = useQueryClient();
  const queryKey = masterQueryKey(config.key);
  const rows = useQuery({ queryKey, queryFn: config.list });
  const [search, setSearch] = useState('');
  const [editing, setEditing] = useState<{ mode: 'create' } | { mode: 'edit'; row: R } | null>(null);
  const [deleting, setDeleting] = useState<R | null>(null);
  const [dragging, setDragging] = useState<string | null>(null);

  const invalidate = () => queryClient.invalidateQueries({ queryKey });

  const reorder = useMutation({
    mutationFn: async (ids: string[]) => {
      if (!config.reorder) return;
      await config.reorder(ids);
    },
    onSuccess: () => invalidate(),
    onError: (err) => toastError(err, 'Could not reorder'),
  });

  const moveRow = (fromId: string, toIndex: number) => {
    const ids = (rows.data ?? []).map((r) => r.id);
    const from = ids.indexOf(fromId);
    if (from < 0 || toIndex < 0 || toIndex >= ids.length || from === toIndex) return;
    ids.splice(toIndex, 0, ids.splice(from, 1)[0] as string);
    reorder.mutate(ids);
  };

  const save = useMutation({
    mutationFn: async (values: F) => {
      if (editing?.mode === 'edit') return config.update(editing.row.id, values);
      return config.create(values);
    },
    onSuccess: async () => {
      await invalidate();
      toast({ title: `${config.singular} saved` });
      setEditing(null);
    },
    onError: (err) => toastError(err, `Could not save ${config.singular.toLowerCase()}`),
  });

  const remove = useMutation({
    mutationFn: async (row: R) => {
      if (!config.remove) throw new Error('Delete is not available here');
      return config.remove(row.id);
    },
    onSuccess: async () => {
      await invalidate();
      toast({ title: `${config.singular} deleted` });
      setDeleting(null);
    },
    onError: (err) => toastError(err, `Could not delete ${config.singular.toLowerCase()}`),
  });

  const addSuggestions = useMutation({
    mutationFn: async () => {
      const s = config.suggestions;
      if (!s) return 0;
      const existing = rows.data ?? [];
      const missing = s.rows.filter((r) => !s.isPresent(existing, r));
      for (const r of missing) await config.create(r);
      return missing.length;
    },
    onSuccess: async (n) => {
      await invalidate();
      toast({ title: n ? `${n} added` : 'Nothing to add', description: n ? undefined : 'All standard rows already exist.' });
    },
    onError: (err) => toastError(err, 'Could not add the standard rows'),
  });

  const filtered = useMemo(() => {
    const all = rows.data ?? [];
    const q = search.trim().toLowerCase();
    if (!q) return all;
    return all.filter((row) =>
      config.columns.some((c) => {
        const v = c.exportValue ? c.exportValue(row) : cellValue(row, c.key);
        return v !== null && v !== undefined && String(v).toLowerCase().includes(q);
      }),
    );
  }, [rows.data, search, config.columns]);

  const canReorder = Boolean(config.reorder) && config.canEdit && search.trim() === '';

  const onExport = () => {
    const data = filtered.map((row) => {
      const out: Record<string, unknown> = {};
      for (const c of config.columns) out[c.label] = c.exportValue ? c.exportValue(row) : cellValue(row, c.key);
      return out;
    });
    exportToExcel(config.exportName, data, config.title);
  };

  return (
    <section aria-labelledby={`${config.key}-title`} className="space-y-3">
      <div className="flex flex-wrap items-end justify-between gap-2">
        <div>
          <h2 id={`${config.key}-title`} className={cn('font-semibold', compact ? 'text-base' : 'text-lg')}>
            {config.title}
          </h2>
          {config.description && <p className="max-w-2xl text-sm text-muted-foreground">{config.description}</p>}
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Input
            type="search"
            placeholder="Search…"
            aria-label={`Search ${config.title.toLowerCase()}`}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            className="h-8 w-44"
          />
          <Button variant="outline" size="sm" onClick={onExport} disabled={!filtered.length}>
            <Download /> Excel
          </Button>
          {config.suggestions && config.canEdit && (
            <Button
              variant="secondary"
              size="sm"
              onClick={() => addSuggestions.mutate()}
              disabled={addSuggestions.isPending || rows.isLoading}
            >
              <Sparkles /> {config.suggestions.label}
            </Button>
          )}
          {config.canEdit && (
            <Button size="sm" onClick={() => setEditing({ mode: 'create' })}>
              <Plus /> Add {config.singular.toLowerCase()}
            </Button>
          )}
        </div>
      </div>

      {rows.isLoading ? (
        <Spinner />
      ) : rows.error ? (
        <p role="alert" className="text-sm text-destructive">
          Could not load {config.title.toLowerCase()}: {rows.error.message}
        </p>
      ) : filtered.length === 0 ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">
          {search ? 'No rows match your search.' : `No ${config.title.toLowerCase()} yet.`}
        </p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                {canReorder && <TableHead className="w-20">Order</TableHead>}
                {config.columns.map((c) => (
                  <TableHead key={c.key} className={cn(c.align === 'right' && 'text-right')}>
                    {c.label}
                  </TableHead>
                ))}
                {(config.canEdit || config.canDelete) && <TableHead className="w-24 text-right">Actions</TableHead>}
              </TableRow>
            </TableHeader>
            <TableBody>
              {filtered.map((row, index) => (
                <TableRow
                  key={row.id}
                  draggable={canReorder}
                  onDragStart={canReorder ? () => setDragging(row.id) : undefined}
                  onDragOver={canReorder ? (e) => e.preventDefault() : undefined}
                  onDrop={
                    canReorder
                      ? () => {
                          if (dragging) moveRow(dragging, index);
                          setDragging(null);
                        }
                      : undefined
                  }
                  className={cn(dragging === row.id && 'opacity-50')}
                >
                  {canReorder && (
                    <TableCell className="whitespace-nowrap">
                      <span className="inline-flex items-center gap-0.5">
                        <GripVertical className="h-4 w-4 cursor-grab text-muted-foreground" aria-hidden />
                        <Button variant="ghost" size="icon" className="h-6 w-6" aria-label="Move up" disabled={index === 0 || reorder.isPending} onClick={() => moveRow(row.id, index - 1)}>
                          <ArrowUp className="h-3 w-3" />
                        </Button>
                        <Button variant="ghost" size="icon" className="h-6 w-6" aria-label="Move down" disabled={index === filtered.length - 1 || reorder.isPending} onClick={() => moveRow(row.id, index + 1)}>
                          <ArrowDown className="h-3 w-3" />
                        </Button>
                      </span>
                    </TableCell>
                  )}
                  {config.columns.map((c) => (
                    <TableCell key={c.key} className={cn(c.align === 'right' && 'num')}>
                      {c.render ? c.render(row) : defaultRender(cellValue(row, c.key))}
                    </TableCell>
                  ))}
                  {(config.canEdit || config.canDelete) && (
                    <TableCell className="text-right">
                      {config.canEdit && (
                        <Button
                          variant="ghost"
                          size="icon"
                          aria-label={`Edit ${config.rowLabel(row)}`}
                          onClick={() => setEditing({ mode: 'edit', row })}
                        >
                          <Pencil />
                        </Button>
                      )}
                      {config.canDelete && config.remove && (
                        <Button
                          variant="ghost"
                          size="icon"
                          aria-label={`Delete ${config.rowLabel(row)}`}
                          onClick={() => setDeleting(row)}
                        >
                          <Trash2 className="text-destructive" />
                        </Button>
                      )}
                    </TableCell>
                  )}
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {editing && (
        <MasterForm
          key={editing.mode === 'edit' ? editing.row.id : 'create'}
          config={config}
          initial={editing.mode === 'edit' ? config.toForm(editing.row) : config.defaults}
          isEdit={editing.mode === 'edit'}
          pending={save.isPending}
          onCancel={() => setEditing(null)}
          onSubmit={(v) => save.mutate(v)}
        />
      )}

      <Dialog open={deleting !== null} onOpenChange={(o) => !o && setDeleting(null)}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Delete {config.singular.toLowerCase()}?</DialogTitle>
            <DialogDescription>
              {deleting ? config.rowLabel(deleting) : ''} will be removed. Rows already used by a transaction cannot be
              deleted; deactivate them instead.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setDeleting(null)}>
              Cancel
            </Button>
            <Button variant="destructive" disabled={remove.isPending} onClick={() => deleting && remove.mutate(deleting)}>
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </section>
  );
}

function MasterForm<R extends { id: string }, F extends FieldValues>({
  config,
  initial,
  isEdit,
  pending,
  onCancel,
  onSubmit,
}: {
  config: MasterConfig<R, F>;
  initial: DefaultValues<F>;
  isEdit: boolean;
  pending: boolean;
  onCancel: () => void;
  onSubmit: (values: F) => void;
}) {
  const form = useForm<F>({ resolver: zodResolver(config.schema), defaultValues: initial });
  const errors = form.formState.errors;

  return (
    <Dialog open onOpenChange={(o) => !o && onCancel()}>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>
            {isEdit ? 'Edit' : 'New'} {config.singular.toLowerCase()}
          </DialogTitle>
        </DialogHeader>
        <form onSubmit={form.handleSubmit(onSubmit)} className="grid grid-cols-2 gap-3" noValidate>
          {config.fields.map((f) => {
            const id = `${config.key}-${f.name}`;
            const err = errors[f.name]?.message;
            const message = typeof err === 'string' ? err : undefined;
            const disabled = isEdit && f.lockOnEdit;
            const span = f.half ? 'col-span-1' : 'col-span-2';
            if (f.type === 'checkbox') {
              return (
                <label key={f.name} htmlFor={id} className={cn(span, 'flex items-center gap-2 pt-5 text-sm')}>
                  <Checkbox id={id} disabled={disabled} {...form.register(f.name)} />
                  {f.label}
                </label>
              );
            }
            return (
              <Field key={f.name} label={f.label} htmlFor={id} error={message} help={f.help} className={span}>
                {f.type === 'select' ? (
                  <NativeSelect id={id} disabled={disabled} autoFocus={f.autoFocus} {...form.register(f.name)}>
                    {f.options?.map((o) => (
                      <option key={o.value} value={o.value}>
                        {o.label}
                      </option>
                    ))}
                  </NativeSelect>
                ) : f.type === 'textarea' ? (
                  <Textarea id={id} disabled={disabled} placeholder={f.placeholder} {...form.register(f.name)} />
                ) : (
                  <Input
                    id={id}
                    type={f.type === 'number' ? 'number' : 'text'}
                    step={f.step}
                    inputMode={f.type === 'number' ? 'decimal' : undefined}
                    className={cn(f.type === 'number' && 'num')}
                    placeholder={f.placeholder}
                    autoFocus={f.autoFocus}
                    disabled={disabled}
                    {...form.register(f.name)}
                  />
                )}
              </Field>
            );
          })}
          <DialogFooter className="col-span-2 pt-2">
            <Button type="button" variant="outline" onClick={onCancel}>
              Cancel
            </Button>
            <Button type="submit" disabled={pending}>
              {pending ? 'Saving…' : 'Save'}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
