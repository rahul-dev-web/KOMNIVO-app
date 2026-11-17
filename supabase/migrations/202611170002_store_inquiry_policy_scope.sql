-- Tighten service inquiry insert scope and restrict seller updates to status only.
begin;
drop policy if exists store_inquiries_create_buyer on public.store_inquiries;
create policy store_inquiries_create_buyer on public.store_inquiries
for insert to authenticated with check (
  buyer_id = (select auth.uid())
  and exists (
    select 1 from public.store_listings l
    where l.id = store_inquiries.listing_id
      and l.seller_id = store_inquiries.seller_id
      and l.status = 'published'
      and l.seller_id <> (select auth.uid())
      and l.pricing_model in ('monthly','winnings')
  )
);
revoke update on public.store_inquiries from authenticated;
grant update(status) on public.store_inquiries to authenticated;
commit;
