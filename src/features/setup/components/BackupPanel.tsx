import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { DatabaseBackup, Download, RotateCcw } from 'lucide-react';
import { useState } from 'react';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Checkbox } from '@/components/ui/checkbox';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { Input } from '@/components/ui/input';
import { NativeSelect } from '@/components/ui/native-select';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { toast, toastError } from '@/hooks/use-toast';
import { dateTimeDMY } from '@/lib/format';
import { backupDownloadUrl, getBackupSettings, listBackups, restoreBackup, runBackupNow, saveBackupSettings, type BackupRow } from '../api';

const SETTINGS_KEY = ['setup', 'backup_settings'] as const;
const LIST_KEY = ['setup', 'backups'] as const;

function size(bytes: number | null): string {
  const b = Number(bytes ?? 0);
  if (b < 1024) return `${b} B`;
  if (b < 1024 * 1024) return `${(b / 1024).toFixed(0)} KB`;
  return `${(b / 1024 / 1024).toFixed(1)} MB`;
}

/**
 * Backup: a JSON copy of everything the org owns, taken on a schedule (pg_cron →
 * backup-org) or now, kept for N copies; restore puts the org back to one of them.
 */
export function BackupPanel({ compact }: { compact?: boolean }) {
  const perms = usePermissions();
  const me = useMe();
  const qc = useQueryClient();
  const settings = useQuery({ queryKey: SETTINGS_KEY, queryFn: getBackupSettings });
  const backups = useQuery({ queryKey: LIST_KEY, queryFn: listBackups, refetchInterval: (q) => (q.state.data?.some((b) => b.status === 'running') ? 3000 : false) });
  const [restoring, setRestoring] = useState<BackupRow | null>(null);

  const save = useMutation({
    mutationFn: saveBackupSettings,
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: SETTINGS_KEY });
      toast({ title: 'Backup settings saved' });
    },
    onError: (err) => toastError(err, 'Could not save'),
  });
  const run = useMutation({
    mutationFn: runBackupNow,
    onSuccess: async (r) => {
      await qc.invalidateQueries({ queryKey: LIST_KEY });
      toast({ title: 'Backup ready', description: `${size(r.size_bytes ?? 0)}${r.pruned ? ` · ${r.pruned} old cop${r.pruned === 1 ? 'y' : 'ies'} removed` : ''}` });
    },
    onError: async (err) => {
      await qc.invalidateQueries({ queryKey: LIST_KEY });
      toastError(err, 'Backup failed');
    },
  });
  const download = useMutation({
    mutationFn: async (b: BackupRow) => {
      if (!b.file_path) throw new Error('No file');
      const url = await backupDownloadUrl(b.file_path);
      window.open(url, '_blank', 'noopener');
    },
    onError: (err) => toastError(err, 'Could not fetch the file'),
  });

  const isOwner = perms.isOwner;
  const s = settings.data;

  return (
    <section className="space-y-4">
      <div>
        <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Backup & restore</h2>
        <p className="max-w-2xl text-sm text-muted-foreground">
          Every backup is one file with all your masters, documents, stock and accounts. Automatic copies run at the hour
          you set; keep a downloaded copy somewhere else too. Restore is the emergency exit — it replaces everything with
          the chosen copy. {!isOwner && 'Only the owner can take or restore a backup.'}
        </p>
      </div>

      {settings.isLoading ? (
        <Spinner />
      ) : s ? (
        <form
          className="grid max-w-3xl grid-cols-2 gap-3 md:grid-cols-4"
          onSubmit={(ev) => {
            ev.preventDefault();
            const fd = new FormData(ev.currentTarget);
            save.mutate({
              auto_enabled: fd.get('auto_enabled') === 'on',
              frequency: String(fd.get('frequency') ?? 'daily'),
              run_at: String(fd.get('run_at') ?? '23:30'),
              keep_copies: Math.max(1, Number(fd.get('keep_copies') ?? 30)),
            });
          }}
        >
          <fieldset disabled={!isOwner} className="contents">
            <label htmlFor="bk-auto" className="col-span-2 flex items-center gap-2 pt-6 text-sm md:col-span-1">
              <Checkbox id="bk-auto" name="auto_enabled" defaultChecked={s.auto_enabled} />
              Automatic backups
            </label>
            <Field label="How often" htmlFor="bk-freq">
              <NativeSelect id="bk-freq" name="frequency" defaultValue={s.frequency}>
                <option value="daily">Every day</option>
                <option value="weekly">Every week</option>
              </NativeSelect>
            </Field>
            <Field label="At (IST)" htmlFor="bk-time" help="Checked hourly; runs in that hour.">
              <Input id="bk-time" name="run_at" type="time" defaultValue={s.run_at.slice(0, 5)} />
            </Field>
            <Field label="Copies to keep" htmlFor="bk-keep">
              <Input id="bk-keep" name="keep_copies" type="number" min={1} max={365} className="num" defaultValue={s.keep_copies} />
            </Field>
          </fieldset>
          {isOwner && (
            <div className="col-span-2 flex justify-end gap-2 md:col-span-4">
              <Button type="submit" variant="outline" disabled={save.isPending}>
                {save.isPending ? 'Saving…' : 'Save settings'}
              </Button>
              <Button type="button" onClick={() => run.mutate()} disabled={run.isPending}>
                <DatabaseBackup /> {run.isPending ? 'Backing up…' : 'Back up now'}
              </Button>
            </div>
          )}
        </form>
      ) : null}

      {backups.isLoading ? (
        <Spinner />
      ) : !backups.data?.length ? (
        <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No backups yet.</p>
      ) : (
        <div className="rounded-md border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Taken</TableHead>
                <TableHead>By</TableHead>
                <TableHead className="text-right">Size</TableHead>
                <TableHead>Status</TableHead>
                <TableHead className="w-48 text-right">Actions</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {backups.data.map((b) => (
                <TableRow key={b.id ?? ''}>
                  <TableCell>{dateTimeDMY(b.created_at)}</TableCell>
                  <TableCell>{b.is_auto ? <span className="text-muted-foreground">Automatic</span> : (b.created_by_name ?? '—')}</TableCell>
                  <TableCell className="num">{b.size_bytes ? size(b.size_bytes) : '—'}</TableCell>
                  <TableCell>
                    <Badge variant={b.status === 'ready' ? 'secondary' : b.status === 'failed' ? 'destructive' : b.status === 'restored' ? 'default' : 'outline'}>{b.status}</Badge>
                  </TableCell>
                  <TableCell className="text-right">
                    {isOwner && (b.status === 'ready' || b.status === 'restored') && (
                      <>
                        <Button variant="ghost" size="sm" onClick={() => download.mutate(b)} disabled={download.isPending}>
                          <Download /> Download
                        </Button>
                        <Button variant="ghost" size="sm" className="text-destructive" onClick={() => setRestoring(b)}>
                          <RotateCcw /> Restore
                        </Button>
                      </>
                    )}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      {restoring && <RestoreDialog backup={restoring} orgName={me.data?.org_name ?? ''} onClose={() => setRestoring(null)} />}
    </section>
  );
}

function RestoreDialog({ backup, orgName, onClose }: { backup: BackupRow; orgName: string; onClose: () => void }) {
  const qc = useQueryClient();
  const [typed, setTyped] = useState('');
  const restore = useMutation({
    mutationFn: () => restoreBackup(backup.id ?? ''),
    onSuccess: async (r) => {
      await qc.invalidateQueries();
      const n = Object.values(r.restored).reduce((s, v) => s + v, 0);
      toast({ title: 'Restored', description: `${n} rows back from the copy taken ${dateTimeDMY(r.taken_at)}.` });
      onClose();
    },
    onError: (err) => toastError(err, 'Restore failed — nothing was changed'),
  });
  const ok = typed.trim().toUpperCase() === orgName.trim().toUpperCase() && orgName !== '';
  return (
    <Dialog open onOpenChange={(o) => !o && !restore.isPending && onClose()}>
      <DialogContent className="max-w-md">
        <DialogHeader>
          <DialogTitle>Restore the copy from {dateTimeDMY(backup.created_at)}?</DialogTitle>
          <DialogDescription>
            Everything entered after that moment — bills, receipts, stock movements, master changes — will be gone. User logins
            and the audit trail stay. Take a fresh backup first if you may want today's work back.
          </DialogDescription>
        </DialogHeader>
        <Field label={`Type the trade name (${orgName}) to confirm`} htmlFor="rs-name">
          <Input id="rs-name" value={typed} onChange={(e) => setTyped(e.target.value)} autoFocus />
        </Field>
        <DialogFooter>
          <Button variant="outline" onClick={onClose} disabled={restore.isPending}>
            Cancel
          </Button>
          <Button variant="destructive" onClick={() => restore.mutate()} disabled={!ok || restore.isPending}>
            {restore.isPending ? 'Restoring…' : 'Restore now'}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
