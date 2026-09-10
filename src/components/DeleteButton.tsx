import { useMutation, useQueryClient } from '@tanstack/react-query';
import { Trash2 } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { toast } from '@/hooks/use-toast';
import { errorMessage } from '@/lib/errors';

export interface DeleteButtonProps {
  /** What is being removed, as a person would say it: "invoice 0041", "P. SRINIVAS". */
  label: string;
  /** Does the deletion. Resolves to 'deleted' or 'cancelled'. */
  onDelete: () => Promise<string>;
  /** Query keys to refresh afterwards. */
  invalidate?: string[];
  /** Extra sentence for this kind — what the deletion will undo. */
  detail?: ReactNode;
  /** Shown as an icon in a table row, or a labelled button on a detail screen. */
  variant?: 'icon' | 'button';
  disabled?: boolean;
  /** Runs after a successful delete, e.g. to navigate away from the record. */
  onDone?: (outcome: string) => void;
  /**
   * Sets the record inactive. Offered only once a refusal has actually named
   * that as the way out — which is the moment the person wants it, and saves
   * them closing this, finding the record, opening it and hunting for a tick box.
   */
  onDeactivate?: () => Promise<unknown>;
}

/**
 * One delete, everywhere, so it always behaves the same and always explains
 * itself first.
 *
 * The confirmation is not a formality. Half of these calls come back refused —
 * a product that is on a bill, a purchase whose goods have been sold — and the
 * reason the database gives is written to be read by the person at the screen,
 * so it is shown as-is rather than replaced with "could not delete".
 */
export function DeleteButton({
  label,
  onDelete,
  invalidate = [],
  detail,
  variant = 'icon',
  disabled,
  onDone,
  onDeactivate,
}: DeleteButtonProps) {
  const [open, setOpen] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const queryClient = useQueryClient();

  const run = useMutation({
    mutationFn: onDelete,
    onSuccess: async (outcome) => {
      await Promise.all(invalidate.map((key) => queryClient.invalidateQueries({ queryKey: [key] })));
      setOpen(false);
      setRefusal(null);
      toast({ title: outcome === 'cancelled' ? `${label} cancelled` : `${label} deleted` });
      onDone?.(outcome);
    },
    // Kept on the dialog rather than thrown as a toast: the refusal explains what
    // to do instead, and a toast is gone before it has been read.
    onError: (err) => setRefusal(errorMessage(err)),
  });

  const deactivate = useMutation({
    mutationFn: () => onDeactivate!(),
    onSuccess: async () => {
      await Promise.all(invalidate.map((key) => queryClient.invalidateQueries({ queryKey: [key] })));
      setOpen(false);
      setRefusal(null);
      toast({ title: `${label} set inactive`, description: 'It is gone from new work. Every old record still reads correctly.' });
    },
    onError: (err) => setRefusal(errorMessage(err)),
  });

  // Only when the database itself said so — never guessed at from the error code.
  const offerInactive = Boolean(onDeactivate) && Boolean(refusal?.toLowerCase().includes('inactive'));

  return (
    <>
      {variant === 'icon' ? (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          aria-label={`Delete ${label}`}
          disabled={disabled}
          onClick={() => { setRefusal(null); setOpen(true); }}
        >
          <Trash2 className="text-destructive" />
        </Button>
      ) : (
        <Button
          type="button"
          variant="ghost"
          size="sm"
          className="text-destructive"
          disabled={disabled}
          onClick={() => { setRefusal(null); setOpen(true); }}
        >
          <Trash2 /> Delete
        </Button>
      )}

      <Dialog open={open} onOpenChange={(o) => { setOpen(o); if (!o) setRefusal(null); }}>
        <DialogContent className="max-w-sm">
          <DialogHeader>
            <DialogTitle>Delete {label}?</DialogTitle>
            <DialogDescription>{detail ?? 'This cannot be undone.'}</DialogDescription>
          </DialogHeader>
          {refusal && (
            <p role="alert" className="rounded-md bg-destructive/10 p-3 text-sm text-destructive">{refusal}</p>
          )}
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)}>
              {refusal ? 'Close' : 'Keep it'}
            </Button>
            {offerInactive ? (
              <Button onClick={() => deactivate.mutate()} disabled={deactivate.isPending}>
                Set inactive
              </Button>
            ) : (
              <Button variant="destructive" onClick={() => run.mutate()} disabled={run.isPending}>
                {refusal ? 'Try again' : 'Delete'}
              </Button>
            )}
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
