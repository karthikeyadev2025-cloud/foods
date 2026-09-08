import { useQuery } from '@tanstack/react-query';
import { AlertTriangle, ArrowRight, Boxes, Factory, FileText, IndianRupee, Landmark, MessageSquare, Truck, Wallet } from 'lucide-react';
import type { ReactNode } from 'react';
import { useState } from 'react';
import { Link } from 'react-router-dom';
import { Field } from '@/components/Field';
import { PageHeader } from '@/components/PageHeader';
import { Spinner } from '@/components/Spinner';
import { Badge } from '@/components/ui/badge';
import { Button } from '@/components/ui/button';
import { Card, CardContent, CardHeader, CardTitle } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '@/components/ui/table';
import { useMe, usePermissions } from '@/features/auth/hooks';
import { dateDMY, dateTimeDMY, int, money, toISODate } from '@/lib/format';
import type { ModuleKey } from '@/lib/permissions';
import { cn } from '@/lib/utils';
import { activityLink, dashboardActivity, dashboardSummary, pendingOrders } from '../api';

/**
 * T5.1 — every tile is a SUM/COUNT from `dashboard_summary()` over the live tables;
 * nothing here is stored. The date defaults to today and can be moved back.
 */
export function DashboardPage() {
  const me = useMe();
  const perms = usePermissions();
  const orgId = me.data?.org_id ?? '';
  const [date, setDate] = useState(toISODate());
  const isToday = date === toISODate();

  const summary = useQuery({ queryKey: ['dashboard', 'summary', orgId, date], queryFn: () => dashboardSummary(orgId, date), enabled: Boolean(orgId), refetchInterval: 60_000 });
  const activity = useQuery({ queryKey: ['dashboard', 'activity', orgId, date], queryFn: () => dashboardActivity(orgId, date), enabled: Boolean(orgId), refetchInterval: 60_000 });
  const orders = useQuery({ queryKey: ['dashboard', 'orders', orgId], queryFn: pendingOrders, enabled: Boolean(orgId) && perms.canView('messaging'), refetchInterval: 60_000 });

  const s = summary.data;
  return (
    <div className="space-y-4">
      <PageHeader
        title={me.data?.org_name ? `${me.data.org_name}` : 'Dashboard'}
        description={isToday ? `Today, ${dateDMY(date)}` : `As on ${dateDMY(date)}`}
        actions={
          <Field label="Date" htmlFor="db-date"><Input id="db-date" type="date" className="h-8 w-40" value={date} max={toISODate()} onChange={(e) => setDate(e.target.value || toISODate())} /></Field>
        }
      />

      {summary.error && <p role="alert" className="text-sm text-destructive">Could not load the summary: {summary.error.message}</p>}

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tile perms={perms} module="invoices" to="/invoices" icon={FileText} label={isToday ? 'Sales today' : 'Sales on the day'} value={s ? money(s.sales_today) : null} sub={s ? `${int(s.invoices_today)} invoice${s.invoices_today === 1 ? '' : 's'}` : ''} />
        <Tile perms={perms} module="invoices" to="/reports/sales" icon={IndianRupee} label="Sales this month" value={s ? money(s.sales_mtd) : null} sub="month to date" />
        <Tile perms={perms} module="receipts" to="/receipts" icon={Wallet} label={isToday ? 'Collection today' : 'Collection on the day'} value={s ? money(s.collection_today) : null} sub="all receipt modes" />
        <Tile perms={perms} module="reports" to="/reports/ageing" icon={IndianRupee} label="Total outstanding" value={s ? money(s.total_outstanding) : null} sub="every customer, live" tone={s && s.total_outstanding > 0 ? 'warn' : undefined} />
      </div>
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <Tile perms={perms} module="stock" to="/stock/low" icon={Boxes} label="Low stock" value={s ? int(s.low_stock_items) : null} sub="items at or below reorder level" tone={s && s.low_stock_items > 0 ? 'warn' : undefined} />
        <Tile perms={perms} module="stock" to="/stock/batches" icon={AlertTriangle} label="Expiring this week" value={s ? int(s.expiring_batches) : null} sub={s && s.negative_stock > 0 ? `${int(s.negative_stock)} item${s.negative_stock === 1 ? '' : 's'} in negative stock` : s && s.open_counts > 0 ? `${int(s.open_counts)} stock count${s.open_counts === 1 ? '' : 's'} open` : 'batches with stock left, FEFO'} tone={s && (s.expiring_batches > 0 || s.negative_stock > 0) ? 'bad' : undefined} />
        <Tile perms={perms} module="vehicles" to="/vehicles/trips" icon={Truck} label="Vehicles out" value={s ? int(s.vehicles_out) : null} sub="dispatched, not yet settled" />
        <Tile perms={perms} module="production" to="/production" icon={Factory} label="Batches open" value={s ? int(s.batches_open) : null} sub="waiting for the chief's actuals" />
      </div>
      {perms.canView('payments') && (
        <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
          <Tile perms={perms} module="payments" to="/accounts" icon={Wallet} label="Cash in hand" value={s ? money(s.cash_balance) : null} sub="cash book balance" tone={s && s.cash_balance < 0 ? 'bad' : undefined} />
          <Tile perms={perms} module="payments" to="/accounts" icon={Landmark} label="Bank" value={s ? money(s.bank_balance) : null} sub="bank book balance" tone={s && s.bank_balance < 0 ? 'bad' : undefined} />
          <Tile perms={perms} module="payments" to="/accounts/cheques" icon={FileText} label="Cheques in hand" value={s ? money(s.cheques_in_hand) : null} sub={s && s.cheques_due > 0 ? `${int(s.cheques_due)} due within 3 days` : 'received, not yet cleared'} tone={s && s.cheques_due > 0 ? 'warn' : undefined} />
          <Tile perms={perms} module="payments" to="/purchases/suppliers" icon={IndianRupee} label="Payable to suppliers" value={s ? money(s.payables) : null} sub="bills less payments" />
        </div>
      )}

      <div className="grid gap-3 lg:grid-cols-5">
        <Card className="lg:col-span-3">
          <CardHeader className="flex-row items-center justify-between space-y-0">
            <CardTitle>{isToday ? "Today's activity" : `Activity on ${dateDMY(date)}`}</CardTitle>
            <span className="text-xs text-muted-foreground">newest first</span>
          </CardHeader>
          <CardContent>
            {activity.isLoading ? <Spinner /> : activity.error ? (
              <p role="alert" className="text-sm text-destructive">{activity.error.message}</p>
            ) : !activity.data?.length ? (
              <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">Nothing entered {isToday ? 'yet today' : 'on this day'}.</p>
            ) : (
              <Table>
                <TableHeader><TableRow><TableHead className="w-24">Type</TableHead><TableHead className="w-28">No.</TableHead><TableHead>Party</TableHead><TableHead className="text-right">Amount</TableHead><TableHead className="w-28">Status</TableHead><TableHead className="w-28">Entered</TableHead></TableRow></TableHeader>
                <TableBody>
                  {activity.data.map((a, i) => {
                    const to = activityLink(a);
                    return (
                      <TableRow key={`${a.kind}-${a.doc_id ?? i}`}>
                        <TableCell><Badge variant="outline">{a.kind}</Badge></TableCell>
                        <TableCell className="font-medium">{to ? <Link to={to} className="hover:underline">{a.doc_no}</Link> : a.doc_no}</TableCell>
                        <TableCell>{a.party}</TableCell>
                        <TableCell className="num">{a.amount === null || a.amount === undefined ? '' : money(a.amount)}</TableCell>
                        <TableCell className="text-xs text-muted-foreground">{a.detail}</TableCell>
                        <TableCell className="text-xs text-muted-foreground">{dateTimeDMY(a.at)}</TableCell>
                      </TableRow>
                    );
                  })}
                </TableBody>
              </Table>
            )}
          </CardContent>
        </Card>

        <Card className="lg:col-span-2">
          <CardHeader className="flex-row items-center justify-between space-y-0">
            <CardTitle className="flex items-center gap-2"><MessageSquare className="h-4 w-4" /> Pending orders</CardTitle>
            {s && s.pending_orders > 0 && <Badge>{int(s.pending_orders)}</Badge>}
          </CardHeader>
          <CardContent>
            {!perms.canView('messaging') ? (
              <p className="text-sm text-muted-foreground">Orders arrive through Messaging; your role does not see that module.</p>
            ) : orders.isLoading ? <Spinner /> : orders.error ? (
              <p role="alert" className="text-sm text-destructive">{orders.error.message}</p>
            ) : !orders.data?.length ? (
              <p className="rounded-md border border-dashed p-6 text-center text-sm text-muted-foreground">No new orders. WhatsApp and call orders land here; <Link to="/messaging" className="text-primary hover:underline">Messaging</Link> has the full queue.</p>
            ) : (
              <ul className="divide-y">
                {orders.data.map((o) => (
                  <li key={o.id ?? ''} className="flex items-start justify-between gap-2 py-2 text-sm">
                    <div className="min-w-0">
                      <div className="font-medium">{o.customer_name ?? o.mobile1 ?? 'Unknown sender'}{o.customer_town ? <span className="text-muted-foreground"> · {o.customer_town}</span> : null}</div>
                      <div className="truncate text-xs text-muted-foreground">{o.raw_text ?? (o.audio_url ? 'Voice note' : '')}</div>
                      <div className="text-xs text-muted-foreground">{dateTimeDMY(o.created_at)} · {o.source}</div>
                    </div>
                    <Button asChild size="sm" variant="outline"><Link to={`/messaging/orders/${o.id}`}>Open <ArrowRight /></Link></Button>
                  </li>
                ))}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </div>
  );
}

function Tile({ perms, module, to, icon: Icon, label, value, sub, tone }: {
  perms: ReturnType<typeof usePermissions>;
  module: ModuleKey;
  to: string;
  icon: typeof FileText;
  label: string;
  value: string | null;
  sub: ReactNode;
  tone?: 'warn' | 'bad';
}) {
  const allowed = perms.canView(module);
  const body = (
    <Card className={cn('h-full transition-colors', allowed && 'hover:border-primary/60', tone === 'warn' && 'border-amber-300 bg-amber-50/40', tone === 'bad' && 'border-red-300 bg-red-50/40')}>
      <CardContent className="p-4">
        <div className="flex items-center justify-between text-xs uppercase tracking-wide text-muted-foreground"><span>{label}</span><Icon className="h-4 w-4" /></div>
        <div className={cn('mt-1 text-2xl font-semibold tabular-nums', tone === 'bad' && 'text-destructive')}>{value ?? <span className="text-muted-foreground">…</span>}</div>
        <div className="text-xs text-muted-foreground">{sub}</div>
      </CardContent>
    </Card>
  );
  return allowed ? <Link to={to} className="block">{body}</Link> : body;
}
