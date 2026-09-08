import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Pencil, Plus, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Combobox } from '@/components/Combobox';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { searchItems, type ItemRow } from '@/features/items/api';
import { toast, toastError } from '@/hooks/use-toast';
import { int, qty } from '@/lib/format';
import { newStockRulesApi, templatesApi, type NewStockRuleRow } from '../api';
import { newStockRuleSchema, type NewStockRuleInput } from '../schema';

export function NewStockPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('messaging');
  const rules = useQuery({ queryKey: ['messaging', 'new_stock_rules'], queryFn: newStockRulesApi.list });
  const [editing, setEditing] = useState<{ row: NewStockRuleRow | null } | null>(null);
  const remove = useMutation({
    mutationFn: (id: string) => newStockRulesApi.remove(id),
    onSuccess: async () => { toast({ title: 'Rule removed' }); await qc.invalidateQueries({ queryKey: ['messaging', 'new_stock_rules'] }); },
    onError: (e) => toastError(e, 'Could not remove'),
  });
  const rows = rules.data ?? [];

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">When production or a purchase lifts an item from below the threshold to at or above it, a broadcast goes to customers who bought that item in the look-back window — not the whole list. "Auto send" queues it at once; otherwise it waits on the Broadcasts tab.</p>
        {canEdit && <Button size="sm" className="ml-auto" onClick={() => setEditing({ row: null })}><Plus /> New rule</Button>}
      </div>
      {rules.isLoading ? <Spinner /> : rules.error ? (
        <p role="alert" className="text-sm text-destructive">{rules.error.message}</p>
      ) : !rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No new-stock rules yet.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Item</TableHead><TableHead className="text-right">Threshold (boxes)</TableHead><TableHead className="text-right">Stock now</TableHead><TableHead className="text-right">Buyers in last</TableHead><TableHead>Template</TableHead><TableHead>Auto send</TableHead><TableHead className="text-right">Broadcasts</TableHead><TableHead>Active</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>
              {rows.map((r) => (
                <TableRow key={r.id ?? ''}>
                  <TableCell><span className="font-medium">{r.item_code}</span> {r.item_name}</TableCell>
                  <TableCell className="num">{qty(r.threshold_boxes)}</TableCell>
                  <TableCell className="num">{qty(r.stock_boxes)}{Number(r.stock_boxes ?? 0) < Number(r.threshold_boxes ?? 0) && <Badge variant="outline" className="ml-2">below</Badge>}</TableCell>
                  <TableCell className="num">{int(r.lookback_days)} d</TableCell>
                  <TableCell className="text-muted-foreground">{r.template_name ?? 'by language'}</TableCell>
                  <TableCell>{r.auto_send ? 'Yes' : 'Wait for me'}</TableCell>
                  <TableCell className="num">{int(r.broadcasts)}</TableCell>
                  <TableCell>{r.is_active ? 'Yes' : 'No'}</TableCell>
                  <TableCell className="whitespace-nowrap text-right">
                    {canEdit && <Button size="sm" variant="ghost" aria-label="Edit" onClick={() => setEditing({ row: r })}><Pencil /></Button>}
                    {perms.canDelete('messaging') && <Button size="sm" variant="ghost" aria-label="Delete" onClick={() => remove.mutate(r.id ?? '')}><Trash2 /></Button>}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {editing && <RuleDialog row={editing.row} onClose={() => setEditing(null)} />}
    </div>
  );
}

function RuleDialog({ row, onClose }: { row: NewStockRuleRow | null; onClose: () => void }) {
  const qc = useQueryClient();
  const templates = useQuery({ queryKey: ['setup', 'message_templates'], queryFn: templatesApi.list });
  const [item, setItem] = useState<ItemRow | null>(row ? ({ id: row.item_id, item_code: row.item_code, name: row.item_name } as ItemRow) : null);
  const form = useForm<NewStockRuleInput>({
    resolver: zodResolver(newStockRuleSchema),
    defaultValues: row
      ? { item_id: row.item_id ?? '', threshold_boxes: Number(row.threshold_boxes ?? 5), lookback_days: Number(row.lookback_days ?? 60), template_id: row.template_id ?? '', auto_send: row.auto_send ?? false, is_active: row.is_active ?? true }
      : { item_id: '', threshold_boxes: 5, lookback_days: 60, template_id: '', auto_send: false, is_active: true },
  });
  const save = useMutation({
    mutationFn: (v: NewStockRuleInput) => {
      const values = { item_id: v.item_id, threshold_boxes: v.threshold_boxes, lookback_days: v.lookback_days, template_id: v.template_id || null, auto_send: v.auto_send, is_active: v.is_active };
      return row?.id ? newStockRulesApi.update(row.id, values) : newStockRulesApi.create(values);
    },
    onSuccess: async () => { toast({ title: 'Rule saved' }); await qc.invalidateQueries({ queryKey: ['messaging', 'new_stock_rules'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not save'),
  });
  const e = form.formState.errors;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>{row ? 'Edit new-stock rule' : 'New-stock rule'}</DialogTitle><DialogDescription>Tell recent buyers when this item is back.</DialogDescription></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
          <Field label="Item" htmlFor="ns-item" className="col-span-2" error={e.item_id?.message}>
            <Combobox<ItemRow> id="ns-item" value={item} onChange={(i) => { setItem(i); form.setValue('item_id', i?.id ?? '', { shouldValidate: true }); }} search={(q) => searchItems(q, { finishedOnly: true })} queryKey="items-finished" getKey={(i) => i.id ?? ''} getLabel={(i) => `${i.item_code} — ${i.name}`} renderOption={(i) => <span><span className="font-medium">{i.item_code}</span> {i.name}</span>} placeholder="Code or name…" autoFocus={!row} disabled={Boolean(row)} eager />
          </Field>
          <Field label="Threshold (boxes)" htmlFor="ns-th" error={e.threshold_boxes?.message}><Input id="ns-th" type="number" step="0.001" className="num" {...form.register('threshold_boxes')} /></Field>
          <Field label="Buyers in the last (days)" htmlFor="ns-lb" error={e.lookback_days?.message}><Input id="ns-lb" type="number" className="num" {...form.register('lookback_days')} /></Field>
          <Field label="Template" htmlFor="ns-tpl" className="col-span-2">
            <NativeSelect id="ns-tpl" {...form.register('template_id')}>
              <option value="">— by customer language —</option>
              {(templates.data ?? []).filter((t) => t.purpose === 'new_stock' && t.is_active).map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
            </NativeSelect>
          </Field>
          <label className="flex items-center gap-2 text-sm"><Checkbox {...form.register('auto_send')} /> Send without asking me</label>
          <label className="flex items-center gap-2 text-sm"><Checkbox {...form.register('is_active')} /> Active</label>
          <DialogFooter className="col-span-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={save.isPending}>{save.isPending ? 'Saving…' : 'Save'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
