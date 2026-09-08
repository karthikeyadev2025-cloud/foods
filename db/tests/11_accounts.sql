-- ============================================================
-- DB acceptance test: T7 accounting & money.
-- The trial balance must be zero after every step. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_head uuid; v_item uuid; v_inv uuid;
  m_cash uuid; m_bank uuid; m_chq uuid; a_cash uuid; a_bank uuid; v_rc uuid; v_rc2 uuid; v_chq uuid; v_chq2 uuid; v_chq3 uuid; v_pay uuid; v_je uuid; v_rev uuid;
  r record; n int; q numeric; q2 numeric; v_purchase_total numeric;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Godown') returning id into v_loc;
  insert into customers (org_id, name, town, mobile1, opening_balance) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746', 500) returning id into v_cust;
  insert into suppliers (org_id, name, opening_balance) values (v_org, 'SUGAR TRADERS', 0) returning id into v_sup;
  insert into expense_heads (org_id, name) values (v_org, 'Diesel') returning id into v_head;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'CASH', 'Cash', true, false, 1) returning id into m_cash;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, sort_order) values (v_org, 'BANK', 'Bank', true, true, 2) returning id into m_bank;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference, is_cheque, sort_order) values (v_org, 'CHEQUE', 'Cheque', true, true, true, 3) returning id into m_chq;
  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate, purchase_rate)
    values (v_org, '8', '5/- HT. MYSOOR PAK(12) 32', v_uom, v_pack, 32, 12, 42, 30) returning id into v_item;

  -- ===== a sale, then a receipt: part cash, part cheque =====
  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', current_date, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item, 'boxes', 2, 'rate', 42)));
  perform set_invoice_status(v_inv, 'confirmed');
  v_rc := save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date),
    jsonb_build_array(jsonb_build_object('mode_id', m_cash, 'amount', 1000),
                      jsonb_build_object('mode_id', m_chq, 'amount', 688, 'reference', 'CHQ123', 'cheque_date', current_date + 5, 'bank_name', 'SBI')));
  select id into a_cash from cash_bank_accounts where org_id = v_org and kind = 'cash';
  select id into a_bank from cash_bank_accounts where org_id = v_org and kind = 'bank';
  assert a_cash is not null and a_bank is not null, 'default cash and bank accounts created on first use';
  select balance into q from v_cash_bank_accounts where id = a_cash; assert q = 1000, format('cash book %s', q);
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 0, 'the cheque is not in the bank yet';
  select * into r from v_cheques where cheque_no = 'CHQ123';
  assert r.direction = 'received' and r.state = 'in_hand' and r.amount = 688 and r.party_name = 'P. SRINIVAS (MCL)' and r.doc_no is not null, format('cheque row %s', to_jsonb(r));
  v_chq := r.id;
  select balance into q from v_trial_balance where org_id = v_org and code = 'CHEQUES_IN_HAND'; assert q = 688, 'cheques in hand is an asset until it clears';
  select outstanding into q from v_customer_outstanding where customer_id = v_cust; assert q = 500 + 2688 - 1688, format('outstanding %s', q);
  assert trial_balance_check(v_org) = 0, 'TB after receipt';

  -- ===== deposit and clear =====
  begin
    perform clear_cheque(v_chq); raise exception 'should fail';
  exception when others then assert sqlerrm = 'Deposit the cheque first', sqlerrm; end;
  perform deposit_cheque(v_chq, a_bank);
  select state::text into r from v_cheques where id = v_chq; assert r.state = 'deposited';
  perform clear_cheque(v_chq, current_date + 6);
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 688, format('bank after clearing %s', q);
  select balance into q from v_trial_balance where org_id = v_org and code = 'CHEQUES_IN_HAND'; assert q = 0;
  assert trial_balance_check(v_org) = 0, 'TB after clearing';

  -- ===== a second cheque bounces: the customer owes again, the bill reopens, bank charges =====
  v_rc2 := save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', current_date),
    jsonb_build_array(jsonb_build_object('mode_id', m_chq, 'amount', 500, 'reference', 'CHQ777')));
  select balance into q from v_invoice_balance where invoice_id = v_inv; assert q = 2688 - 1688 - 500, format('invoice balance before bounce %s', q);
  select id into v_chq2 from cheques where cheque_no = 'CHQ777';
  perform deposit_cheque(v_chq2, a_bank);
  v_rev := bounce_cheque(v_chq2, current_date, 50);
  select state::text into r from v_cheques where id = v_chq2; assert r.state = 'bounced';
  select total_amount, reversal_of into r from receipts where id = v_rev; assert r.total_amount = -500 and r.reversal_of = v_rc2, 'reversal receipt';
  select balance into q from v_invoice_balance where invoice_id = v_inv; assert q = 2688 - 1688, format('invoice reopened %s', q);
  select outstanding into q from v_customer_outstanding where customer_id = v_cust; assert q = 500 + 2688 - 1688, format('outstanding back %s', q);
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 688 - 50, format('bank charges %s', q);
  select balance into q from v_trial_balance where org_id = v_org and code = 'BANK_CHARGES'; assert q = 50;
  assert trial_balance_check(v_org) = 0, 'TB after bounce';
  -- the register shows the bounce as a negative in the cheque column
  select (by_mode->>'CHEQUE')::numeric into q from receipts_register(v_org, current_date, current_date) where customer_id = v_cust;
  assert q = 688, format('register cheque column nets to %s', q);

  -- ===== payments: bank transfer, an issued cheque that clears, a purchase paid in cash =====
  perform save_payment(jsonb_build_object('supplier_id', v_sup, 'amount', 300, 'mode_id', m_bank, 'reference', 'UTR1', 'payment_date', current_date));
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 638 - 300, format('bank after supplier payment %s', q);
  v_pay := save_payment(jsonb_build_object('expense_head_id', v_head, 'amount', 200, 'mode_id', m_chq, 'reference', 'CHQ9', 'payment_date', current_date, 'cheque_date', current_date + 2));
  select * into r from v_cheques where cheque_no = 'CHQ9';
  assert r.direction = 'issued' and r.state = 'in_hand' and r.account_id = a_bank, format('issued cheque %s', to_jsonb(r));
  v_chq3 := r.id;
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 338, 'issued cheque not yet out of the bank';
  select balance into q from v_trial_balance where org_id = v_org and code = 'CHEQUES_ISSUED'; assert q = -200, 'cheques issued is a liability';
  perform clear_cheque(v_chq3);
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 138, format('bank after issued cheque cleared %s', q);
  perform save_purchase(jsonb_build_object('supplier_id', v_sup, 'location_id', v_loc, 'bill_date', current_date, 'paid_amount', 100), jsonb_build_array(jsonb_build_object('item_id', v_item, 'qty', 32, 'uom_id', v_uom, 'rate', 30)));
  select total into v_purchase_total from purchases where org_id = v_org;
  select balance into q from v_cash_bank_accounts where id = a_cash; assert q = 900, format('cash after purchase %s', q);
  assert trial_balance_check(v_org) = 0, 'TB after payments';
  -- an issued cheque that bounces puts the supplier back on creditors
  perform save_payment(jsonb_build_object('supplier_id', v_sup, 'amount', 120, 'mode_id', m_chq, 'reference', 'CHQ10', 'payment_date', current_date));
  select payable into q from v_supplier_list where id = v_sup;
  perform bounce_cheque((select id from cheques where cheque_no = 'CHQ10'), current_date, 0, true);
  select payable into q2 from v_supplier_list where id = v_sup; assert q2 = q + 120, format('supplier payable back after cancelled cheque %s → %s', q, q2);
  assert trial_balance_check(v_org) = 0, 'TB after issued bounce';

  -- ===== transfer cash → bank =====
  perform save_transfer(jsonb_build_object('from_account', a_cash, 'to_account', a_bank, 'amount', 500, 'narration', 'deposit'));
  select balance into q from v_cash_bank_accounts where id = a_cash; assert q = 400, format('cash after transfer %s', q);
  select balance into q from v_cash_bank_accounts where id = a_bank; assert q = 638, format('bank after transfer %s', q);
  begin
    perform save_transfer(jsonb_build_object('from_account', a_cash, 'to_account', a_cash, 'amount', 5)); raise exception 'should fail';
  exception when others then assert sqlerrm like 'Pick two different accounts%', sqlerrm; end;
  assert trial_balance_check(v_org) = 0, 'TB after transfer';

  -- ===== manual journal with a cash line, then reverse it =====
  begin
    perform save_manual_journal(jsonb_build_object('narration', 'x', 'lines', jsonb_build_array(jsonb_build_object('code', 'EXPENSES', 'debit', 40), jsonb_build_object('code', 'CASH', 'credit', 40))));
    raise exception 'should fail';
  exception when others then assert sqlerrm like 'Line 2: say which cash account%', sqlerrm; end;
  begin
    perform save_manual_journal(jsonb_build_object('narration', 'x', 'lines', jsonb_build_array(jsonb_build_object('code', 'EXPENSES', 'debit', 40), jsonb_build_object('code', 'CASH', 'credit', 30, 'cash_account_id', a_cash))));
    raise exception 'should fail';
  exception when others then assert sqlerrm like 'Journal does not balance%', sqlerrm; end;
  v_je := save_manual_journal(jsonb_build_object('narration', 'Tea and snacks', 'lines', jsonb_build_array(
    jsonb_build_object('code', 'EXPENSES', 'debit', 40, 'narration', 'tea'), jsonb_build_object('code', 'CASH', 'credit', 40, 'cash_account_id', a_cash))));
  select balance into q from v_cash_bank_accounts where id = a_cash; assert q = 360, format('cash after manual journal %s', q);
  select is_manual, doc_no, amount into r from v_journal_entries where id = v_je; assert r.is_manual and r.doc_no = 'manual' and r.amount = 40;
  perform reverse_manual_journal(v_je);
  select balance into q from v_cash_bank_accounts where id = a_cash; assert q = 400, format('cash after reversal %s', q);
  select is_reversed into r from v_journal_entries where id = v_je; assert r.is_reversed;
  begin
    perform reverse_manual_journal(v_je); raise exception 'should fail';
  exception when others then assert sqlerrm = 'Already reversed', sqlerrm; end;
  assert trial_balance_check(v_org) = 0, 'TB after manual journal';

  -- ===== books =====
  select balance into q from account_book(a_cash) order by txn_date desc nulls first limit 1;
  select count(*) into n from account_book(a_cash); assert n = 1 + 5, format('cash book rows %s', n);  -- opening + receipt, purchase, transfer, journal, reversal
  select balance into q from account_book(a_cash) where doc = 'Journal' and money_in > 0; assert q = 400, format('running balance ends at %s', q);
  select count(*) into n from account_book(a_bank, current_date + 6, current_date + 6); assert n = 2, 'bank book for the clearing day: opening + 1';
  select balance into q from account_book(a_bank, current_date + 6, current_date + 6) where doc = 'Cheque'; assert q = 638, format('bank book closing %s', q);
  select count(*) into n from ledger_account_book(acct(v_org, 'CASH')); assert n > 3;
  select balance into q from ledger_account_book(acct(v_org, 'CASH')) order by entry_date desc nulls first, line_id desc limit 1;
  select balance into q from v_trial_balance where org_id = v_org and code = 'CASH'; assert q = 400, format('CASH ledger agrees with the cash book: %s', q);
  select balance into q from v_trial_balance where org_id = v_org and code = 'BANK'; assert q = 638, format('BANK ledger agrees with the bank book: %s', q);

  -- ===== trial balance, P&L, balance sheet =====
  select sum(debit), sum(credit) into q, q2 from trial_balance(v_org); assert q = q2, format('trial balance %s vs %s', q, q2);
  select sum(closing) into q from trial_balance(v_org); assert q = 0, 'closings net to zero';
  select sum(debit) - sum(credit) into q from trial_balance(v_org, current_date + 6, current_date + 6); assert q = 0, 'range TB balances';
  select sum(case when section = 'income' then amount else -amount end) into q from profit_and_loss(v_org, current_date, current_date + 6);
  -- sales 2688 − purchase − bank charges 50 − diesel 200 (the 40 tea entry was reversed)
  assert q = 2688 - v_purchase_total - 50 - 200, format('net profit %s (purchase %s)', q, v_purchase_total);
  select amount into q from profit_and_loss(v_org, current_date, current_date + 6) where code = 'EXPENSES'; assert q = 200, format('reversed tea nets out, diesel stays: %s', q);
  select sum(case when section = 'asset' then amount else -amount end) into q from balance_sheet(v_org, current_date + 6);
  assert q = 0, format('balance sheet ties: %s', q);
  select amount into q from balance_sheet(v_org, current_date + 6) where code = 'OPEN_DEBTORS'; assert q = 500, 'customer opening balance on the balance sheet';
  select amount into q from balance_sheet(v_org, current_date + 6) where code = 'DEBTORS'; assert q = 2688 - 1688, format('debtors %s', q);

  -- ===== day book, cash flow, item profit, dashboard =====
  select count(*) into n from day_book(v_org, current_date); assert n >= 8, format('day book rows %s', n);
  select inflow into q from cash_flow(v_org, current_date, current_date + 6) where head = 'Collections from customers'; assert q = 1000;
  select inflow into q from cash_flow(v_org, current_date, current_date + 6) where head = 'Closing cash & bank'; assert q = 400 + 638, format('cash flow closing %s', q);
  select outflow into q from cash_flow(v_org, current_date, current_date + 6) where head = 'Supplier payments'; assert q = 300;
  select * into r from item_profit(v_org, current_date, current_date, 'item');
  assert r.boxes = 2 and r.sale_value = 2688 and r.cost_value = 64 * 30 and r.gross_profit = 768, format('item profit %s', to_jsonb(r));
  select (dashboard_summary(v_org)->>'cash_balance')::numeric, (dashboard_summary(v_org)->>'bank_balance')::numeric into q, q2;
  assert q = 400 and q2 = 638, format('dashboard balances %s / %s', q, q2);

  -- ===== chart of accounts protection =====
  begin
    delete from ledger_accounts where org_id = v_org and code = 'SALES'; raise exception 'should fail';
  exception when others then assert sqlerrm like 'System account%', sqlerrm; end;
  update ledger_accounts set name = 'Sales — sweets' where org_id = v_org and code = 'SALES';
  begin
    update ledger_accounts set code = 'X' where org_id = v_org and code = 'SALES'; raise exception 'should fail';
  exception when others then assert sqlerrm like 'System account%', sqlerrm; end;
  insert into ledger_accounts (org_id, code, name, type) values (v_org, 'RENT', 'Shop rent', 'expense');
  assert trial_balance_check(v_org) = 0, 'TB at the end';

  reset role;
  raise notice 'OK: accounts — cash & bank books, cheques in hand → deposited → cleared / bounced (reversal receipt reopens the bill), issued cheques, transfers, manual journal + reversal, books agree with the ledger, TB = 0 throughout, P&L, balance sheet ties, day book, cash flow, item profit, dashboard balances';
end $$;

rollback;
