import { NavLink, useParams } from 'react-router-dom';
import { PageHeader } from '@/components/PageHeader';
import { cn } from '@/lib/utils';
import { CashBankPanel } from '../components/CashBankPanel';
import { ChequesPanel } from '../components/ChequesPanel';
import { ChartPanel, JournalPanel } from '../components/JournalPanel';
import { BalanceSheetReport, CashFlowReport, DayBookReport, ItemProfitReport, PnlReport, TrialBalanceReport } from '../components/reports';

const TABS = [
  { key: 'cash-bank', label: 'Cash & bank' },
  { key: 'cheques', label: 'Cheques' },
  { key: 'journal', label: 'Journal' },
  { key: 'chart', label: 'Chart of accounts' },
  { key: 'trial-balance', label: 'Trial balance' },
  { key: 'pnl', label: 'Profit & loss' },
  { key: 'balance-sheet', label: 'Balance sheet' },
  { key: 'day-book', label: 'Day book' },
  { key: 'cash-flow', label: 'Cash flow' },
  { key: 'item-profit', label: 'Item profit' },
] as const;
type Tab = (typeof TABS)[number]['key'];

/** T7 — money. Everything here reads the one journal the documents post to. */
export function AccountsPage() {
  const { tab: param } = useParams();
  const tab: Tab = TABS.some((t) => t.key === param) ? (param as Tab) : 'cash-bank';
  return (
    <div className="space-y-3">
      <PageHeader title="Accounts" description="Cash and bank books, cheques, the journal and the financial statements. If the trial balance is not zero, a posting rule is wrong — say so." />
      <nav className="no-print flex flex-wrap gap-1 border-b" aria-label="Accounts">
        {TABS.map((t) => (
          <NavLink key={t.key} to={t.key === 'cash-bank' ? '/accounts' : `/accounts/${t.key}`} end className={({ isActive }) => cn('-mb-px border-b-2 px-3 py-1.5 text-sm', isActive ? 'border-primary font-medium text-primary' : 'border-transparent text-muted-foreground hover:text-foreground')}>
            {t.label}
          </NavLink>
        ))}
      </nav>
      {tab === 'cash-bank' && <CashBankPanel />}
      {tab === 'cheques' && <ChequesPanel />}
      {tab === 'journal' && <JournalPanel />}
      {tab === 'chart' && <ChartPanel />}
      {tab === 'trial-balance' && <TrialBalanceReport />}
      {tab === 'pnl' && <PnlReport />}
      {tab === 'balance-sheet' && <BalanceSheetReport />}
      {tab === 'day-book' && <DayBookReport />}
      {tab === 'cash-flow' && <CashFlowReport />}
      {tab === 'item-profit' && <ItemProfitReport />}
    </div>
  );
}
