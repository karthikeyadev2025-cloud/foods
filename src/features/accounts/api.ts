import { currentOrgId } from '@/features/auth/api';
import { expectOk, expectOne, expectRows, supabase } from '@/lib/supabase';
import { orIlike } from '@/lib/search';
import type { Database } from '@/types/supabase';

type Tables = Database['public']['Tables'];
type Views = Database['public']['Views'];
type Fns = Database['public']['Functions'];

export type CashBankAccount = Tables['cash_bank_accounts']['Row'];
export type CashBankAccountRow = Views['v_cash_bank_accounts']['Row'];
export type AccountKind = Database['public']['Enums']['account_kind'];
export type TransferRow = Views['v_account_transfers']['Row'];
export type ChequeRow = Views['v_cheques']['Row'];
export type ChequeState = Database['public']['Enums']['cheque_state'];
export type LedgerAccount = Tables['ledger_accounts']['Row'];
export type LedgerAccountRow = Views['v_ledger_accounts']['Row'];
export type AccountType = Database['public']['Enums']['account_type'];
export type JournalEntryRow = Views['v_journal_entries']['Row'];
export type JournalLineRow = Views['v_journal_lines']['Row'];
export type BookRow = Fns['account_book']['Returns'][number];
export type LedgerBookRow = Fns['ledger_account_book']['Returns'][number];
export type TrialBalanceRow = Fns['trial_balance']['Returns'][number];
export type PnlRow = Fns['profit_and_loss']['Returns'][number];
export type BalanceSheetRow = Fns['balance_sheet']['Returns'][number];
export type DayBookRow = Fns['day_book']['Returns'][number];
export type CashFlowRow = Fns['cash_flow']['Returns'][number];
export type ItemProfitRow = Fns['item_profit']['Returns'][number];

export const chequeTone: Record<ChequeState, 'default' | 'secondary' | 'destructive' | 'outline'> = {
  in_hand: 'default',
  deposited: 'secondary',
  cleared: 'outline',
  bounced: 'destructive',
  cancelled: 'destructive',
};

// ---------------- cash & bank ----------------
export function listCashBankAccounts(): Promise<CashBankAccountRow[]> {
  return expectRows(supabase.from('v_cash_bank_accounts').select('*').order('kind').order('name'));
}

export const cashBankApi = {
  create: async (v: Omit<Tables['cash_bank_accounts']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('cash_bank_accounts').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['cash_bank_accounts']['Update']) =>
    expectOne(supabase.from('cash_bank_accounts').update(v).eq('id', id).select('*').single()),
};

export async function accountBook(accountId: string, from?: string, to?: string): Promise<BookRow[]> {
  const { data, error } = await supabase.rpc('account_book', { p_account: accountId, p_from: from || undefined, p_to: to || undefined });
  if (error) throw error;
  return data ?? [];
}

export type TransferInput = { from_account: string; to_account: string; amount: number; txn_date: string; narration?: string | null };

export async function saveTransfer(input: TransferInput): Promise<string> {
  const { data, error } = await supabase.rpc('save_transfer', { p: { ...input } });
  if (error) throw error;
  return data;
}

export function listTransfers(): Promise<TransferRow[]> {
  return expectRows(supabase.from('v_account_transfers').select('*').order('txn_date', { ascending: false }).limit(100));
}

// ---------------- cheques ----------------
export function listCheques(opts: { state?: ChequeState | ''; direction?: 'received' | 'issued' | ''; dueOnly?: boolean } = {}): Promise<ChequeRow[]> {
  let query = supabase.from('v_cheques').select('*');
  if (opts.state) query = query.eq('state', opts.state);
  if (opts.direction) query = query.eq('direction', opts.direction);
  if (opts.dueOnly) query = query.eq('is_due', true);
  return expectRows(query.order('cheque_date').order('created_at', { ascending: false }).limit(500));
}

export async function depositCheque(id: string, accountId: string, date: string): Promise<void> {
  const { error } = await supabase.rpc('deposit_cheque', { p_cheque: id, p_account: accountId, p_date: date });
  if (error) throw error;
}

export async function clearCheque(id: string, date: string): Promise<void> {
  const { error } = await supabase.rpc('clear_cheque', { p_cheque: id, p_date: date });
  if (error) throw error;
}

export async function bounceCheque(id: string, date: string, charges: number, cancel: boolean): Promise<string> {
  const { data, error } = await supabase.rpc('bounce_cheque', { p_cheque: id, p_date: date, p_charges: charges, p_cancel: cancel });
  if (error) throw error;
  return data;
}

// ---------------- chart of accounts & journal ----------------
export function listLedgerAccounts(): Promise<LedgerAccountRow[]> {
  return expectRows(supabase.from('v_ledger_accounts').select('*').order('type').order('code').order('name'));
}

export const ledgerAccountsApi = {
  list: listLedgerAccounts,
  create: async (v: Omit<Tables['ledger_accounts']['Insert'], 'org_id'>) =>
    expectOne(supabase.from('ledger_accounts').insert({ ...v, org_id: await currentOrgId() }).select('*').single()),
  update: (id: string, v: Tables['ledger_accounts']['Update']) =>
    expectOne(supabase.from('ledger_accounts').update(v).eq('id', id).select('*').single()),
  remove: (id: string) => expectOk(supabase.from('ledger_accounts').delete().eq('id', id)),
};

export function listJournalEntries(opts: { from?: string; to?: string; manualOnly?: boolean; search?: string } = {}): Promise<JournalEntryRow[]> {
  let query = supabase.from('v_journal_entries').select('*');
  if (opts.from) query = query.gte('entry_date', opts.from);
  if (opts.to) query = query.lte('entry_date', opts.to);
  if (opts.manualOnly) query = query.eq('is_manual', true);
  query = orIlike(query, ['entry_no', 'narration', 'doc_no'], opts.search);
  return expectRows(query.order('entry_date', { ascending: false }).order('created_at', { ascending: false }).limit(300));
}

export function getJournalLines(entryId: string): Promise<JournalLineRow[]> {
  return expectRows(supabase.from('v_journal_lines').select('*').eq('entry_id', entryId).order('debit', { ascending: false }).order('id'));
}

export type ManualLine = { account_id: string; debit: number; credit: number; narration?: string | null; cash_account_id?: string | null };

export async function saveManualJournal(input: { entry_date: string; narration: string; lines: ManualLine[] }): Promise<string> {
  const { data, error } = await supabase.rpc('save_manual_journal', { p: { ...input, lines: input.lines.map((l) => ({ ...l })) } });
  if (error) throw error;
  return data;
}

export async function reverseManualJournal(entryId: string, date: string): Promise<string> {
  const { data, error } = await supabase.rpc('reverse_manual_journal', { p_entry: entryId, p_date: date });
  if (error) throw error;
  return data;
}

export async function ledgerAccountBook(accountId: string, from?: string, to?: string): Promise<LedgerBookRow[]> {
  const { data, error } = await supabase.rpc('ledger_account_book', { p_account: accountId, p_from: from || undefined, p_to: to || undefined });
  if (error) throw error;
  return data ?? [];
}

// ---------------- reports ----------------
export async function trialBalance(orgId: string, from?: string, to?: string): Promise<TrialBalanceRow[]> {
  const { data, error } = await supabase.rpc('trial_balance', { p_org: orgId, p_from: from || undefined, p_to: to || undefined });
  if (error) throw error;
  return data ?? [];
}

export async function profitAndLoss(orgId: string, from: string, to: string): Promise<PnlRow[]> {
  const { data, error } = await supabase.rpc('profit_and_loss', { p_org: orgId, p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

export async function balanceSheet(orgId: string, asOn: string): Promise<BalanceSheetRow[]> {
  const { data, error } = await supabase.rpc('balance_sheet', { p_org: orgId, p_as_on: asOn });
  if (error) throw error;
  return data ?? [];
}

export async function dayBook(orgId: string, date: string): Promise<DayBookRow[]> {
  const { data, error } = await supabase.rpc('day_book', { p_org: orgId, p_date: date });
  if (error) throw error;
  return data ?? [];
}

export async function cashFlow(orgId: string, from: string, to: string): Promise<CashFlowRow[]> {
  const { data, error } = await supabase.rpc('cash_flow', { p_org: orgId, p_from: from, p_to: to });
  if (error) throw error;
  return data ?? [];
}

export async function itemProfit(orgId: string, from: string, to: string, group: 'item' | 'section'): Promise<ItemProfitRow[]> {
  const { data, error } = await supabase.rpc('item_profit', { p_org: orgId, p_from: from, p_to: to, p_group: group });
  if (error) throw error;
  return data ?? [];
}
