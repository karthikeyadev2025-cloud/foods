-- ============================================================
-- DB acceptance test: T2 transactions.
--   T2.2 the quotation: 17 lines, 32 boxes, 753 qty, net 34,258.00
--   T2.4 rate difference changes the balance, leaves stock_ledger alone
--   T7.3 (brought forward) the trial balance nets to zero, always
-- Runs as the authenticated owner. Rolls back.
-- ============================================================
begin;

grant usage on schema public to authenticated;
grant all on all tables in schema public to authenticated;
grant all on all sequences in schema public to authenticated;
grant execute on all functions in schema public to authenticated;

do $$
declare
  v_org uuid; v_uom uuid; v_kg uuid; v_pack uuid; v_loc uuid; v_cust uuid; v_sup uuid; v_head uuid;
  v_cash uuid; v_bank uuid; v_brk uuid; v_inv uuid; v_inv2 uuid; v_ret uuid; v_rcpt uuid; v_pur uuid; v_pay uuid;
  v_sugar uuid; v_item8 uuid; r record; n int; q numeric; t text; v_lines jsonb;
  uid_owner uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claim.sub', uid_owner::text, true);
  set local role authenticated;
  v_org := bootstrap_org('JYOTHI FOODS', 'Owner');
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar', 'unit') returning id into v_uom;
  insert into uoms (org_id, code, name, basis, weight_g) values (v_org, 'KG', 'Kilogram', 'weight', 1000) returning id into v_kg;
  insert into pack_types (org_id, code) values (v_org, 'JAR') returning id into v_pack;
  insert into stock_locations (org_id, name) values (v_org, 'Main godown') returning id into v_loc;
  insert into customers (org_id, name, town, mobile1) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA', '9849686746') returning id into v_cust;
  insert into suppliers (org_id, name) values (v_org, 'Sugar Traders') returning id into v_sup;
  insert into expense_heads (org_id, name) values (v_org, 'Fuel') returning id into v_head;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference) values (v_org, 'CASH', 'Cash', true, false) returning id into v_cash;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference) values (v_org, 'BANK', 'Bank', true, true) returning id into v_bank;
  insert into receipt_modes (org_id, code, name, is_collection, needs_reference) values (v_org, 'BRK', 'Breakage', false, false) returning id into v_brk;

  insert into items (org_id, item_code, name, base_uom_id, pack_type_id, units_per_box, pieces_per_unit, unit_rate)
  select v_org, c, nm, v_uom, v_pack, j, 12, rt from (values
    ('8','5/- HT. MYSOOR PAK(12) 32',32,42),('2','5/- BOONDI LADDU (12) 48',48,40),('200A','TRY',1,100),
    ('1','5/- BOONDI LADDU (8)',8,120),('57','5/- KAJA PKTS (12) 24P',24,40),('44','5/- MIXING BURFI(12)32 NEW',32,40),
    ('2686','5/- BOONDI LADDU (12) 6J',24,40),('83','5/- SUNNI VUNDALU (12)21',21,40),('87','5/- PALA KOVA (8)',8,120),
    ('31','5/- SOANPAPIDI (8)',8,120),('80','1/- SUNNI VUNDALU (15J)',15,42),('50','2/- BESIN NICE (40) 15',15,58),
    ('68','5/- PALLI VUNDALU (12)60',60,36),('2702','5/- HALWA (12)32',32,40),('2504','5/- MIXING NICE (12)32',32,40),
    ('137','5/- DIL KUSH (30) 6J',6,105),('1262','5/- SWEET TOMATO (24)',24,40)) as v(c,nm,j,rt);
  insert into items (org_id, item_code, name, type, base_uom_id, units_per_box, pieces_per_unit, purchase_rate)
    values (v_org, 'RM-SUGAR', 'SUGAR', 'raw_material', v_kg, 1, 1, 42) returning id into v_sugar;
  select id into v_item8 from items where org_id = v_org and item_code = '8';

  -- ============ T2.2 the quotation through save_invoice ============
  select jsonb_agg(jsonb_build_object('item_id', i.id, 'boxes', v.b, 'rate', v.rt)) into v_lines
  from (values ('8',2,42),('2',3,40),('200A',3,100),('1',3,120),('57',4,40),('44',2,40),('2686',1,40),('83',1,40),
               ('87',1,120),('31',1,120),('80',2,42),('50',1,58),('68',2,36),('2702',1,40),('2504',2,40),('137',2,105),('1262',1,40)) as v(c,b,rt)
  join items i on i.org_id = v_org and i.item_code = v.c;

  v_inv := save_invoice(jsonb_build_object('customer_id', v_cust, 'invoice_date', '2026-08-25', 'location_id', v_loc), v_lines);
  select * into r from v_invoice_list where id = v_inv;
  assert r.invoice_no = '0001', format('invoice no: %s', r.invoice_no);
  assert r.line_count = 17 and r.total_boxes = 32 and r.total_qty = 753 and r.total = 34258,
    format('quotation: %s lines, %s boxes, %s qty, net %s', r.line_count, r.total_boxes, r.total_qty, r.total);
  assert r.status = 'draft' and r.balance = 34258;
  select count(*) into n from stock_ledger where ref_id = v_inv; assert n = 0, 'draft posts no stock';
  select count(*) into n from journal_entries where ref_id = v_inv; assert n = 0, 'draft posts no journal';

  -- Editing a draft replaces the lines; rate defaults from the master when omitted
  v_inv := save_invoice(jsonb_build_object('id', v_inv, 'customer_id', v_cust, 'invoice_date', '2026-08-25', 'location_id', v_loc, 'freight', 200),
                        jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 2)));
  select * into r from v_invoice_list where id = v_inv;
  assert r.line_count = 1 and r.subtotal = 2688 and r.total = 2888, format('edited draft: %s / %s', r.subtotal, r.total);
  -- …and back to the full quotation
  v_inv := save_invoice(jsonb_build_object('id', v_inv, 'customer_id', v_cust, 'invoice_date', '2026-08-25', 'location_id', v_loc), v_lines);
  select total into q from invoices where id = v_inv; assert q = 34258;

  -- Confirm: stock out, journal balanced
  perform set_invoice_status(v_inv, 'confirmed');
  select count(*) into n from stock_ledger where ref_id = v_inv; assert n = 17, 'confirm posts 17 stock rows';
  select coalesce(sum(jl.debit),0), coalesce(sum(jl.credit),0) into q, n
    from journal_lines jl join journal_entries je on je.id = jl.entry_id where je.ref_id = v_inv;
  assert q = 34258 and n = 34258, format('invoice journal: dr %s cr %s', q, n);
  assert trial_balance_check(v_org) = 0, 'trial balance after invoice';
  begin
    perform save_invoice(jsonb_build_object('id', v_inv, 'customer_id', v_cust, 'location_id', v_loc), v_lines);
    raise exception 'confirmed invoice must not be editable';
  exception when others then if sqlerrm not like '%only drafts%' then raise; end if;
  end;
  begin
    perform set_invoice_status(v_inv, 'draft');
    raise exception 'cannot go back to draft';
  exception when others then if sqlerrm not like 'Cannot move%' then raise; end if;
  end;

  -- ============ T2.5 receipt: FIFO allocation ============
  v_rcpt := save_receipt(jsonb_build_object('customer_id', v_cust, 'receipt_date', '2026-08-28'),
                         jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 20000)));
  select balance into q from v_invoice_balance where invoice_id = v_inv;
  assert q = 14258, format('after 20000 receipt balance should be 14258, got %s', q);
  select allocated into q from v_receipt_list where id = v_rcpt; assert q = 20000, 'FIFO allocated the whole receipt';
  begin
    perform save_receipt(jsonb_build_object('customer_id', v_cust), jsonb_build_array(jsonb_build_object('mode_id', v_bank, 'amount', 10)));
    raise exception 'bank without reference must fail';
  exception when others then if sqlerrm not like '%reference%' then raise; end if;
  end;
  assert trial_balance_check(v_org) = 0, 'trial balance after receipt';

  -- ============ T2.4 three kinds of return ============
  -- fresh: 1 box of code 8 = 32 units × 42 = 1,344 back in stock
  v_ret := save_sales_return(jsonb_build_object('customer_id', v_cust, 'invoice_id', v_inv, 'kind', 'fresh_return', 'location_id', v_loc),
                             jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 1, 'rate', 42)));
  select total into q from sales_returns where id = v_ret; assert q = 1344, format('fresh return credit %s', q);
  select sum(qty_base) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret; assert q = 32, 'fresh return stock back';
  -- damage: 1 box, credit = 50% of 1,344 = 672, stock written off (row with 0 qty)
  v_ret := save_sales_return(jsonb_build_object('customer_id', v_cust, 'invoice_id', v_inv, 'kind', 'damage_return', 'location_id', v_loc),
                             jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 1, 'rate', 42)));
  select total into q from sales_returns where id = v_ret; assert q = 672, format('damage credit at 50%% = 672, got %s', q);
  select coalesce(sum(qty_base),0) into q from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret; assert q = 0, 'damage: nothing saleable comes back';
  -- rate difference: 2 boxes 42 → 41 = 64 units × 1 = 64, NO stock row
  select count(*) into n from stock_ledger where org_id = v_org;
  v_ret := save_sales_return(jsonb_build_object('customer_id', v_cust, 'invoice_id', v_inv, 'kind', 'rate_difference', 'location_id', v_loc),
                             jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 2, 'rate', 42, 'new_rate', 41)));
  select total into q from sales_returns where id = v_ret; assert q = 64, format('rate difference credit %s', q);
  select count(*) into r from stock_ledger where org_id = v_org;
  assert r.count = n, 'a rate-difference return must leave stock_ledger untouched';
  select balance into q from v_invoice_balance where invoice_id = v_inv;
  assert q = 14258 - 1344 - 672 - 64, format('invoice balance after returns: %s', q);
  select outstanding into q from v_customer_outstanding where customer_id = v_cust;
  assert q = 34258 - 20000 - 1344 - 672 - 64, format('customer outstanding: %s', q);
  assert trial_balance_check(v_org) = 0, 'trial balance after returns';

  -- Receipt with a breakage deduction line + explicit allocation
  v_rcpt := save_receipt(jsonb_build_object('customer_id', v_cust),
                         jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 1000), jsonb_build_object('mode_id', v_brk, 'amount', 178)),
                         jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 1178)));
  select balance into q from v_invoice_balance where invoice_id = v_inv; assert q = 11000, format('balance after 2nd receipt: %s', q);
  begin
    perform save_receipt(jsonb_build_object('customer_id', v_cust), jsonb_build_array(jsonb_build_object('mode_id', v_cash, 'amount', 5)),
                         jsonb_build_array(jsonb_build_object('invoice_id', v_inv, 'amount', 99999)));
    raise exception 'over-allocation must fail';
  exception when others then if sqlerrm not like '%exceeds its balance%' then raise; end if;
  end;

  -- ============ T2.1 purchase: raw material in, creditor up ============
  v_pur := save_purchase(jsonb_build_object('supplier_id', v_sup, 'bill_no', 'ST/101', 'location_id', v_loc, 'paid_amount', 1000),
                         jsonb_build_array(jsonb_build_object('item_id', v_sugar, 'qty', 100, 'uom_id', v_kg, 'rate', 42)));
  select total, subtotal into q, n from v_purchase_list where id = v_pur; assert q = 4200, format('purchase total %s', q);
  select sum(qty_base) into q from stock_ledger where ref_table = 'purchases' and ref_id = v_pur; assert q = 100, format('sugar in stock: %s', q);
  select payable into q from v_supplier_list where id = v_sup; assert q = 3200, format('supplier payable %s', q);
  assert trial_balance_check(v_org) = 0, 'trial balance after purchase';

  -- ============ T2.6 payments ============
  v_pay := save_payment(jsonb_build_object('supplier_id', v_sup, 'mode_id', v_cash, 'amount', 3200));
  select payable into q from v_supplier_list where id = v_sup; assert q = 0, 'supplier paid off';
  v_pay := save_payment(jsonb_build_object('expense_head_id', v_head, 'mode_id', v_cash, 'amount', 500, 'narration', 'diesel'));
  select party_kind, party_name into r from v_payment_list where id = v_pay;
  assert r.party_kind = 'expense' and r.party_name = 'Fuel';
  begin
    perform save_payment(jsonb_build_object('supplier_id', v_sup, 'expense_head_id', v_head, 'mode_id', v_cash, 'amount', 1));
    raise exception 'payment to two parties must fail';
  exception when others then if sqlerrm not like '%exactly one%' then raise; end if;
  end;
  begin
    perform save_payment(jsonb_build_object('supplier_id', v_sup, 'mode_id', v_brk, 'amount', 1));
    raise exception 'paying via a deduction head must fail';
  exception when others then if sqlerrm not like '%deduction head%' then raise; end if;
  end;
  assert trial_balance_check(v_org) = 0, 'trial balance after payments';

  -- ============ cancel: blocked when money is against it; otherwise reverses ============
  begin
    perform set_invoice_status(v_inv, 'cancelled');
    raise exception 'cancel with allocations must fail';
  exception when others then if sqlerrm not like '%receipts allocated%' then raise; end if;
  end;
  v_inv2 := save_invoice(jsonb_build_object('customer_id', v_cust, 'location_id', v_loc), jsonb_build_array(jsonb_build_object('item_id', v_item8, 'boxes', 1)));
  perform set_invoice_status(v_inv2, 'confirmed');
  perform set_invoice_status(v_inv2, 'dispatched');
  select sum(qty_base) into q from stock_ledger where ref_id = v_inv2; assert q = -32, 'dispatch does not double post';
  perform set_invoice_status(v_inv2, 'cancelled');
  select sum(qty_base) into q from stock_ledger where ref_id = v_inv2; assert q = 0, 'cancel reverses stock with a row';
  select count(*) into n from journal_entries where ref_id = v_inv2; assert n = 2, 'cancel adds a reversing journal entry';
  select count(*) into n from journal_entries where ref_id = v_inv2 and reverses_entry_id is not null; assert n = 1;
  perform set_invoice_status(v_inv2, 'cancelled');   -- idempotent
  assert trial_balance_check(v_org) = 0, 'trial balance after cancel';
  select outstanding into q from v_customer_outstanding where customer_id = v_cust;
  assert q = 34258 - 20000 - 1344 - 672 - 64 - 1178, format('cancelled invoice must not count: %s', q);

  -- Every document numbered from its own series
  select string_agg(distinct doc_type, ',' order by doc_type) into t from number_series where org_id = v_org;
  assert t = 'invoice,journal,payment,receipt,return', format('series used: %s', t);

  reset role;
  raise notice 'OK: transactions — quotation 17/32/753/34258, three returns, FIFO receipts, purchase, payments; trial balance = 0';
end $$;

rollback;
