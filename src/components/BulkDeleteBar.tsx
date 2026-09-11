import { useQueryClient } from '@tanstack/react-query';
import { Trash2, X } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { toast } from '@/hooks/use-toast';
import { errorMessage } from '@/lib/errors';
import { int } from '@/lib/format';

export interface BulkDeleteBarProps {
  /** The selected rows, in the order they are shown. */
  ids: string[];
  /** How to name one of them in a message: "BESEN", "invoice 0041". */
  labelFor: (id: string) => string;
  /** Deletes one. Resolves to 'deleted' or 'cancelled'; rejects to refuse. */
  onDelete: (id: string) => Promise<string>;
  /** Clears the selection after a run. */
  onClear: () => void;
  invalidate?: string[];
  /** Singular, lower case: "product", "customer". */
  noun: string;
  /** Extra sentence in the confirmation. */
  detail?: ReactNode;
}

interface Refusal {
  label: string;
  reason: string;
}

/**
 * Delete a page-full at once, one at a time, and report honestly on what
 * happened to each.
 *
 * Deleting in bulk here is not the usual "are you sure" — half of these calls
 * come back REFUSED, because a product that has been billed or counted must not
 * vanish. A bar that reported "14 deleted" over six silent refusals would be
 * worse than no bar at all, so the run always ends with a list: what went, what
 * stayed, and why it stayed.
 *
 * Sequential on purpose. Each delete is a separate permission check and a
 * separate refusal, forty of them at once is a burst the database gains nothing
 * from, and the order of the results has to match the order on screen.
 */
export function BulkDeleteBar({ ids, labelFor, onDelete, onClear, invalidate = [], noun, detail }: BulkDeleteBarProps) {
  const [confirm, setConfirm] = useState(false);
  const [running, setRunning] = useState(false);
  const [done, setDone] = useState<{ removed: number; refused: Refusal[] } | null>(null);
  const queryClient = useQueryClient();

  if (ids.length === 0) return null;
  const plural = ids.length === 1 ? noun : `${noun}s`;

  const run = async () => {
    setRunning(true);
    let removed = 0;
    const refused: Refusal[] = [];
    for (const id of ids) {
      try {
        await onDelete(id);
        removed += 1;
      } catch (err) {
        refused.push({ label: labelFor(id), reason: errorMessage(err) });
      }
    }
    await Promise.all(invalidate.map((key) => queryClient.invalidateQueries({ queryKey: [key] })));
    setRunning(false);
    setConfirm(false);
    setDone({ removed, refused });
    // Only clear what actually went: leaving the refused ones ticked means the
    // list on screen still matches the list in the report beside it.
    if (!refused.length) onClear();
    if (removed) toast({ title: `${int(removed)} ${removed === 1 ? noun : `${noun}s`} deleted` });
  };

  return (
    <>
      <div className="flex flex-wrap items-center gap-2 rounded-md border bg-muted/40 p-2 text-sm">
        <span className="font-medium">{int(ids.length)} selected</span>
        <Button variant="destructive" size="sm" onClick={() => setConfirm(true)} disabled={running}>
          <Trash2 /> Delete {int(ids.length)} {plural}
        </Button>
        <Button variant="ghost" size="sm" onClick={onClear} disabled={running}>
          <X /> Clear
        </Button>
      </div>

      <Dialog open={confirm} onOpenChange={(o) => !running && setConfirm(o)}>
        <DialogContent className="max-w-md">
          <DialogHeader>
            <DialogTitle>Delete {int(ids.length)} {plural}?</DialogTitle>
            <DialogDescription>
              {detail ?? `Each one is checked separately. Any that cannot go will be listed with the reason, and nothing else in the batch is affected.`}
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setConfirm(false)} disabled={running}>
              Keep them
            </Button>
            <Button variant="destructive" onClick={() => void run()} disabled={running}>
              {running ? `Deleting… ` : `Delete ${int(ids.length)}`}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>

      <Dialog open={Boolean(done)} onOpenChange={() => setDone(null)}>
        <DialogContent className="max-w-lg">
          <DialogHeader>
            <DialogTitle>
              {done?.removed ? `${int(done.removed)} deleted` : 'Nothing was deleted'}
              {done?.refused.length ? `, ${int(done.refused.length)} kept` : ''}
            </DialogTitle>
            <DialogDescription>
              {done?.refused.length
                ? 'These were refused. They are still ticked, so you can set them inactive instead.'
                : 'All of them went.'}
            </DialogDescription>
          </DialogHeader>
          {Boolean(done?.refused.length) && (
            <ul className="max-h-72 space-y-1.5 overflow-auto text-sm">
              {done?.refused.map((r, i) => (
                <li key={`${r.label}-${i}`}>
                  <span className="font-medium">{r.label}</span>
                  <span className="block text-xs text-destructive">{r.reason}</span>
                </li>
              ))}
            </ul>
          )}
          <DialogFooter>
            <Button onClick={() => setDone(null)}>Close</Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
