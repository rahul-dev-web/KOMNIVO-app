-- Cover Store marketplace foreign-key lookups with indexes.
create index if not exists store_cart_items_listing_idx on public.store_cart_items(listing_id);
create index if not exists store_order_items_listing_idx on public.store_order_items(listing_id);
create index if not exists store_inquiries_listing_idx on public.store_inquiries(listing_id);
