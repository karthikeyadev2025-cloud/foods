import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { Check, KeyRound, Lock, Trash2 } from 'lucide-react';
import { useState } from 'react';
import { Field } from '@/components/Field';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useLicense, useMe, usePermissions } from '@/features/auth/hooks';
import { activateLicense, LICENSE_LABEL, listLicenseDevices, removeLicenseDevice } from '@/features/license/api';
import { toast, toastError } from '@/hooks/use-toast';
import { deviceInfo } from '@/lib/desktop';
import { dateDMY, dateTimeDMY } from '@/lib/format';
import { FEATURES, PLANS } from '@/lib/permissions';
import { cn } from '@/lib/utils';

const DEVICES_KEY = ['license', 'devices'] as const;

/**
 * The three keys, what each opens, and where this organisation sits. Locked rows are
 * shown rather than hidden: the owner should be able to see what the next key buys.
 */
function PlanLadder() {
  const perms = usePermissions();
  const license = useLicense();
  // During a plan trial the plan in force is Full while the key says Starter. Marking only
  // the one in force would let a client believe they had bought it.
  const paid = license.data?.paid_plan;
  const onTrial = license.data?.plan_trial_days_left != null;
  return (
    <section>
      <h3 className="mb-1 text-sm font-medium">What each key opens</h3>
      <p className="mb-2 max-w-2xl text-sm text-muted-foreground">
        Each plan includes everything in the one before it. Moving up is a new key — nothing is reinstalled, and nothing
        already entered is lost.
      </p>
      <div className="grid gap-3 lg:grid-cols-3">
        {PLANS.map((p) => {
          const mine = p.key === perms.plan;
          const bought = onTrial && p.key === paid;
          return (
            <div key={p.key} className={cn('rounded-md border p-3', mine && 'border-primary bg-primary/5', bought && 'border-primary')}>
              <div className="flex items-center gap-2">
                <span className="font-semibold">{p.label}</span>
                {mine && <Badge>{onTrial ? 'open now' : 'current'}</Badge>}
                {bought && <Badge variant="secondary">your key</Badge>}
              </div>
              <p className="mt-1 text-xs text-muted-foreground">{p.blurb}</p>
              <ul className="mt-2 space-y-1 text-sm">
                {FEATURES.filter((f) => f.plan === p.key).map((f) => {
                  const on = perms.has(f.key);
                  return (
                    <li key={f.key} className="flex items-start gap-1.5">
                      {on ? (
                        <Check className="mt-0.5 h-3.5 w-3.5 shrink-0 text-emerald-600" aria-hidden />
                      ) : (
                        <Lock className="mt-0.5 h-3.5 w-3.5 shrink-0 text-muted-foreground" aria-hidden />
                      )}
                      <span className={on ? '' : 'text-muted-foreground'}>
                        {f.label}
                        <span className="block text-xs text-muted-foreground">{f.detail}</span>
                      </span>
                    </li>
                  );
                })}
              </ul>
            </div>
          );
        })}
      </div>
    </section>
  );
}

/**
 * Licence: the state the app runs in, the key entry, and the devices the key is
 * active on. The database decides (db/18_licensing.sql); this screen only shows it.
 */
export function LicencePanel({ compact }: { compact?: boolean }) {
  const me = useMe();
  const qc = useQueryClient();
  const license = useLicense();
  const devices = useQuery({ queryKey: DEVICES_KEY, queryFn: listLicenseDevices });
  const thisDevice = useQuery({ queryKey: ['license', 'this_device'], queryFn: deviceInfo, staleTime: Infinity });
  const [key, setKey] = useState('');
  const canActivate = me.data?.role === 'owner' || me.data?.role === 'admin';
  const isOwner = me.data?.role === 'owner';

  const activate = useMutation({
    mutationFn: () => activateLicense(key),
    onSuccess: async (s) => {
      await qc.invalidateQueries({ queryKey: ['license'] });
      await qc.invalidateQueries({ queryKey: ['permissions'] });
      setKey('');
      toast({ title: 'Licence activated', description: s.valid_till ? `Valid till ${dateDMY(s.valid_till)}.` : undefined });
    },
    onError: (err) => toastError(err, 'Could not activate'),
  });
  const remove = useMutation({
    mutationFn: removeLicenseDevice,
    onSuccess: async () => {
      await qc.invalidateQueries({ queryKey: ['license'] });
      toast({ title: 'Device removed' });
    },
    onError: (err) => toastError(err, 'Could not remove the device'),
  });

  const s = license.data;
  const tone = !s ? 'outline' : s.read_only ? 'destructive' : s.status === 'active' ? 'secondary' : 'default';

  return (
    <section className="space-y-4">
      <div>
        <h2 className={compact ? 'text-base font-semibold' : 'text-lg font-semibold'}>Licence</h2>
        <p className="max-w-2xl text-sm text-muted-foreground">
          The app checks its licence on start and every half hour. Once a licence lapses beyond the grace days the app is
          read-only: every screen, report and export still works, but no new documents can be made until it is renewed.
        </p>
      </div>

      {license.isLoading ? (
        <Spinner />
      ) : license.error ? (
        <p role="alert" className="text-sm text-destructive">
          {license.error.message}
        </p>
      ) : s ? (
        <div className="grid max-w-3xl gap-3 rounded-md border p-4 text-sm md:grid-cols-2">
          <div className="space-y-1">
            <div className="flex items-center gap-2">
              <Badge variant={tone}>{LICENSE_LABEL[s.status]}</Badge>
              {s.read_only && <span className="text-destructive">read-only</span>}
            </div>
            <div>
              Plan <Badge variant="secondary">{s.plan_name}</Badge>
              {s.plan_trial_days_left != null && <Badge className="ml-1">trial</Badge>}
            </div>
            {s.plan_trial_days_left != null && (
              <div className="text-amber-700 dark:text-amber-500">
                Everything is open for {s.plan_trial_days_left} more day{s.plan_trial_days_left === 1 ? '' : 's'}
                {s.plan_full_until && `, until ${dateDMY(s.plan_full_until)}`}. After that this becomes{' '}
                <span className="font-medium">{s.paid_plan_name}</span> — nothing entered is lost, the extra screens simply close.
              </div>
            )}
            {s.licensed_to && <div>Licensed to <span className="font-medium">{s.licensed_to}</span></div>}
            <div>
              {s.status === 'trial' && `Trial ends ${s.valid_till ? dateDMY(s.valid_till) : ''} (${s.days_left} day${s.days_left === 1 ? '' : 's'} left).`}
              {s.status === 'unlicensed' && `The ${s.trial_days}-day trial ended ${s.valid_till ? dateDMY(s.valid_till) : ''}.`}
              {s.status === 'active' && `Valid till ${s.valid_till ? dateDMY(s.valid_till) : ''} (${s.days_left} day${s.days_left === 1 ? '' : 's'} left).`}
              {s.status === 'grace' && `Expired ${s.valid_till ? dateDMY(s.valid_till) : ''}, ${-s.days_left} day${-s.days_left === 1 ? '' : 's'} ago. Read-only after ${s.grace_days} days of grace.`}
              {s.status === 'expired' && `Expired ${s.valid_till ? dateDMY(s.valid_till) : ''}. Renew to create documents again.`}
            </div>
            <div className="text-muted-foreground">
              Devices: {s.devices} of {s.max_devices}
              {thisDevice.data && (
                <>
                  {' '}· this device: {thisDevice.data.deviceName} ({s.this_device_known ? 'activated' : 'not activated'})
                </>
              )}
            </div>
            <div className="text-xs text-muted-foreground">Checked {dateTimeDMY(s.checked_at)}</div>
          </div>
          <div>
            {canActivate ? (
              <form
                className="space-y-2"
                onSubmit={(ev) => {
                  ev.preventDefault();
                  activate.mutate();
                }}
              >
                <Field label="Licence key" htmlFor="lic-key" help={s.has_key ? 'Enter the key on each device that will use the app.' : 'No licence has been issued yet — ask your vendor for a key.'}>
                  <Input id="lic-key" value={key} onChange={(e) => setKey(e.target.value)} placeholder="JF-XXXXX-XXXXX-XXXXX-XXXXX" autoComplete="off" className="font-mono uppercase" />
                </Field>
                <Button type="submit" size="sm" disabled={!key.trim() || activate.isPending}>
                  <KeyRound /> {activate.isPending ? 'Checking…' : 'Activate on this device'}
                </Button>
              </form>
            ) : (
              <p className="text-muted-foreground">Ask the owner or an admin to enter the licence key.</p>
            )}
          </div>
        </div>
      ) : null}

      <PlanLadder />

      <div>
        <h3 className="mb-1 text-sm font-medium">Activated devices</h3>
        {devices.isLoading ? (
          <Spinner />
        ) : !devices.data?.length ? (
          <p className="text-sm text-muted-foreground">No device has activated the key yet.</p>
        ) : (
          <div className="max-w-3xl rounded-md border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Device</TableHead>
                  <TableHead>Platform</TableHead>
                  <TableHead>Version</TableHead>
                  <TableHead>Activated</TableHead>
                  <TableHead>Last seen</TableHead>
                  {isOwner && <TableHead className="w-12" />}
                </TableRow>
              </TableHeader>
              <TableBody>
                {devices.data.map((d) => (
                  <TableRow key={d.id ?? ''}>
                    <TableCell className="font-medium">
                      {d.device_name ?? d.device_id}
                      {thisDevice.data?.deviceId === d.device_id && <span className="ml-2 text-xs text-muted-foreground">(this one)</span>}
                    </TableCell>
                    <TableCell>{d.platform ?? '—'}</TableCell>
                    <TableCell>{d.app_version ?? '—'}</TableCell>
                    <TableCell>
                      {dateTimeDMY(d.activated_at)}
                      {d.activated_by_name && <div className="text-xs text-muted-foreground">{d.activated_by_name}</div>}
                    </TableCell>
                    <TableCell>{dateTimeDMY(d.last_seen)}</TableCell>
                    {isOwner && (
                      <TableCell>
                        <Button variant="ghost" size="icon" aria-label={`Remove ${d.device_name ?? d.device_id}`} onClick={() => remove.mutate(d.id ?? '')} disabled={remove.isPending}>
                          <Trash2 />
                        </Button>
                      </TableCell>
                    )}
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>
    </section>
  );
}
