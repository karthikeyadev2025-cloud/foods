-- ============================================================
-- Storage buckets. Run once in the Supabase SQL Editor (the
-- storage schema exists only on Supabase, so apply.sh skips this).
--
--   branding  public   logo and signature images (printed documents)
--   catalogs  public   price-list / festival PDFs pushed on WhatsApp
--   backups   private  org snapshots; only the owner reads their own
-- ============================================================
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('branding', 'branding', true, 2097152, array['image/png', 'image/jpeg', 'image/webp', 'image/svg+xml'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('catalogs', 'catalogs', true, 20971520, array['application/pdf'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit)
values ('backups', 'backups', false, 524288000)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;

-- Files live under <org_id>/... in every bucket; the first folder decides who may touch them.
drop policy if exists branding_read on storage.objects;
create policy branding_read on storage.objects for select using (bucket_id = 'branding');
drop policy if exists branding_write on storage.objects;
create policy branding_write on storage.objects for all to authenticated
  using (bucket_id = 'branding' and (storage.foldername(name))[1] = public.my_org_id()::text and public.my_role() = 'owner')
  with check (bucket_id = 'branding' and (storage.foldername(name))[1] = public.my_org_id()::text and public.my_role() = 'owner');

drop policy if exists catalogs_read on storage.objects;
create policy catalogs_read on storage.objects for select using (bucket_id = 'catalogs');
drop policy if exists catalogs_write on storage.objects;
create policy catalogs_write on storage.objects for all to authenticated
  using (bucket_id = 'catalogs' and (storage.foldername(name))[1] = public.my_org_id()::text and public.can_edit('messaging'))
  with check (bucket_id = 'catalogs' and (storage.foldername(name))[1] = public.my_org_id()::text and public.can_edit('messaging'));

-- Delivery proof photos from the driver's phone: private, read by anyone in the org.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proofs', 'proofs', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists proofs_read on storage.objects;
create policy proofs_read on storage.objects for select to authenticated
  using (bucket_id = 'proofs' and (storage.foldername(name))[1] = public.my_org_id()::text);
drop policy if exists proofs_write on storage.objects;
create policy proofs_write on storage.objects for insert to authenticated
  with check (bucket_id = 'proofs' and (storage.foldername(name))[1] = public.my_org_id()::text and public.can_view('invoices'));

-- Backups are written by the backup-org edge function (service role, bypasses these); the owner may only read.
drop policy if exists backups_owner_read on storage.objects;
create policy backups_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'backups' and (storage.foldername(name))[1] = public.my_org_id()::text and public.my_role() = 'owner');


-- Product photos, for the item master and the printed rate card. Public, because a
-- rate card is meant to be handed to customers; writing needs Items edit rights.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('products', 'products', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

-- Anyone may look — the point of a rate card is that customers can see it. Only
-- somebody who may edit items can put one there, and only inside their own org's folder.
drop policy if exists products_read on storage.objects;
create policy products_read on storage.objects for select using (bucket_id = 'products');
drop policy if exists products_write on storage.objects;
create policy products_write on storage.objects for all to authenticated
  using (bucket_id = 'products' and (storage.foldername(name))[1] = public.my_org_id()::text and public.can_edit('items'))
  with check (bucket_id = 'products' and (storage.foldername(name))[1] = public.my_org_id()::text and public.can_edit('items'));

