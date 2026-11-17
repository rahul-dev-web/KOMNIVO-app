-- KOMNIVO Store marketplace: public listings, buyer cart, order snapshots and service inquiries.
begin;

create table if not exists public.store_listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.profiles(id) on delete cascade,
  category_key text not null check (category_key in ('assets','artists','players','coaches','orgs','management')),
  title text not null check (char_length(btrim(title)) between 3 and 60),
  role text not null check (char_length(btrim(role)) between 3 and 90),
  description text not null check (char_length(btrim(description)) between 10 and 1200),
  game text not null default '',
  region text not null default 'Remote',
  price_amount numeric(12,2) not null check (price_amount > 0),
  pricing_model text not null check (pricing_model in ('fixed','monthly','winnings','license')),
  currency text not null default 'INR' check (currency = 'INR'),
  status text not null default 'published' check (status in ('draft','published','paused','archived')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint store_listing_pricing_category_check check (
    (category_key = 'assets' and pricing_model in ('fixed','license'))
    or (category_key <> 'assets' and pricing_model in ('monthly','winnings'))
  )
);
create index if not exists store_listings_public_category_created_idx
  on public.store_listings(category_key, created_at desc) where status = 'published';
create index if not exists store_listings_seller_created_idx
  on public.store_listings(seller_id, created_at desc);
create trigger store_listings_set_updated_at before update on public.store_listings
for each row execute function app_private.set_updated_at();
alter table public.store_listings enable row level security;
create policy store_listings_read_published_or_owner on public.store_listings
for select to authenticated using (status = 'published' or seller_id = (select auth.uid()));
create policy store_listings_publish_self on public.store_listings
for insert to authenticated with check (seller_id = (select auth.uid()) and status = 'published');
create policy store_listings_update_owner on public.store_listings
for update to authenticated using (seller_id = (select auth.uid()))
with check (seller_id = (select auth.uid()));
create policy store_listings_delete_owner on public.store_listings
for delete to authenticated using (seller_id = (select auth.uid()));

create table if not exists public.store_cart_items (
  id uuid primary key default gen_random_uuid(),
  buyer_id uuid not null references public.profiles(id) on delete cascade,
  listing_id uuid not null references public.store_listings(id) on delete cascade,
  quantity integer not null default 1 check (quantity between 1 and 20),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (buyer_id, listing_id)
);
create index if not exists store_cart_items_buyer_idx on public.store_cart_items(buyer_id, created_at desc);
create trigger store_cart_items_set_updated_at before update on public.store_cart_items
for each row execute function app_private.set_updated_at();
alter table public.store_cart_items enable row level security;
create policy store_cart_items_read_own on public.store_cart_items
for select to authenticated using (buyer_id = (select auth.uid()));
create policy store_cart_items_add_purchase_listing on public.store_cart_items
for insert to authenticated with check (
  buyer_id = (select auth.uid()) and exists (
    select 1 from public.store_listings l where l.id = listing_id
      and l.status = 'published' and l.pricing_model in ('fixed','license')
      and l.seller_id <> (select auth.uid())
  )
);
create policy store_cart_items_update_own on public.store_cart_items
for update to authenticated using (buyer_id = (select auth.uid()))
with check (
  buyer_id = (select auth.uid()) and exists (
    select 1 from public.store_listings l where l.id = listing_id
      and l.status = 'published' and l.pricing_model in ('fixed','license')
      and l.seller_id <> (select auth.uid())
  )
);
create policy store_cart_items_delete_own on public.store_cart_items
for delete to authenticated using (buyer_id = (select auth.uid()));

create table if not exists public.store_orders (
  id uuid primary key default gen_random_uuid(),
  order_code text not null unique,
  buyer_id uuid not null references public.profiles(id),
  status text not null default 'awaiting_whatsapp'
    check (status in ('awaiting_whatsapp','contacted','confirmed','completed','cancelled')),
  currency text not null default 'INR' check (currency = 'INR'),
  subtotal numeric(12,2) not null check (subtotal > 0),
  whatsapp_phone text not null default '+919981977828',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists store_orders_buyer_created_idx on public.store_orders(buyer_id, created_at desc);
create trigger store_orders_set_updated_at before update on public.store_orders
for each row execute function app_private.set_updated_at();
alter table public.store_orders enable row level security;
create policy store_orders_read_buyer on public.store_orders
for select to authenticated using (buyer_id = (select auth.uid()));

create table if not exists public.store_order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references public.store_orders(id) on delete cascade,
  listing_id uuid references public.store_listings(id) on delete set null,
  title_snapshot text not null,
  pricing_model_snapshot text not null,
  unit_price numeric(12,2) not null check (unit_price > 0),
  quantity integer not null check (quantity between 1 and 20),
  line_total numeric(12,2) not null check (line_total > 0),
  created_at timestamptz not null default now()
);
create index if not exists store_order_items_order_idx on public.store_order_items(order_id);
alter table public.store_order_items enable row level security;
create policy store_order_items_read_buyer on public.store_order_items
for select to authenticated using (exists (
  select 1 from public.store_orders o where o.id = order_id and o.buyer_id = (select auth.uid())
));

create table if not exists public.store_inquiries (
  id uuid primary key default gen_random_uuid(),
  listing_id uuid not null references public.store_listings(id) on delete cascade,
  buyer_id uuid not null references public.profiles(id) on delete cascade,
  seller_id uuid not null references public.profiles(id) on delete cascade,
  message text not null default '' check (char_length(message) <= 1000),
  status text not null default 'open' check (status in ('open','responded','closed')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (buyer_id <> seller_id)
);
create index if not exists store_inquiries_buyer_created_idx on public.store_inquiries(buyer_id, created_at desc);
create index if not exists store_inquiries_seller_created_idx on public.store_inquiries(seller_id, created_at desc);
create trigger store_inquiries_set_updated_at before update on public.store_inquiries
for each row execute function app_private.set_updated_at();
alter table public.store_inquiries enable row level security;
create policy store_inquiries_read_participants on public.store_inquiries
for select to authenticated using (buyer_id = (select auth.uid()) or seller_id = (select auth.uid()));
create policy store_inquiries_create_buyer on public.store_inquiries
for insert to authenticated with check (
  buyer_id = (select auth.uid()) and exists (
    select 1 from public.store_listings l where l.id = listing_id and l.seller_id = seller_id
      and l.status = 'published' and l.seller_id <> (select auth.uid())
      and l.pricing_model in ('monthly','winnings')
  )
);
create policy store_inquiries_update_seller on public.store_inquiries
for update to authenticated using (seller_id = (select auth.uid()))
with check (seller_id = (select auth.uid()));

create or replace function public.create_store_order(p_items jsonb)
returns jsonb language plpgsql security definer
set search_path = public, pg_temp
as $$
declare
  v_buyer uuid := auth.uid();
  v_order_id uuid;
  v_order_code text;
  v_total numeric(12,2) := 0;
  v_item record;
  v_listing public.store_listings%rowtype;
  v_qty integer;
begin
  if v_buyer is null then raise exception 'Authentication required'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'Your cart is empty';
  end if;
  if jsonb_array_length(p_items) > 30 then raise exception 'Cart has too many different listings'; end if;

  for v_item in select value from jsonb_array_elements(p_items) loop
    if coalesce(v_item.value->>'listing_id','') = '' then raise exception 'Invalid cart item'; end if;
    v_qty := greatest(1, least(20, coalesce((v_item.value->>'quantity')::integer, 1)));
    select * into v_listing from public.store_listings
      where id = (v_item.value->>'listing_id')::uuid and status = 'published'
        and pricing_model in ('fixed','license') and seller_id <> v_buyer for share;
    if not found then raise exception 'A listing is no longer available for purchase'; end if;
    v_total := v_total + (v_listing.price_amount * v_qty);
  end loop;
  if v_total <= 0 then raise exception 'Invalid order total'; end if;

  v_order_id := gen_random_uuid();
  v_order_code := 'KOM-' || upper(substr(replace(v_order_id::text, '-', ''), 1, 10));
  insert into public.store_orders(id, order_code, buyer_id, subtotal)
    values (v_order_id, v_order_code, v_buyer, v_total);

  for v_item in select value from jsonb_array_elements(p_items) loop
    v_qty := greatest(1, least(20, coalesce((v_item.value->>'quantity')::integer, 1)));
    select * into v_listing from public.store_listings
      where id = (v_item.value->>'listing_id')::uuid and status = 'published'
        and pricing_model in ('fixed','license') and seller_id <> v_buyer for share;
    insert into public.store_order_items(
      order_id, listing_id, title_snapshot, pricing_model_snapshot, unit_price, quantity, line_total
    ) values (
      v_order_id, v_listing.id, v_listing.title, v_listing.pricing_model,
      v_listing.price_amount, v_qty, v_listing.price_amount * v_qty
    );
    delete from public.store_cart_items where buyer_id = v_buyer and listing_id = v_listing.id;
  end loop;

  return jsonb_build_object(
    'order_id', v_order_id, 'order_code', v_order_code, 'subtotal', v_total,
    'currency', 'INR', 'whatsapp_phone', '+919981977828'
  );
end;
$$;
revoke all on function public.create_store_order(jsonb) from public, anon;
grant execute on function public.create_store_order(jsonb) to authenticated;

grant select, insert, update, delete on public.store_listings to authenticated;
grant select, insert, update, delete on public.store_cart_items to authenticated;
grant select on public.store_orders to authenticated;
grant select on public.store_order_items to authenticated;
grant select, insert, update on public.store_inquiries to authenticated;

commit;
