import { useMutation, useQueryClient } from '@tanstack/react-query';
import { Trash2 } from 'lucide-react';
import { useState, type ReactNode } from 'react';
import { Button } from '@/components/ui/button';
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from '@/components/ui/dialog';
import { toast } from '@/hooks/use-toast';

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
    onError: (err) => setRefusal(err instanceof Error ? err.message : String(err)),
  });

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
            <Button variant="destructive" onClick={() => run.mutate()} disabled={run.isPending}>
              {refusal ? 'Try again' : 'Delete'}
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
