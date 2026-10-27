import { Link, Outlet } from 'react-router-dom';
import { ShieldOff } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Spinner } from '@/components/Spinner';
import type { ModuleKey } from '@/lib/permissions';
import { usePermissions } from '../hooks';
import { FeatureLocked } from './RequireFeature';

/**
 * Cosmetic guard for a route. The real guard is RLS: if a role lacks `can_view`,
 * the database returns nothing even when this component is bypassed.
 */
export function RequireModule({ module }: { module: ModuleKey }) {
  const perms = usePermissions();
  if (perms.loading) return <Spinner label="Loading…" />;
  /*
    Blocked by the LICENCE rather than by the role: say that instead, with what
    the plan includes and whatever the supplier has put on the account.
    can_view folds the two reasons together, so an owner on Starter opening
    Purchases used to be told "not available for your role" — sending him to
    the users screen to fix something that is not broken, and never mentioning
    the one thing that would fix it.
  */
  const planLock = perms.planLockFor(module);
  if (planLock && perms.roleCanView(module)) return <FeatureLocked feature={planLock} />;
  if (!perms.canView(module)) {
    return (
      <div className="flex max-w-md flex-col items-start gap-3">
        <div className="flex items-center gap-2 text-lg font-semibold">
          <ShieldOff className="h-5 w-5 text-destructive" aria-hidden />
          Not available for your role
        </div>
        <p className="text-sm text-muted-foreground">
          Your role does not have access to this module. Ask the owner to change it under Setup → Users &amp;
          permissions.
        </p>
        <Button asChild variant="outline" size="sm">
          <Link to="/">Back to dashboard</Link>
        </Button>
      </div>
    );
  }
  return <Outlet />;
}
