import { Lock } from 'lucide-react';
import { Link, Outlet } from 'react-router-dom';
import { Spinner } from '@/components/Spinner';
import { Button } from '@/components/ui/button';
import { featureInfo, planLabel, type FeatureKey } from '@/lib/permissions';
import { usePermissions } from '../hooks';

/**
 * A screen the licence plan does not include. Says what it is and which key opens it,
 * rather than pretending the screen does not exist — the owner should be able to see
 * what they would get. The database refuses the data either way (db/21_plans.sql).
 */
export function FeatureLocked({ feature }: { feature: FeatureKey }) {
  const perms = usePermissions();
  const info = featureInfo(feature);
  return (
    <div className="mx-auto max-w-lg rounded-md border bg-card p-6">
      <div className="flex items-center gap-2 text-lg font-semibold">
        <Lock className="h-5 w-5 text-muted-foreground" aria-hidden />
        {info?.label ?? 'This feature'} is not in your licence
      </div>
      <p className="mt-2 text-sm text-muted-foreground">{info?.detail}</p>
      <p className="mt-3 text-sm">
        You are on the <strong>{perms.planName}</strong> plan. This is included in{' '}
        <strong>{planLabel(info?.plan)}</strong>.
      </p>
      <p className="mt-2 text-sm text-muted-foreground">
        Nothing is lost — anything already entered stays, and it appears again the moment the new key is entered.
      </p>
      <div className="mt-4 flex gap-2">
        <Button asChild size="sm" variant="outline">
          <Link to="/">Back to dashboard</Link>
        </Button>
        {perms.canView('setup') && (
          <Button asChild size="sm">
            <Link to="/setup/licence">See the plans</Link>
          </Button>
        )}
      </div>
    </div>
  );
}

/** Route guard: the licence plan must include the feature. */
export function RequireFeature({ feature }: { feature: FeatureKey }) {
  const perms = usePermissions();
  if (perms.loading) return <Spinner label="Loading…" />;
  if (!perms.has(feature)) return <FeatureLocked feature={feature} />;
  return <Outlet />;
}
