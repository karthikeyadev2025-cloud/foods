import { Link, Outlet } from 'react-router-dom';
import { ShieldOff } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { Spinner } from '@/components/Spinner';
import type { ModuleKey } from '@/lib/permissions';
import { usePermissions } from '../hooks';

/**
 * Cosmetic guard for a route. The real guard is RLS: if a role lacks `can_view`,
 * the database returns nothing even when this component is bypassed.
 */
export function RequireModule({ module }: { module: ModuleKey }) {
  const perms = usePermissions();
  if (perms.loading) return <Spinner label="Loading…" />;
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
