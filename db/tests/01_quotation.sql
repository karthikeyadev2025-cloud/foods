-- ============================================================
-- DB acceptance test: the client's real quotation, through the
-- real triggers and posting functions. Runs inside a transaction
-- and rolls back, so it is safe to run against any database.
--
--   psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db/tests/01_quotation.sql
--
-- Expected (docs/reference/quotation.jpeg):
--   17 lines · 32 total boxes · 753 total qty · net 34,258.00
--   Row 1: Jars 32 × Boxes 2 = Qty 64 × Rate 42 = 2,688
-- ============================================================
begin;

do $$
declare
  v_org      uuid;
  v_uom      uuid;
  v_cust     uuid;
  v_loc      uuid;
  v_inv      uuid;
  v_ret      uuid;
  v_item8    uuid;
  r          record;
  n_lines    int;
  t_boxes    numeric;
  t_qty      numeric;
  t_net      numeric;
  n_ledger   int;
  v_credit   numeric;
  v_no       text;
begin
  -- Masters -------------------------------------------------------
  insert into orgs (name) values ('JYOTHI FOODS') returning id into v_org;
  insert into uoms (org_id, code, name, basis) values (v_org, 'JAR', 'Jar / pack', 'unit') returning id into v_uom;
  insert into customers (org_id, name, town) values (v_org, 'P. SRINIVAS (MCL)', 'MACHARLA') returning id into v_cust;
  insert into stock_locations (org_id, name, kind) values (v_org, 'Main godown', 'godown') returning id into v_loc;

  -- The 17 items exactly as printed: code, name, Jars (= units_per_box), rate.
  -- pieces_per_unit is not on the quotation; use 12 as a neutral value.
  insert into items (org_id, item_code, name, base_uom_id, units_per_box, pieces_per_unit, unit_rate)
  select v_org, c, n, v_uom, j, 12, rt
  from (values
    ('8',    '5/- HT. MYSOOR PAK(12) 32',   32, 42),
    ('2',    '5/- BOONDI LADDU (12) 48',    48, 40),
    ('200A', 'TRY',                          1, 100),
    ('1',    '5/- BOONDI LADDU (8)',         8, 120),
    ('57',   '5/- KAJA PKTS (12) 24P',      24, 40),
    ('44',   '5/- MIXING BURFI(12)32 NEW',  32, 40),
    ('2686', '5/- BOONDI LADDU (12) 6J',    24, 40),
    ('83',   '5/- SUNNI VUNDALU (12)21',    21, 40),
    ('87',   '5/- PALA KOVA (8)',            8, 120),
    ('31',   '5/- SOANPAPIDI (8)',           8, 120),
    ('80',   '1/- SUNNI VUNDALU (15J)',     15, 42),
    ('50',   '2/- BESIN NICE (40) 15',      15, 58),
    ('68',   '5/- PALLI VUNDALU (12)60',    60, 36),
    ('2702', '5/- HALWA (12)32',            32, 40),
    ('2504', '5/- MIXING NICE (12)32',      32, 40),
    ('137',  '5/- DIL KUSH (30) 6J',         6, 105),
    ('1262', '5/- SWEET TOMATO (24)',       24, 40)
  ) as v(c, n, j, rt);

  -- Numbering comes from number_series, created on first use.
  v_no := next_doc_no(v_org, 'invoice');
  assert v_no = '0001', format('first invoice number should be 0001, got %s', v_no);

  -- Invoice: the operator types only CODE, Boxes, Rate --------------
  insert into invoices (org_id, invoice_no, customer_id, location_id, invoice_date)
  values (v_org, v_no, v_cust, v_loc, date '2026-08-25') returning id into v_inv;

  insert into invoice_items (invoice_id, item_id, boxes, rate)
  select v_inv, i.id, b, rt
  from (values
    ('8',2,42),('2',3,40),('200A',3,100),('1',3,120),('57',4,40),('44',2,40),
    ('2686',1,40),('83',1,40),('87',1,120),('31',1,120),('80',2,42),('50',1,58),
    ('68',2,36),('2702',1,40),('2504',2,40),('137',2,105),('1262',1,40)
  ) as v(c, b, rt)
  join items i on i.org_id = v_org and i.item_code = v.c;

  -- Row 1 derived columns
  select ii.units_per_box, ii.qty, ii.amount into r
  from invoice_items ii join items i on i.id = ii.item_id
  where ii.invoice_id = v_inv and i.item_code = '8';
  assert r.units_per_box = 32, format('row 1 jars: %s', r.units_per_box);
  assert r.qty = 64,           format('row 1 qty: %s', r.qty);
  assert r.amount = 2688,      format('row 1 total: %s', r.amount);

  -- Footer
  select count(*), sum(boxes), sum(qty), sum(amount) into n_lines, t_boxes, t_qty, t_net
  from invoice_items where invoice_id = v_inv;
  assert n_lines = 17,   format('lines: %s', n_lines);
  assert t_boxes = 32,   format('total boxes: %s', t_boxes);
  assert t_qty = 753,    format('total qty: %s', t_qty);
  assert t_net = 34258,  format('net amount: %s', t_net);

  -- Stock leaves only on confirm ------------------------------------
  select count(*) into n_ledger from stock_ledger where ref_table = 'invoices' and ref_id = v_inv;
  assert n_ledger = 0, 'draft invoice must not touch stock';

  update invoices set status = 'confirmed' where id = v_inv;
  select count(*) into n_ledger from stock_ledger where ref_table = 'invoices' and ref_id = v_inv;
  assert n_ledger = 17, format('confirmed invoice should post 17 ledger rows, got %s', n_ledger);

  -- Negative stock is allowed and flagged, never blocked --------------
  select is_negative, qty_boxes into r
  from v_stock_on_hand s join items i on i.id = s.item_id
  where i.org_id = v_org and i.item_code = '8' and s.location_id = v_loc;
  assert r.is_negative, 'stock should be negative after selling from empty';
  assert r.qty_boxes = -2, format('code 8 should be -2 boxes, got %s', r.qty_boxes);

  select count(*) into n_ledger from closing_stock_report(v_org, date '2026-08-25') where is_negative;
  assert n_ledger = 17, format('closing stock report should flag 17 negative rows, got %s', n_ledger);

  -- Packing locks once an item has stock movement --------------------
  select id into v_item8 from items where org_id = v_org and item_code = '8';
  begin
    update items set units_per_box = 40 where id = v_item8;
    raise exception 'packing lock did not fire';
  exception when others then
    if sqlerrm not like 'Packing is locked%' then raise; end if;
  end;

  -- Rate difference credits money but never moves stock ---------------
  insert into sales_returns (org_id, customer_id, invoice_id, kind, total)
  values (v_org, v_cust, v_inv, 'rate_difference', 64) returning id into v_ret;
  insert into sales_return_items (return_id, item_id, qty, uom_id, old_rate, new_rate, amount)
  values (v_ret, v_item8, 0, v_uom, 42, 41, 64);
  perform post_return_stock(v_ret);
  select count(*) into n_ledger from stock_ledger where ref_table = 'sales_returns' and ref_id = v_ret;
  assert n_ledger = 0, 'rate_difference must not write stock_ledger rows';

  -- Breakage credit is orgs.breakage_recovery_pct, not a literal ------
  v_credit := breakage_credit(v_org, 1000);
  assert v_credit = 500, format('breakage credit at 50%% should be 500, got %s', v_credit);
  update orgs set breakage_recovery_pct = 40 where id = v_org;
  v_credit := breakage_credit(v_org, 1000);
  assert v_credit = 400, format('breakage credit at 40%% should be 400, got %s', v_credit);

  -- Outstanding = opening + billed - received - returned ---------------
  select outstanding into r from v_customer_outstanding where customer_id = v_cust;
  assert r.outstanding = 34258 - 64, format('outstanding: %s', r.outstanding);

  raise notice 'OK: quotation reproduced — 17 lines, 32 boxes, 753 qty, net 34258.00';
end $$;

rollback;
