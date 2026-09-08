-- ============================================================
-- JYOTHI FOODS ERP — 14: ACCOUNTING & MONEY (T7)
-- Cash & bank books, transfers, cheques, chart of accounts,
-- manual journal, and the financial reports — all read from the
-- same journal the documents already post to. The acceptance
-- test is trial_balance_check() = 0 at every step.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Cash & bank accounts. Every rupee in or out of one is an
--    account_transactions row (the cash book / bank book); the
--    journal keeps the CASH / BANK control totals.
-- ------------------------------------------------------------
alter table receipt_modes
  add column if not exists is_cheque boolean not null default false,
  add column if not exists account_id uuid references cash_bank_accounts(id) on delete set null;
alter table receipts add column if not exists reversal_of uuid references receipts(id);
alter table payments add column if not exists reversal_of uuid references payments(id);
alter table cheques
  add column if not exists deposited_on date,
  add column if not exists bounced_on date,
  add column if not exists mode_id uuid references receipt_modes(id),
  add column if not exists created_at timestamptz not null default now();
alter table journal_lines add column if not exists cash_account_id uuid references cash_bank_accounts(id);
alter table account_transfers add column if not exists transfer_no text;
alter table journal_entries add column if not exists reversed_by uuid references journal_entries(id);

create or replace function ensure_system_accounts(p_org uuid)
returns void language sql as $$
  insert into ledger_accounts (org_id, code, name, type, is_system)
  values
    (p_org, 'CASH',            'Cash in hand',              'asset',     true),
    (p_org, 'BANK',            'Bank',                      'asset',     true),
    (p_org, 'CHEQUES_IN_HAND', 'Cheques in hand',           'asset',     true),
    (p_org, 'DEBTORS',         'Sundry debtors',            'asset',     true),
    (p_org, 'CREDITORS',       'Sundry creditors',          'liability', true),
    (p_org, 'CHEQUES_ISSUED',  'Cheques issued',            'liability', true),
    (p_org, 'CAPITAL',         'Capital',                   'equity',    true),
    (p_org, 'SALES',           'Sales',                     'income',    true),
    (p_org, 'FREIGHT',         'Freight recovered',         'income',    true),
    (p_org, 'ROUND_OFF',       'Round off',                 'income',    true),
    (p_org, 'SALES_RETURNS',   'Sales returns',             'income',    true),
    (p_org, 'RATE_DIFF',       'Rate difference allowed',   'income',    true),
    (p_org, 'OTHER_INCOME',    'Other income',              'income',    true),
    (p_org, 'DISCOUNT',        'Discount allowed',          'expense',   true),
    (p_org, 'BREAKAGE',        'Breakage / damage',         'expense',   true),
    (p_org, 'PURCHASES',       'Purchases',                 'expense',   true),
    (p_org, 'WAGES',           'Labour & wages',            'expense',   true),
    (p_org, 'EXPENSES',        'General expenses',          'expense',   true),
    (p_org, 'BANK_CHARGES',    'Bank charges',              'expense',   true)
  on conflict (org_id, name) do nothing;
$$;

/** One cash and one bank account exist for every org that moves money. */
create or replace function ensure_default_accounts(p_org uuid) returns void
language plpgsql as $$
begin
  if not exists (select 1 from cash_bank_accounts where org_id = p_org and kind = 'cash') then
    insert into cash_bank_accounts (org_id, name, kind) values (p_org, 'Cash in hand', 'cash');
  end if;
  if not exists (select 1 from cash_bank_accounts where org_id = p_org and kind = 'bank') then
    insert into cash_bank_accounts (org_id, name, kind) values (p_org, 'Bank', 'bank');
  end if;
end $$;

/** Which cash/bank account a mode lands in: explicit → the mode's own → the first active of its kind. */
create or replace function money_account(p_org uuid, p_mode_code text, p_mode_account uuid, p_explicit uuid default null)
returns uuid language plpgsql as $$
declare v_kind account_kind; v_id uuid;
begin
  if p_explicit is not null then return p_explicit; end if;
  if p_mode_account is not null then return p_mode_account; end if;
  perform ensure_default_accounts(p_org);
  v_kind := case when upper(coalesce(p_mode_code, '')) = 'CASH' then 'cash' else 'bank' end;
  select id into v_id from cash_bank_accounts where org_id = p_org and kind = v_kind and is_active order by name limit 1;
  if v_id is null then
    select id into v_id from cash_bank_accounts where org_id = p_org and is_active order by (kind = 'cash') desc, name limit 1;
  end if;
  return v_id;
end $$;

/** The journal control code for a cash/bank account. */
create or replace function money_code(p_account uuid) returns text
language sql stable as $$
  select case when kind = 'cash' then 'CASH' else 'BANK' end from cash_bank_accounts where id = p_account;
$$;

/** +in / −out of a cash/bank account. */
create or replace function post_money(p_org uuid, p_account uuid, p_date date, p_amount numeric, p_narration text, p_ref_table text, p_ref_id uuid)
returns bigint language plpgsql as $$
declare v_id bigint;
begin
  if p_account is null then raise exception 'No cash/bank account to post to'; end if;
  if coalesce(p_amount, 0) = 0 then return null; end if;
  insert into account_transactions (org_id, account_id, txn_date, amount, narration, ref_table, ref_id, created_by)
  values (p_org, p_account, p_date, round(p_amount, 2), p_narration, p_ref_table, p_ref_id, my_staff_id())
  returning id into v_id;
  return v_id;
end $$;

create or replace view v_cash_bank_accounts as
select a.*, a.opening_balance + coalesce((select sum(t.amount) from account_transactions t where t.account_id = a.id), 0) as balance,
       (select max(t.txn_date) from account_transactions t where t.account_id = a.id) as last_txn_date,
       (select count(*) from cheques c where c.account_id = a.id and c.state = 'deposited') as cheques_pending
  from cash_bank_accounts a;
alter view v_cash_bank_accounts set (security_invoker = on);

-- ------------------------------------------------------------
-- 2. Receipts and payments now say WHICH account the money went
--    to, and a cheque mode books the cheque instead of the bank.
--    Same signatures as 09; same journal shape plus cheques.
-- ------------------------------------------------------------
create or replace function save_receipt(p_header jsonb, p_lines jsonb, p_allocations jsonb default '[]'::jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_cust uuid; v_date date; v_total numeric := 0; l jsonb; n int := 0;
  m receipt_modes%rowtype; v_remaining numeric; inv record; v_alloc numeric; v_cust_name text; v_no text;
  v_lines jsonb := '[]'::jsonb; v_amt numeric; v_acct uuid; v_ref text; v_line_id uuid;
begin
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'A receipt needs at least one mode line';
  end if;
  v_cust := (p_header->>'customer_id')::uuid;
  v_date := coalesce(nullif(p_header->>'receipt_date','')::date, current_date);
  select name into v_cust_name from customers where id = v_cust and org_id = v_org;
  if v_cust_name is null then raise exception 'Customer not found'; end if;

  v_no := next_doc_no(v_org, 'receipt');
  insert into receipts (org_id, receipt_no, customer_id, receipt_date, vehicle_id, trip_id, narration, created_by, account_id)
  values (v_org, v_no, v_cust, v_date, nullif(p_header->>'vehicle_id','')::uuid, nullif(p_header->>'trip_id','')::uuid,
          nullif(p_header->>'narration',''), my_staff_id(), nullif(p_header->>'account_id','')::uuid)
  returning id into v_id;

  for l in select * from jsonb_array_elements(p_lines) loop
    n := n + 1;
    select * into m from receipt_modes where id = (l->>'mode_id')::uuid and org_id = v_org;
    if not found then raise exception 'Line %: receipt mode not found', n; end if;
    v_amt := coalesce((l->>'amount')::numeric, 0);
    if v_amt <= 0 then raise exception 'Line % (%): amount must be greater than zero', n, m.code; end if;
    v_ref := nullif(trim(coalesce(l->>'reference','')), '');
    if (m.needs_reference or m.is_cheque) and v_ref is null then
      raise exception 'Line % (%): a % number is required', n, m.code, case when m.is_cheque then 'cheque' else 'reference' end;
    end if;
    insert into receipt_lines (receipt_id, mode_id, amount, reference) values (v_id, m.id, v_amt, v_ref) returning id into v_line_id;
    v_total := v_total + v_amt;

    if not m.is_collection then
      -- a deduction head (BRK, ADJ) reduces the bill: its expense takes the debit
      v_lines := v_lines || jsonb_build_object('account', case when upper(m.code) = 'BRK' then 'BREAKAGE' else 'DISCOUNT' end, 'debit', v_amt, 'narration', m.code);
    elsif m.is_cheque then
      -- the cheque is an asset until it clears; the bank sees nothing yet
      insert into cheques (org_id, direction, party_kind, customer_id, cheque_no, cheque_date, bank_name, amount, state, mode_id, ref_table, ref_id, notes)
      values (v_org, 'received', 'customer', v_cust, v_ref, coalesce(nullif(l->>'cheque_date','')::date, v_date), nullif(l->>'bank_name',''),
              v_amt, 'in_hand', m.id, 'receipts', v_id, format('Receipt %s', v_no));
      v_lines := v_lines || jsonb_build_object('account', 'CHEQUES_IN_HAND', 'debit', v_amt, 'narration', m.code || ' ' || v_ref);
    else
      v_acct := money_account(v_org, m.code, m.account_id, coalesce(nullif(l->>'account_id','')::uuid, nullif(p_header->>'account_id','')::uuid));
      perform post_money(v_org, v_acct, v_date, v_amt, format('Receipt %s — %s (%s)', v_no, v_cust_name, m.code), 'receipts', v_id);
      v_lines := v_lines || jsonb_build_object('account', money_code(v_acct), 'debit', v_amt, 'narration', m.code);
    end if;
  end loop;
  update receipts set total_amount = round(v_total, 2) where id = v_id;

  v_remaining := v_total;
  if jsonb_typeof(p_allocations) = 'array' and jsonb_array_length(p_allocations) > 0 then
    for l in select * from jsonb_array_elements(p_allocations) loop
      v_alloc := coalesce((l->>'amount')::numeric, 0);
      if v_alloc <= 0 then continue; end if;
      select * into inv from v_invoice_balance where invoice_id = (l->>'invoice_id')::uuid and customer_id = v_cust;
      if not found then raise exception 'Allocation to an invoice that is not this customer''s'; end if;
      if inv.status in ('draft','cancelled') then raise exception 'Cannot allocate to a % invoice', inv.status; end if;
      if v_alloc > inv.balance + 0.005 then
        raise exception 'Allocation % to invoice % exceeds its balance %', v_alloc, inv.invoice_no, inv.balance;
      end if;
      if v_alloc > v_remaining + 0.005 then raise exception 'Allocations exceed the receipt total'; end if;
      insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, inv.invoice_id, round(v_alloc, 2));
      v_remaining := v_remaining - v_alloc;
    end loop;
  else
    for inv in
      select * from v_invoice_balance
       where customer_id = v_cust and status not in ('draft','cancelled') and balance > 0
       order by invoice_date, invoice_no
    loop
      exit when v_remaining <= 0;
      v_alloc := least(v_remaining, inv.balance);
      insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_id, inv.invoice_id, round(v_alloc, 2));
      v_remaining := v_remaining - v_alloc;
    end loop;
  end if;

  perform post_journal(v_org, v_date, format('Receipt %s — %s', v_no, v_cust_name), 'receipts', v_id,
    v_lines || jsonb_build_object('account', 'DEBTORS', 'credit', round(v_total, 2)));
  return v_id;
end $$;

create or replace function save_payment(p jsonb)
returns uuid language plpgsql as $$
declare
  v_org uuid := my_org_id(); v_id uuid; v_amt numeric; v_date date; m receipt_modes%rowtype;
  v_sup uuid := nullif(p->>'supplier_id','')::uuid; v_staff uuid := nullif(p->>'staff_id','')::uuid; v_head uuid := nullif(p->>'expense_head_id','')::uuid;
  v_party text; v_no text; v_acct_code text; v_acct uuid; v_ref text; v_credit jsonb;
begin
  if (v_sup is not null)::int + (v_staff is not null)::int + (v_head is not null)::int <> 1 then
    raise exception 'A payment goes to exactly one of: supplier, staff member, expense head';
  end if;
  v_amt := coalesce((p->>'amount')::numeric, 0);
  if v_amt <= 0 then raise exception 'Amount must be greater than zero'; end if;
  v_date := coalesce(nullif(p->>'payment_date','')::date, current_date);
  select * into m from receipt_modes where id = nullif(p->>'mode_id','')::uuid and org_id = v_org;
  if not found then raise exception 'Choose how it was paid (mode)'; end if;
  if not m.is_collection then raise exception '% is a deduction head, not a way to pay', m.code; end if;
  v_ref := nullif(trim(coalesce(p->>'reference','')), '');
  if (m.needs_reference or m.is_cheque) and v_ref is null then
    raise exception '% needs a % number', m.code, case when m.is_cheque then 'cheque' else 'reference' end;
  end if;

  select coalesce(s.name, st.full_name, e.name), case when v_sup is not null then 'CREDITORS' when v_staff is not null then 'WAGES' else 'EXPENSES' end
    into v_party, v_acct_code
  from (select 1) x
  left join suppliers s on s.id = v_sup
  left join staff st on st.id = v_staff
  left join expense_heads e on e.id = v_head;

  v_no := next_doc_no(v_org, 'payment');
  v_acct := case when m.is_cheque then null else money_account(v_org, m.code, m.account_id, nullif(p->>'account_id','')::uuid) end;
  insert into payments (org_id, payment_no, supplier_id, staff_id, expense_head_id, payment_date, mode_id, amount, reference, narration, created_by, account_id)
  values (v_org, v_no, v_sup, v_staff, v_head, v_date, m.id, round(v_amt, 2), v_ref, nullif(p->>'narration',''), my_staff_id(), v_acct)
  returning id into v_id;

  if m.is_cheque then
    insert into cheques (org_id, direction, party_kind, supplier_id, cheque_no, cheque_date, bank_name, amount, state, mode_id, account_id, ref_table, ref_id, notes)
    values (v_org, 'issued', case when v_sup is not null then 'supplier' when v_staff is not null then 'staff' else 'expense' end, v_sup, v_ref,
            coalesce(nullif(p->>'cheque_date','')::date, v_date), nullif(p->>'bank_name',''), round(v_amt, 2), 'in_hand', m.id,
            money_account(v_org, 'BANK', m.account_id, nullif(p->>'account_id','')::uuid), 'payments', v_id, format('Payment %s — %s', v_no, v_party));
    v_credit := jsonb_build_object('account', 'CHEQUES_ISSUED', 'credit', round(v_amt, 2), 'narration', m.code || ' ' || v_ref);
  else
    perform post_money(v_org, v_acct, v_date, -v_amt, format('Payment %s — %s (%s)', v_no, v_party, m.code), 'payments', v_id);
    v_credit := jsonb_build_object('account', money_code(v_acct), 'credit', round(v_amt, 2), 'narration', m.code);
  end if;

  perform post_journal(v_org, v_date, format('Payment %s — %s', v_no, v_party), 'payments', v_id,
    jsonb_build_array(jsonb_build_object('account', v_acct_code, 'debit', round(v_amt, 2)), v_credit));
  return v_id;
end $$;

-- A purchase paid on the spot leaves the cash account (09 already credits CASH in the journal).
create or replace function t_purchase_money() returns trigger language plpgsql as $$
begin
  if new.paid_amount > 0 then
    perform post_money(new.org_id, money_account(new.org_id, 'CASH', null), new.bill_date, -new.paid_amount,
      format('Purchase %s paid', coalesce(new.bill_no, '')), 'purchases', new.id);
  end if;
  return null;
end $$;
drop trigger if exists t_purchase_money on purchases;
create trigger t_purchase_money after insert on purchases for each row execute function t_purchase_money();

-- ------------------------------------------------------------
-- 3. Transfers between accounts (cash → bank, bank → bank).
-- ------------------------------------------------------------
create or replace function save_transfer(p jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_id uuid; v_from uuid; v_to uuid; v_amt numeric; v_date date; v_no text; v_fc text; v_tc text; v_fn text; v_tn text;
begin
  v_from := (p->>'from_account')::uuid; v_to := (p->>'to_account')::uuid;
  v_amt := coalesce((p->>'amount')::numeric, 0);
  v_date := coalesce(nullif(p->>'txn_date','')::date, current_date);
  if v_from is null or v_to is null or v_from = v_to then raise exception 'Pick two different accounts'; end if;
  if v_amt <= 0 then raise exception 'Amount must be greater than zero'; end if;
  select name into v_fn from cash_bank_accounts where id = v_from and org_id = v_org;
  select name into v_tn from cash_bank_accounts where id = v_to and org_id = v_org;
  if v_fn is null or v_tn is null then raise exception 'Account not found'; end if;
  v_no := next_doc_no(v_org, 'transfer');
  insert into account_transfers (org_id, from_account, to_account, txn_date, amount, narration, created_by, transfer_no)
  values (v_org, v_from, v_to, v_date, round(v_amt, 2), nullif(p->>'narration',''), my_staff_id(), v_no)
  returning id into v_id;
  perform post_money(v_org, v_from, v_date, -v_amt, format('Transfer %s to %s', v_no, v_tn), 'account_transfers', v_id);
  perform post_money(v_org, v_to,   v_date,  v_amt, format('Transfer %s from %s', v_no, v_fn), 'account_transfers', v_id);
  v_fc := money_code(v_from); v_tc := money_code(v_to);
  if v_fc <> v_tc then
    perform post_journal(v_org, v_date, format('Transfer %s — %s → %s', v_no, v_fn, v_tn), 'account_transfers', v_id,
      jsonb_build_array(jsonb_build_object('account', v_tc, 'debit', v_amt), jsonb_build_object('account', v_fc, 'credit', v_amt)));
  end if;
  return v_id;
end $$;

create or replace view v_account_transfers as
select t.*, f.name as from_name, g.name as to_name, st.full_name as created_by_name
  from account_transfers t
  join cash_bank_accounts f on f.id = t.from_account
  join cash_bank_accounts g on g.id = t.to_account
  left join staff st on st.id = t.created_by;
alter view v_account_transfers set (security_invoker = on);

-- ------------------------------------------------------------
-- 4. Cheques: in hand → deposited → cleared / bounced. A bounce
--    is a new row (a reversal receipt or payment), never an edit.
-- ------------------------------------------------------------
create or replace view v_cheques as
select c.*, coalesce(cu.name, s.name, c.notes) as party_name, cu.town as party_town, a.name as account_name, m.code as mode_code,
       case when c.ref_table = 'receipts' then (select receipt_no from receipts where id = c.ref_id)
            when c.ref_table = 'payments' then (select payment_no from payments where id = c.ref_id) end as doc_no,
       (c.cheque_date - current_date) as days_to_date,
       (c.state in ('in_hand', 'deposited') and c.cheque_date <= current_date + 3) as is_due
  from cheques c
  left join customers cu on cu.id = c.customer_id
  left join suppliers s on s.id = c.supplier_id
  left join cash_bank_accounts a on a.id = c.account_id
  left join receipt_modes m on m.id = c.mode_id;
alter view v_cheques set (security_invoker = on);

create or replace function deposit_cheque(p_cheque uuid, p_account uuid, p_date date default current_date) returns void
language plpgsql as $$
declare c cheques%rowtype;
begin
  select * into c from cheques where id = p_cheque for update;
  if not found then raise exception 'Cheque not found'; end if;
  if c.direction <> 'received' or c.state <> 'in_hand' then raise exception 'Only a received cheque in hand can be deposited (this one is % %)', c.direction, c.state; end if;
  if not exists (select 1 from cash_bank_accounts where id = p_account and org_id = c.org_id and kind <> 'cash') then raise exception 'Deposit into a bank account'; end if;
  update cheques set state = 'deposited', account_id = p_account, deposited_on = p_date where id = p_cheque;
end $$;

create or replace function clear_cheque(p_cheque uuid, p_date date default current_date) returns void
language plpgsql as $$
declare c cheques%rowtype; v_acct uuid;
begin
  select * into c from cheques where id = p_cheque for update;
  if not found then raise exception 'Cheque not found'; end if;
  if c.state not in ('in_hand', 'deposited') then raise exception 'Cheque is already %', c.state; end if;
  if c.direction = 'received' and c.state = 'in_hand' then raise exception 'Deposit the cheque first'; end if;
  v_acct := coalesce(c.account_id, money_account(c.org_id, 'BANK', null));
  if c.direction = 'received' then
    perform post_money(c.org_id, v_acct, p_date, c.amount, format('Cheque %s cleared — %s', c.cheque_no, c.notes), 'cheques', c.id);
    perform post_journal(c.org_id, p_date, format('Cheque %s cleared', c.cheque_no), 'cheques', c.id,
      jsonb_build_array(jsonb_build_object('account', money_code(v_acct), 'debit', c.amount), jsonb_build_object('account', 'CHEQUES_IN_HAND', 'credit', c.amount)));
  else
    perform post_money(c.org_id, v_acct, p_date, -c.amount, format('Cheque %s cleared — %s', c.cheque_no, c.notes), 'cheques', c.id);
    perform post_journal(c.org_id, p_date, format('Cheque %s cleared', c.cheque_no), 'cheques', c.id,
      jsonb_build_array(jsonb_build_object('account', 'CHEQUES_ISSUED', 'debit', c.amount), jsonb_build_object('account', money_code(v_acct), 'credit', c.amount)));
  end if;
  update cheques set state = 'cleared', cleared_on = p_date, account_id = v_acct where id = p_cheque;
end $$;

/**
 * Bounced (or cancelled before presenting): the money never arrived, so the customer
 * owes again — a reversal receipt with a negative amount undoes the collection and its
 * allocations; an issued cheque puts the supplier back on the creditors ledger.
 */
create or replace function bounce_cheque(p_cheque uuid, p_date date default current_date, p_charges numeric default 0, p_cancel boolean default false) returns uuid
language plpgsql as $$
declare c cheques%rowtype; r receipts%rowtype; pm payments%rowtype; v_new uuid; v_left numeric; a record; v_alloc numeric; v_acct uuid; v_code text; v_state cheque_state;
begin
  select * into c from cheques where id = p_cheque for update;
  if not found then raise exception 'Cheque not found'; end if;
  if c.state not in ('in_hand', 'deposited') then raise exception 'Cheque is already %', c.state; end if;
  v_state := case when p_cancel then 'cancelled' else 'bounced' end;

  if c.direction = 'received' then
    select * into r from receipts where id = c.ref_id;
    insert into receipts (org_id, receipt_no, customer_id, receipt_date, narration, created_by, total_amount, reversal_of)
    values (c.org_id, next_doc_no(c.org_id, 'receipt'), c.customer_id, p_date,
            format('Cheque %s %s (against %s)', c.cheque_no, v_state, r.receipt_no), my_staff_id(), -c.amount, r.id)
    returning id into v_new;
    insert into receipt_lines (receipt_id, mode_id, amount, reference) values (v_new, c.mode_id, -c.amount, c.cheque_no);
    -- give the bills back: undo this receipt's allocations, newest bill first, up to the cheque amount
    v_left := c.amount;
    for a in select ra.invoice_id, ra.amount from receipt_allocations ra join invoices i on i.id = ra.invoice_id
              where ra.receipt_id = r.id order by i.invoice_date desc, i.invoice_no desc loop
      exit when v_left <= 0;
      v_alloc := least(v_left, a.amount);
      insert into receipt_allocations (receipt_id, invoice_id, amount) values (v_new, a.invoice_id, -v_alloc);
      v_left := v_left - v_alloc;
    end loop;
    perform post_journal(c.org_id, p_date, format('Cheque %s %s — %s', c.cheque_no, v_state, coalesce((select name from customers where id = c.customer_id), '')), 'receipts', v_new,
      jsonb_build_array(jsonb_build_object('account', 'DEBTORS', 'debit', c.amount), jsonb_build_object('account', 'CHEQUES_IN_HAND', 'credit', c.amount)));
    if coalesce(p_charges, 0) > 0 then
      v_acct := coalesce(c.account_id, money_account(c.org_id, 'BANK', null));
      perform post_money(c.org_id, v_acct, p_date, -p_charges, format('Bank charges — cheque %s bounced', c.cheque_no), 'cheques', c.id);
      perform post_journal(c.org_id, p_date, format('Bank charges — cheque %s bounced', c.cheque_no), 'cheques', c.id,
        jsonb_build_array(jsonb_build_object('account', 'BANK_CHARGES', 'debit', p_charges), jsonb_build_object('account', money_code(v_acct), 'credit', p_charges)));
    end if;
  else
    select * into pm from payments where id = c.ref_id;
    v_code := case when pm.supplier_id is not null then 'CREDITORS' when pm.staff_id is not null then 'WAGES' else 'EXPENSES' end;
    insert into payments (org_id, payment_no, supplier_id, staff_id, expense_head_id, payment_date, mode_id, amount, reference, narration, created_by, reversal_of)
    values (c.org_id, next_doc_no(c.org_id, 'payment'), pm.supplier_id, pm.staff_id, pm.expense_head_id, p_date, pm.mode_id, -c.amount, c.cheque_no,
            format('Cheque %s %s (against %s)', c.cheque_no, v_state, pm.payment_no), my_staff_id(), pm.id)
    returning id into v_new;
    perform post_journal(c.org_id, p_date, format('Cheque %s %s', c.cheque_no, v_state), 'payments', v_new,
      jsonb_build_array(jsonb_build_object('account', 'CHEQUES_ISSUED', 'debit', c.amount), jsonb_build_object('account', v_code, 'credit', c.amount)));
  end if;
  update cheques set state = v_state, bounced_on = p_date where id = p_cheque;
  return v_new;
end $$;

-- ------------------------------------------------------------
-- 5. Cash book / bank book with running balance.
-- ------------------------------------------------------------
create or replace function account_book(p_account uuid, p_from date default null, p_to date default null)
returns table (txn_id bigint, txn_date date, doc text, doc_no text, doc_id uuid, party text, narration text, money_in numeric, money_out numeric, balance numeric)
language sql stable as $$
  with a as (select * from cash_bank_accounts where id = p_account),
  opening as (
    select a.opening_balance + coalesce((select sum(t.amount) from account_transactions t where t.account_id = a.id and p_from is not null and t.txn_date < p_from), 0) as bal
      from a),
  rows as (
    select t.id, t.txn_date,
           case t.ref_table when 'receipts' then 'Receipt' when 'payments' then 'Payment' when 'purchases' then 'Purchase'
                            when 'account_transfers' then 'Transfer' when 'cheques' then 'Cheque' when 'journal_entries' then 'Journal' else coalesce(t.ref_table, 'Entry') end as doc,
           case t.ref_table when 'receipts' then (select receipt_no from receipts where id = t.ref_id)
                            when 'payments' then (select payment_no from payments where id = t.ref_id)
                            when 'purchases' then (select bill_no from purchases where id = t.ref_id)
                            when 'account_transfers' then (select transfer_no from account_transfers where id = t.ref_id)
                            when 'cheques' then (select cheque_no from cheques where id = t.ref_id)
                            when 'journal_entries' then (select entry_no from journal_entries where id = t.ref_id) end as doc_no,
           t.ref_id,
           case t.ref_table when 'receipts' then (select c.name from receipts r join customers c on c.id = r.customer_id where r.id = t.ref_id)
                            when 'payments' then (select party_name from v_payment_list where id = t.ref_id)
                            when 'purchases' then (select s.name from purchases p left join suppliers s on s.id = p.supplier_id where p.id = t.ref_id)
                            when 'cheques' then (select party_name from v_cheques where id = t.ref_id) end as party,
           t.narration, t.amount, t.created_at
      from account_transactions t
     where t.account_id = p_account and (p_from is null or t.txn_date >= p_from) and (p_to is null or t.txn_date <= p_to))
  select null::bigint, null::date, 'Opening', null, null, null, 'Opening balance',
         case when bal >= 0 then bal else 0 end, case when bal < 0 then -bal else 0 end, bal from opening
  union all
  select id, txn_date, doc, doc_no, ref_id, party, narration,
         case when amount > 0 then amount else 0 end, case when amount < 0 then -amount else 0 end,
         (select bal from opening) + sum(amount) over (order by txn_date, created_at, id rows unbounded preceding)
    from rows
   order by 2 nulls first, 1 nulls first;
$$;

-- ------------------------------------------------------------
-- 6. Chart of accounts and the manual journal.
-- ------------------------------------------------------------
create or replace function t_protect_system_account() returns trigger language plpgsql as $$
begin
  if old.is_system then raise exception 'System account % cannot be deleted (you can rename it)', old.name; end if;
  return old;
end $$;
drop trigger if exists t_protect_system_account on ledger_accounts;
create trigger t_protect_system_account before delete on ledger_accounts for each row execute function t_protect_system_account();

create or replace function t_protect_system_code() returns trigger language plpgsql as $$
begin
  if old.is_system and (new.code is distinct from old.code or new.type <> old.type or not new.is_system) then
    raise exception 'System account % keeps its code and type', old.name;
  end if;
  return new;
end $$;
drop trigger if exists t_protect_system_code on ledger_accounts;
create trigger t_protect_system_code before update on ledger_accounts for each row execute function t_protect_system_code();

create or replace view v_ledger_accounts as
select la.*, p.name as parent_name,
       coalesce((select sum(jl.debit) from journal_lines jl where jl.account_id = la.id), 0) as total_debit,
       coalesce((select sum(jl.credit) from journal_lines jl where jl.account_id = la.id), 0) as total_credit,
       coalesce((select sum(jl.debit - jl.credit) from journal_lines jl where jl.account_id = la.id), 0) as balance,
       (select count(*) from journal_lines jl where jl.account_id = la.id) as line_count
  from ledger_accounts la left join ledger_accounts p on p.id = la.parent_id;
alter view v_ledger_accounts set (security_invoker = on);

create or replace view v_journal_entries as
select je.*, st.full_name as created_by_name,
       coalesce((select sum(jl.debit) from journal_lines jl where jl.entry_id = je.id), 0) as amount,
       (select count(*) from journal_lines jl where jl.entry_id = je.id) as line_count,
       exists (select 1 from journal_entries r where r.reverses_entry_id = je.id) as is_reversed,
       case je.ref_table when 'invoices' then (select invoice_no from invoices where id = je.ref_id)
                         when 'receipts' then (select receipt_no from receipts where id = je.ref_id)
                         when 'payments' then (select payment_no from payments where id = je.ref_id)
                         when 'purchases' then (select bill_no from purchases where id = je.ref_id)
                         when 'sales_returns' then (select return_no from sales_returns where id = je.ref_id)
                         when 'account_transfers' then (select transfer_no from account_transfers where id = je.ref_id)
                         when 'cheques' then (select cheque_no from cheques where id = je.ref_id)
                         when 'journal_entries' then 'manual' end as doc_no
  from journal_entries je left join staff st on st.id = je.created_by;
alter view v_journal_entries set (security_invoker = on);

create or replace view v_journal_lines as
select jl.*, la.code as account_code, la.name as account_name, la.type as account_type, a.name as cash_account_name, je.org_id, je.entry_date
  from journal_lines jl
  join ledger_accounts la on la.id = jl.account_id
  join journal_entries je on je.id = jl.entry_id
  left join cash_bank_accounts a on a.id = jl.cash_account_id;
alter view v_journal_lines set (security_invoker = on);

/**
 * save_manual_journal({entry_date, narration, lines:[{account_id | code, debit, credit, narration, cash_account_id}]})
 * A line on CASH / BANK names the cash/bank account so the books move too.
 */
create or replace function save_manual_journal(p jsonb) returns uuid
language plpgsql as $$
declare v_org uuid := my_org_id(); v_entry uuid := gen_random_uuid(); v_date date; l jsonb; v_acct uuid; v_code text; v_dr numeric := 0; v_cr numeric := 0; v_d numeric; v_c numeric; v_cash uuid; n int := 0;
begin
  perform ensure_system_accounts(v_org);
  v_date := coalesce(nullif(p->>'entry_date','')::date, current_date);
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') < 2 then raise exception 'A journal entry needs at least two lines'; end if;
  -- journal_entries is append-only under RLS (no update policy), so the self-reference is set on insert
  insert into journal_entries (id, org_id, entry_no, entry_date, narration, ref_table, ref_id, is_manual, created_by)
  values (v_entry, v_org, next_doc_no(v_org, 'journal'), v_date, nullif(p->>'narration',''), 'journal_entries', v_entry, true, my_staff_id());

  for l in select * from jsonb_array_elements(p->'lines') loop
    n := n + 1;
    v_d := round(coalesce(nullif(l->>'debit','')::numeric, 0), 2); v_c := round(coalesce(nullif(l->>'credit','')::numeric, 0), 2);
    if v_d < 0 or v_c < 0 or (v_d > 0 and v_c > 0) then raise exception 'Line %: enter either a debit or a credit', n; end if;
    if v_d = 0 and v_c = 0 then continue; end if;
    v_acct := nullif(l->>'account_id','')::uuid;
    if v_acct is null then v_acct := acct(v_org, l->>'code'); end if;
    select code into v_code from ledger_accounts where id = v_acct and org_id = v_org and is_active;
    if not found then raise exception 'Line %: ledger account not found', n; end if;
    v_cash := nullif(l->>'cash_account_id','')::uuid;
    if v_cash is not null then
      if v_code not in ('CASH', 'BANK') then raise exception 'Line %: only a Cash or Bank line can name a cash/bank account', n; end if;
      if not exists (select 1 from cash_bank_accounts where id = v_cash and org_id = v_org) then raise exception 'Line %: cash/bank account not found', n; end if;
      if money_code(v_cash) <> v_code then raise exception 'Line %: % is a % account, post it to the % ledger', n, (select name from cash_bank_accounts where id = v_cash), (select kind from cash_bank_accounts where id = v_cash), money_code(v_cash); end if;
      perform post_money(v_org, v_cash, v_date, v_d - v_c, coalesce(nullif(l->>'narration',''), nullif(p->>'narration',''), 'Journal'), 'journal_entries', v_entry);
    elsif v_code in ('CASH', 'BANK') then
      raise exception 'Line %: say which % account the money moved through', n, lower(v_code);
    end if;
    insert into journal_lines (entry_id, account_id, debit, credit, narration, cash_account_id) values (v_entry, v_acct, v_d, v_c, nullif(l->>'narration',''), v_cash);
    v_dr := v_dr + v_d; v_cr := v_cr + v_c;
  end loop;
  if abs(v_dr - v_cr) > 0.005 then raise exception 'Journal does not balance: debit % vs credit %', v_dr, v_cr; end if;
  if v_dr = 0 then raise exception 'Journal entry is empty'; end if;
  return v_entry;
end $$;

/** Reverse a manual entry (money moves back too). Document entries reverse with their document. */
create or replace function reverse_manual_journal(p_entry uuid, p_date date default current_date) returns uuid
language plpgsql security definer set search_path = public as $$
declare e journal_entries%rowtype; v_new uuid; l record;
begin
  select * into e from journal_entries where id = p_entry;
  if not found or e.org_id is distinct from my_org_id() then raise exception 'Entry not found'; end if;
  if not can_edit('payments') then raise exception 'Your role cannot reverse journal entries'; end if;
  if not e.is_manual then raise exception 'Only manual entries reverse here; cancel the document instead'; end if;
  if e.reverses_entry_id is not null then raise exception 'This is itself a reversal'; end if;
  if exists (select 1 from journal_entries r where r.reverses_entry_id = e.id) then raise exception 'Already reversed'; end if;
  insert into journal_entries (org_id, entry_no, entry_date, narration, ref_table, ref_id, is_manual, reverses_entry_id, created_by)
  values (e.org_id, next_doc_no(e.org_id, 'journal'), p_date, format('Reversal of %s — %s', e.entry_no, coalesce(e.narration, '')), 'journal_entries', e.id, true, e.id, my_staff_id())
  returning id into v_new;
  insert into journal_lines (entry_id, account_id, debit, credit, narration, cash_account_id)
  select v_new, account_id, credit, debit, narration, cash_account_id from journal_lines where entry_id = e.id;
  for l in select * from journal_lines where entry_id = e.id and cash_account_id is not null loop
    perform post_money(e.org_id, l.cash_account_id, p_date, l.credit - l.debit, format('Reversal of %s', e.entry_no), 'journal_entries', v_new);
  end loop;
  update journal_entries set reversed_by = v_new where id = e.id;
  return v_new;
end $$;

/** General ledger for one account with running balance. */
create or replace function ledger_account_book(p_account uuid, p_from date default null, p_to date default null)
returns table (line_id bigint, entry_date date, entry_no text, entry_id uuid, doc_no text, narration text, debit numeric, credit numeric, balance numeric)
language sql stable as $$
  with opening as (
    select coalesce(sum(jl.debit - jl.credit), 0) as bal from journal_lines jl join journal_entries je on je.id = jl.entry_id
     where jl.account_id = p_account and p_from is not null and je.entry_date < p_from),
  rows as (
    select jl.id, je.entry_date, je.entry_no, je.id as entry_id, v.doc_no, coalesce(jl.narration, je.narration) as narration, jl.debit, jl.credit, je.created_at
      from journal_lines jl join journal_entries je on je.id = jl.entry_id join v_journal_entries v on v.id = je.id
     where jl.account_id = p_account and (p_from is null or je.entry_date >= p_from) and (p_to is null or je.entry_date <= p_to))
  select null::bigint, null::date, null, null, null, 'Opening balance', case when bal > 0 then bal else 0 end, case when bal < 0 then -bal else 0 end, bal from opening
  union all
  select id, entry_date, entry_no, entry_id, doc_no, narration, debit, credit,
         (select bal from opening) + sum(debit - credit) over (order by entry_date, created_at, id rows unbounded preceding)
    from rows
   order by 2 nulls first, 1 nulls first;
$$;

/** Trial balance for a range: opening, movement, closing per account. Debits positive. */
create or replace function trial_balance(p_org uuid, p_from date default null, p_to date default null)
returns table (account_id uuid, code text, name text, type account_type, opening numeric, debit numeric, credit numeric, closing numeric)
language sql stable as $$
  select la.id, la.code, la.name, la.type,
         coalesce(sum(jl.debit - jl.credit) filter (where p_from is not null and je.entry_date < p_from), 0),
         coalesce(sum(jl.debit)  filter (where (p_from is null or je.entry_date >= p_from) and (p_to is null or je.entry_date <= p_to)), 0),
         coalesce(sum(jl.credit) filter (where (p_from is null or je.entry_date >= p_from) and (p_to is null or je.entry_date <= p_to)), 0),
         coalesce(sum(jl.debit - jl.credit) filter (where p_to is null or je.entry_date <= p_to), 0)
    from ledger_accounts la
    left join journal_lines jl on jl.account_id = la.id
    left join journal_entries je on je.id = jl.entry_id
   where la.org_id = p_org
   group by la.id, la.code, la.name, la.type
  having count(jl.id) > 0
   order by la.type, la.code;
$$;

-- ------------------------------------------------------------
-- 7. Financial reports.
-- ------------------------------------------------------------
create or replace function profit_and_loss(p_org uuid, p_from date, p_to date)
returns table (section text, code text, name text, amount numeric)
language sql stable as $$
  select la.type::text, la.code, la.name,
         case when la.type = 'income' then sum(jl.credit - jl.debit) else sum(jl.debit - jl.credit) end
    from ledger_accounts la
    join journal_lines jl on jl.account_id = la.id
    join journal_entries je on je.id = jl.entry_id
   where la.org_id = p_org and la.type in ('income', 'expense') and je.entry_date between p_from and p_to
   group by la.type, la.code, la.name
  having sum(jl.debit) <> 0 or sum(jl.credit) <> 0
   order by la.type desc, 4 desc;
$$;

/**
 * Balance sheet as on a date. Journal balances plus the opening balances that live on the
 * masters (customer, supplier, cash/bank) and were never journalled, with their plug in
 * "Opening balance equity" so the two sides tie.
 */
create or replace function balance_sheet(p_org uuid, p_as_on date default current_date)
returns table (section text, code text, name text, amount numeric)
language sql stable as $$
  with j as (
    select la.type, la.code, la.name, sum(jl.debit - jl.credit) as dr
      from ledger_accounts la join journal_lines jl on jl.account_id = la.id join journal_entries je on je.id = jl.entry_id
     where la.org_id = p_org and je.entry_date <= p_as_on
     group by la.type, la.code, la.name),
  -- income sits as credits (dr < 0), expenses as debits: profit = −Σ(dr) over both
  pl as (select -coalesce(sum(dr), 0) as profit from j where type in ('income', 'expense')),
  op as (
    select coalesce((select sum(opening_balance) from customers where org_id = p_org), 0) as debtors,
           coalesce((select sum(opening_balance) from suppliers where org_id = p_org), 0) as creditors,
           coalesce((select sum(opening_balance) from cash_bank_accounts where org_id = p_org), 0) as cash)
  select x.section, x.code, x.name, x.amount from (
    select 'asset' as section, code, name, dr as amount from j where type = 'asset'
    union all select 'asset', 'OPEN_DEBTORS', 'Customer opening balances', debtors from op where debtors <> 0
    union all select 'asset', 'OPEN_CASH', 'Cash & bank opening balances', cash from op where cash <> 0
    union all select 'liability', code, name, -dr from j where type = 'liability'
    union all select 'liability', 'OPEN_CREDITORS', 'Supplier opening balances', creditors from op where creditors <> 0
    union all select 'equity', code, name, -dr from j where type = 'equity'
    union all select 'equity', 'PL', 'Profit & loss to date', profit from pl where profit <> 0
    union all select 'equity', 'OPEN_EQUITY', 'Opening balance equity', debtors + cash - creditors from op where debtors + cash - creditors <> 0
  ) x
  order by case x.section when 'asset' then 1 when 'liability' then 2 else 3 end, x.code;
$$;

create or replace function day_book(p_org uuid, p_date date)
returns table (doc text, doc_no text, doc_id uuid, party text, narration text, amount numeric, direction text, at timestamptz)
language sql stable as $$
  select x.doc, x.doc_no, x.doc_id, x.party, x.narration, x.amount, x.direction, x.at from (
    select 'Invoice' as doc, i.invoice_no as doc_no, i.id as doc_id, c.name as party, i.status::text as narration, i.total as amount, 'in' as direction, i.created_at as at
      from invoices i join customers c on c.id = i.customer_id where i.org_id = p_org and i.invoice_date = p_date and i.status <> 'cancelled'
    union all
    select 'Receipt', r.receipt_no, r.id, c.name, coalesce(r.narration, (select modes from v_receipt_list where id = r.id)), r.total_amount, 'in', r.created_at
      from receipts r join customers c on c.id = r.customer_id where r.org_id = p_org and r.receipt_date = p_date
    union all
    select 'Return', s.return_no, s.id, c.name, replace(s.kind::text, '_', ' '), s.total, 'out', s.created_at
      from sales_returns s join customers c on c.id = s.customer_id where s.org_id = p_org and s.return_date = p_date
    union all
    select 'Purchase', p.bill_no, p.id, coalesce(sp.name, 'cash purchase'), p.notes, p.total, 'out', p.created_at
      from purchases p left join suppliers sp on sp.id = p.supplier_id where p.org_id = p_org and p.bill_date = p_date
    union all
    select 'Payment', p.payment_no, p.id, v.party_name, coalesce(p.narration, v.mode_code), p.amount, 'out', p.created_at
      from payments p join v_payment_list v on v.id = p.id where p.org_id = p_org and p.payment_date = p_date
    union all
    select 'Transfer', t.transfer_no, t.id, t.from_name || ' → ' || t.to_name, t.narration, t.amount, 'move', now()
      from v_account_transfers t where t.org_id = p_org and t.txn_date = p_date
    union all
    select 'Cheque', c.cheque_no, c.id, c.party_name, c.state::text, c.amount, case when c.direction = 'received' then 'in' else 'out' end, now()
      from v_cheques c where c.org_id = p_org and (c.cleared_on = p_date or c.bounced_on = p_date)
    union all
    select 'Journal', je.entry_no, je.id, null::text, je.narration, v.amount, 'move', je.created_at
      from journal_entries je join v_journal_entries v on v.id = je.id where je.org_id = p_org and je.entry_date = p_date and je.is_manual
  ) x
  order by x.at, x.doc_no;
$$;

/** Money actually moved: inflows and outflows by head, with opening and closing cash+bank. */
create or replace function cash_flow(p_org uuid, p_from date, p_to date)
returns table (head text, inflow numeric, outflow numeric, sort integer)
language sql stable as $$
  with t as (
    select t.*, case t.ref_table
             when 'receipts' then 'Collections from customers'
             when 'cheques' then case when t.amount > 0 then 'Cheques cleared (received)' when exists (select 1 from cheques c where c.id = t.ref_id and c.direction = 'issued') then 'Cheques cleared (issued)' else 'Bank charges' end
             when 'purchases' then 'Purchases paid on the spot'
             when 'payments' then (select case v.party_kind when 'supplier' then 'Supplier payments' when 'staff' then 'Wages' else 'Expenses' end from v_payment_list v where v.id = t.ref_id)
             when 'account_transfers' then 'Transfers between accounts'
             when 'journal_entries' then 'Journal entries'
             else 'Other' end as head
      from account_transactions t
     where t.org_id = p_org and t.txn_date between p_from and p_to)
  select 'Opening cash & bank' as head, (select coalesce(sum(opening_balance), 0) from cash_bank_accounts where org_id = p_org)
                                + coalesce((select sum(amount) from account_transactions where org_id = p_org and txn_date < p_from), 0) as inflow, 0::numeric as outflow, 0 as sort
  union all
  select head, coalesce(sum(amount) filter (where amount > 0), 0), coalesce(-sum(amount) filter (where amount < 0), 0),
         case head when 'Collections from customers' then 1 when 'Cheques cleared (received)' then 2 when 'Supplier payments' then 3 when 'Wages' then 4 when 'Expenses' then 5
                   when 'Purchases paid on the spot' then 6 when 'Cheques cleared (issued)' then 7 when 'Bank charges' then 8 when 'Transfers between accounts' then 9 else 10 end
    from t group by head
  union all
  select 'Closing cash & bank', (select coalesce(sum(opening_balance), 0) from cash_bank_accounts where org_id = p_org)
                                + coalesce((select sum(amount) from account_transactions where org_id = p_org and txn_date <= p_to), 0), 0::numeric, 99
  order by 4, 1;
$$;

/**
 * Item profitability: sale value against cost. Cost per unit is the latest closed batch
 * (ingredients + labour ÷ units made) when the item is produced, else its purchase rate.
 */
create or replace function item_profit(p_org uuid, p_from date, p_to date, p_group text default 'item')
returns table (group_key text, group_label text, boxes numeric, qty numeric, sale_value numeric, cost_value numeric, gross_profit numeric, margin_pct numeric)
language sql stable as $$
  with cost as (
    select i.id as item_id,
           coalesce((select round(b.total_cost / nullif(b.actual_boxes * i.units_per_box, 0), 4) from production_batches b
                      where b.item_id = i.id and b.status = 'closed' and b.actual_boxes > 0 and b.production_date <= p_to
                      order by b.production_date desc, b.closed_at desc limit 1),
                    i.purchase_rate, 0) as unit_cost
      from items i where i.org_id = p_org),
  lines as (
    select ii.item_id, i.item_code, i.name as item_name, s.name as section_name, s.sort_order as section_sort,
           ii.boxes, ii.qty, ii.amount, ii.qty * c.unit_cost as cost
      from invoice_items ii
      join invoices inv on inv.id = ii.invoice_id
      join items i on i.id = ii.item_id
      join cost c on c.item_id = i.id
      left join sections s on s.id = i.section_id
     where inv.org_id = p_org and inv.status <> 'cancelled' and inv.invoice_date between p_from and p_to)
  select case p_group when 'section' then coalesce(section_name, 'OTHERS') else item_code end,
         case p_group when 'section' then coalesce(section_name, 'OTHERS') else item_code || ' — ' || item_name end,
         sum(boxes), sum(qty), sum(amount), round(sum(cost), 2), round(sum(amount) - sum(cost), 2),
         case when sum(amount) > 0 then round((sum(amount) - sum(cost)) / sum(amount) * 100, 1) end
    from lines
   group by 1, 2
   order by 7 desc;
$$;

-- ------------------------------------------------------------
-- 8. Dashboard: balances and cheques due.
-- ------------------------------------------------------------
create or replace function dashboard_summary(p_org uuid, p_date date default current_date)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'sales_today',      (select coalesce(sum(total),0) from invoices where org_id=p_org and invoice_date=p_date and status<>'cancelled'),
    'sales_mtd',        (select coalesce(sum(total),0) from invoices where org_id=p_org and status<>'cancelled' and invoice_date >= date_trunc('month',p_date)),
    'collection_today', (select coalesce(sum(total_amount),0) from receipts where org_id=p_org and receipt_date=p_date),
    'total_outstanding',(select coalesce(sum(outstanding),0) from v_customer_outstanding where org_id=p_org),
    'invoices_today',   (select count(*) from invoices where org_id=p_org and invoice_date=p_date),
    'low_stock_items',  (select count(*) from v_stock_on_hand where org_id=p_org and is_low),
    'negative_stock',   (select count(*) from v_stock_on_hand where org_id=p_org and is_negative),
    'vehicles_out',     (select count(*) from vehicle_trips where org_id=p_org and trip_date=p_date and status='dispatched'),
    'batches_open',     (select count(*) from production_batches where org_id=p_org and status='open'),
    'pending_orders',   (select count(*) from inbound_orders where org_id=p_org and status='new'),
    'cash_balance',     (select coalesce(sum(balance),0) from v_cash_bank_accounts where org_id=p_org and kind='cash' and is_active),
    'bank_balance',     (select coalesce(sum(balance),0) from v_cash_bank_accounts where org_id=p_org and kind<>'cash' and is_active),
    'cheques_in_hand',  (select coalesce(sum(amount),0) from cheques where org_id=p_org and direction='received' and state in ('in_hand','deposited')),
    'cheques_due',      (select count(*) from v_cheques where org_id=p_org and is_due),
    'payables',         (select coalesce(sum(payable),0) from v_supplier_list where org_id=p_org)
  );
$$;
