import { Lock, ShieldOff } from 'lucide-react';
import { usePermissions } from '@/features/auth/hooks';

/**
 * "You cannot do this here", for the right reason.
 *
 * Every screen that writes ends with the same line when the person may not:
 * "Your role cannot enter purchases." Correct while a role was the only thing
 * that could stop them. Once an account can be frozen it is a lie — the owner
 * reads that it is his role, goes to Setup → Users to widen a permission that
 * is already as wide as it goes, and never learns that the bill is the reason.
 *
 * A frozen account says so, and says what is still possible, and carries the
 * supplier's own message about the account (db/63) so the next step is on the
 * screen rather than in a phone call to work out why.
 */
export function CannotEdit({ verb }: { verb: string }) {
  const perms = usePermissions();

  if (perms.readOnly) {
    return (
      <div className="max-w-lg space-y-2 rounded-md border border-destructive/40 bg-destructive/5 p-4">
        <div className="flex items-center gap-2 font-semibold">
          <Lock className="h-4 w-4 shrink-0 text-destructive" aria-hidden />
          The app is read-only
        </div>
        {perms.accountNotice && <p className="text-sm font-medium">{perms.accountNotice}</p>}
        <p className="text-sm text-muted-foreground">
          Nothing new can be saved until the account is settled, so you cannot {verb} at the moment. Everything already
          entered can still be opened, printed and exported, and nothing has been lost.
        </p>
      </div>
    );
  }

  return (
    <p className="flex items-center gap-2 text-sm text-muted-foreground">
      <ShieldOff className="h-4 w-4 shrink-0" aria-hidden />
      Your role cannot {verb}. Ask the owner to change it under Setup → Users &amp; permissions.
    </p>
  );
}
