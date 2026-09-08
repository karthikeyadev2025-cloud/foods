import { useQuery } from '@tanstack/react-query';
import { NavLink, useParams } from 'react-router-dom';
import { PageHeader } from '@/components/PageHeader';
import { cn } from '@/lib/utils';
import { listInboundOrders } from '../api';
import { BroadcastsPanel } from '../components/BroadcastsPanel';
import { CatalogsPanel } from '../components/CatalogsPanel';
import { LogPanel } from '../components/LogPanel';
import { NewStockPanel } from '../components/NewStockPanel';
import { OrdersQueue } from '../components/OrdersQueue';
import { RemindersPanel, TemplatesPanel } from '../components/panels';
import { SettingsPanel } from '../components/SettingsPanel';

const TABS = [
  { key: 'orders', label: 'Orders' },
  { key: 'templates', label: 'Templates' },
  { key: 'reminders', label: 'Reminders' },
  { key: 'stock', label: 'New stock' },
  { key: 'catalogs', label: 'Catalogs' },
  { key: 'broadcasts', label: 'Broadcasts' },
  { key: 'log', label: 'Log' },
  { key: 'settings', label: 'Settings' },
] as const;
type Tab = (typeof TABS)[number]['key'];

/** T6 — Hey Nikki: WhatsApp orders in, reminders / stock / catalog messages out. */
export function MessagingPage() {
  const { tab: param } = useParams();
  const tab: Tab = TABS.some((t) => t.key === param) ? (param as Tab) : 'orders';
  const pending = useQuery({ queryKey: ['messaging', 'orders', 'new'], queryFn: () => listInboundOrders('new'), refetchInterval: 30_000 });
  const count = pending.data?.length ?? 0;

  return (
    <div className="space-y-3">
      <PageHeader title="Messaging" description="Hey Nikki sends, listens and transcribes; the ERP keeps every order and every message. A person confirms each order." />
      <nav className="flex flex-wrap gap-1 border-b" aria-label="Messaging">
        {TABS.map((t) => (
          <NavLink key={t.key} to={t.key === 'orders' ? '/messaging' : `/messaging/${t.key}`} end className={({ isActive }) => cn('-mb-px flex items-center gap-1 border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
            {t.label}
            {t.key === 'orders' && count > 0 && <span className="rounded-full bg-primary px-1.5 text-[10px] font-semibold text-primary-foreground">{count}</span>}
          </NavLink>
        ))}
      </nav>
      {tab === 'orders' && <OrdersQueue />}
      {tab === 'templates' && <TemplatesPanel />}
      {tab === 'reminders' && <RemindersPanel />}
      {tab === 'stock' && <NewStockPanel />}
      {tab === 'catalogs' && <CatalogsPanel />}
      {tab === 'broadcasts' && <BroadcastsPanel />}
      {tab === 'log' && <LogPanel />}
      {tab === 'settings' && <SettingsPanel />}
    </div>
  );
}
