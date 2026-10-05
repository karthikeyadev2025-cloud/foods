-- ============================================================
-- JYOTHI FOODS ERP — 57: THE BUSINESS NAME COMES OFF THE PRINTS
--
-- FORWARD ONLY. Never run a file with a lower number than one already applied.
--
-- "I want to remove Jyothi Foods name also from invoice and quote and all in
--  all in prints."
--
-- The name was printed on nine different sheets and could not be turned off on
-- any of them. The print designer has switches for the logo, the address, the
-- FSSAI number and the email — but the name itself was always drawn, and so was
-- the "For JYOTHI FOODS" line above the signature. The internal sheets — the
-- van loading sheet, the godown transfer, the stock count sheet, the barcode
-- labels, the reports — had no switch at all.
--
-- This is one setting rather than nine, because it is one decision. A shop that
-- prints on paper already headed with its own name prints EVERY document on it,
-- and nobody should have to find nine switches to say so once.
--
-- It is on the organisation, not on a print template, for the same reason: the
-- four sales templates can each be designed differently, but whether the paper
-- already carries the name is a fact about the paper.
--
-- Default TRUE, so nothing changes for anyone who has not asked. The switch is
-- in Setup → Business.
-- ============================================================

alter table orgs add column if not exists print_org_name boolean not null default true;

comment on column orgs.print_org_name is
  'Print the business name at the top of documents. Off when printing on pre-printed letterhead.';

-- v_me is what every screen reads the org from, so the setting has to be on it.
-- `create or replace view` may only APPEND, so it goes last.
create or replace view v_me as
select s.id as staff_id, s.auth_uid, s.full_name, s.phone, s.role, s.is_mestry, s.is_active,
       o.id as org_id, o.name as org_name, o.address, o.phone as org_phone, o.fssai_no,
       o.breakage_recovery_pct, o.interest_pct_pa, o.credit_days, o.jurisdiction,
       o.license_valid_till,
       o.logo_url, o.signature_url, o.email as org_email, o.tagline, o.bank_details,
       o.print_org_name
from staff s join orgs o on o.id = s.org_id
where s.auth_uid = auth.uid();
