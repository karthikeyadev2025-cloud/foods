import { zodResolver } from '@hookform/resolvers/zod';
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { ExternalLink, Pencil, Plus, Send, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { useForm } from 'react-hook-form';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { dateDMY, toISODate } from '@/lib/format';
import { catalogsApi, uploadCatalogPdf, type Catalog } from '../api';
import { catalogSchema, type CatalogInput } from '../schema';
import { BroadcastDialog } from './BroadcastsPanel';

export function CatalogsPanel() {
  const qc = useQueryClient();
  const perms = usePermissions();
  const canEdit = perms.canEdit('messaging');
  const catalogs = useQuery({ queryKey: ['messaging', 'catalogs'], queryFn: catalogsApi.list });
  const [editing, setEditing] = useState<{ row: Catalog | null } | null>(null);
  const [pushing, setPushing] = useState<Catalog | null>(null);
  const remove = useMutation({
    mutationFn: (id: string) => catalogsApi.remove(id),
    onSuccess: async () => { toast({ title: 'Catalog removed' }); await qc.invalidateQueries({ queryKey: ['messaging', 'catalogs'] }); },
    onError: (e) => toastError(e, 'Could not remove'),
  });
  const rows = catalogs.data ?? [];

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center gap-2">
        <p className="max-w-2xl text-sm text-muted-foreground">Upload the price list or festival catalog as a PDF, then push it to a route, a town, or recent buyers. The PDF sits in the <code>catalogs</code> storage bucket so Hey Nikki can attach it.</p>
        {canEdit && <Button size="sm" className="ml-auto" onClick={() => setEditing({ row: null })}><Plus /> New catalog</Button>}
      </div>
      {catalogs.isLoading ? <Spinner /> : catalogs.error ? (
        <p role="alert" className="text-sm text-destructive">{catalogs.error.message}</p>
      ) : !rows.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No catalogs yet.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader><TableRow><TableHead>Name</TableHead><TableHead>Valid</TableHead><TableHead>PDF</TableHead><TableHead>Active</TableHead><TableHead /></TableRow></TableHeader>
            <TableBody>
              {rows.map((c) => (
                <TableRow key={c.id}>
                  <TableCell className="font-medium">{c.name}</TableCell>
                  <TableCell className="text-muted-foreground">{dateDMY(c.valid_from)}{c.valid_to ? ` → ${dateDMY(c.valid_to)}` : ''}</TableCell>
                  <TableCell>{c.pdf_url ? <a href={c.pdf_url} target="_blank" rel="noreferrer" className="inline-flex items-center gap-1 text-primary hover:underline">Open <ExternalLink className="h-3 w-3" /></a> : <span className="text-muted-foreground">no file</span>}</TableCell>
                  <TableCell>{c.is_active ? 'Yes' : 'No'}</TableCell>
                  <TableCell className="whitespace-nowrap text-right">
                    {canEdit && <Button size="sm" onClick={() => setPushing(c)} disabled={!c.pdf_url}><Send /> Push</Button>}{' '}
                    {canEdit && <Button size="sm" variant="ghost" aria-label="Edit" onClick={() => setEditing({ row: c })}><Pencil /></Button>}
                    {perms.canDelete('messaging') && <Button size="sm" variant="ghost" aria-label="Delete" onClick={() => remove.mutate(c.id)}><Trash2 /></Button>}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}
      {editing && <CatalogDialog row={editing.row} onClose={() => setEditing(null)} />}
      <BroadcastDialog open={Boolean(pushing)} onClose={() => setPushing(null)} kind="catalog" catalogId={pushing?.id} catalogName={pushing?.name} />
    </div>
  );
}

function CatalogDialog({ row, onClose }: { row: Catalog | null; onClose: () => void }) {
  const qc = useQueryClient();
  const [file, setFile] = useState<File | null>(null);
  const form = useForm<CatalogInput>({
    resolver: zodResolver(catalogSchema),
    defaultValues: row ? { name: row.name, valid_from: row.valid_from ?? '', valid_to: row.valid_to ?? '', is_active: row.is_active } : { name: '', valid_from: toISODate(), valid_to: '', is_active: true },
  });
  const save = useMutation({
    mutationFn: async (v: CatalogInput) => {
      if (!row && !file) throw new Error('Choose the PDF');
      const uploaded = file ? await uploadCatalogPdf(file) : null;
      const values = { name: v.name, valid_from: v.valid_from || null, valid_to: v.valid_to || null, is_active: v.is_active, ...(uploaded ? { pdf_url: uploaded.url, file_path: uploaded.path } : {}) };
      return row ? catalogsApi.update(row.id, values) : catalogsApi.create(values);
    },
    onSuccess: async () => { toast({ title: 'Catalog saved' }); await qc.invalidateQueries({ queryKey: ['messaging', 'catalogs'] }); onClose(); },
    onError: (e) => toastError(e, 'Could not save the catalog'),
  });
  const e = form.formState.errors;
  return (
    <Dialog open onOpenChange={(o) => !o && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader><DialogTitle>{row ? 'Edit catalog' : 'New catalog'}</DialogTitle><DialogDescription>A PDF up to a few MB works best on WhatsApp.</DialogDescription></DialogHeader>
        <form onSubmit={form.handleSubmit((v) => save.mutate(v))} className="grid grid-cols-2 gap-3">
          <Field label="Name" htmlFor="ct-name" className="col-span-2" error={e.name?.message}><Input id="ct-name" autoFocus {...form.register('name')} /></Field>
          <Field label="Valid from" htmlFor="ct-from"><Input id="ct-from" type="date" {...form.register('valid_from')} /></Field>
          <Field label="Valid to" htmlFor="ct-to"><Input id="ct-to" type="date" {...form.register('valid_to')} /></Field>
          <Field label={row ? 'Replace PDF (optional)' : 'PDF'} htmlFor="ct-file" className="col-span-2">
            <Input id="ct-file" type="file" accept="application/pdf" onChange={(ev) => setFile(ev.target.files?.[0] ?? null)} />
          </Field>
          <label className="col-span-2 flex items-center gap-2 text-sm"><Checkbox {...form.register('is_active')} /> Active</label>
          <DialogFooter className="col-span-2 pt-2">
            <Button type="button" variant="outline" onClick={onClose}>Cancel</Button>
            <Button type="submit" disabled={save.isPending}>{save.isPending ? 'Uploading…' : 'Save'}</Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
