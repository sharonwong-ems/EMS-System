-- =====================================================================
-- EMS Fertilizer Sales System — database setup (schema.sql)
-- Paste this whole file into Supabase > SQL Editor and click Run.
-- Safe to run more than once.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. PROFILES (users and their roles)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  email      text,
  full_name  text not null default '',
  role       text not null default 'staff' check (role in ('owner','manager','staff')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);

-- my_role(): the current user's role, only if their account is active
create or replace function public.my_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select p.role from public.profiles p
  where p.id = auth.uid() and p.active
$$;

-- Create a profile automatically when someone signs up
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', ''))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Profiles for anyone who signed up before this file was run
insert into public.profiles (id, email, full_name)
select u.id, u.email, coalesce(u.raw_user_meta_data->>'full_name', '')
from auth.users u
on conflict (id) do nothing;

-- ---------------------------------------------------------------------
-- 2. SETTINGS (rule numbers live here, never in the code)
-- ---------------------------------------------------------------------
create table if not exists public.settings (
  key        text primary key,
  value      text not null,
  note       text,
  updated_at timestamptz not null default now()
);

insert into public.settings (key, value, note) values
  ('overdue_days',       '30',          'An approved order not paid after this many days is overdue'),
  ('low_stock_bags',     '50',          'Stock below this many bags shows a low-stock alert'),
  ('recent_alert_days',  '7',           'Staff see approved/cancelled orders from the last this many days'),
  ('supplier_name',      'Sample Supplier Sdn Bhd', 'Supplier for low-stock WhatsApp'),
  ('supplier_whatsapp',  '60123456789', 'Supplier WhatsApp number, country code first, no + or spaces (sample)')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------
-- 3. AUDIT LOG (who did what, when)
-- ---------------------------------------------------------------------
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  who        uuid,
  who_email  text,
  action     text not null,
  table_name text not null,
  record_id  text,
  details    jsonb
);

create or replace function public.write_audit(p_action text, p_table text, p_record text, p_details jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_log (who, who_email, action, table_name, record_id, details)
  values (auth.uid(),
          (select p.email from public.profiles p where p.id = auth.uid()),
          p_action, p_table, p_record, p_details);
$$;
revoke execute on function public.write_audit(text, text, text, jsonb) from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. PRODUCTS (fertilizers and stock) — business table 1
-- ---------------------------------------------------------------------
create table if not exists public.products (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references auth.users(id) on delete set null,
  name          text not null unique,
  price_per_bag numeric(12,2) not null default 0 check (price_per_bag >= 0),
  stock_bags    integer not null default 0 check (stock_bags >= 0),
  active        boolean not null default true
);

-- Sample fertilizers
insert into public.products (name, price_per_bag, stock_bags) values
  ('NPK 15-15-15',            95.00, 120),
  ('Urea 46%',                88.50,  42),
  ('Compound Blue 12-12-17', 110.00,  75),
  ('Organic Chicken Manure',  18.90, 300)
on conflict (name) do nothing;

-- ---------------------------------------------------------------------
-- 5. ORDERS — business table 2
-- items = list of { product_id, name, bags, price }
-- ---------------------------------------------------------------------
create table if not exists public.orders (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  created_by    uuid default auth.uid() references auth.users(id) on delete set null,
  customer_name text not null check (length(trim(customer_name)) > 0),
  order_date    date not null default current_date,
  items         jsonb not null default '[]'::jsonb,
  amount        numeric(12,2) not null default 0,
  status        text not null default 'pending'
                check (status in ('pending','approved','paid','cancelled')),
  approved_by   uuid references auth.users(id) on delete set null,
  approved_at   timestamptz,
  paid_at       timestamptz,
  cancelled_at  timestamptz
);

create index if not exists orders_status_idx     on public.orders (status);
create index if not exists orders_order_date_idx on public.orders (order_date);
create index if not exists orders_created_by_idx on public.orders (created_by);

-- Order rules: prices come from the products table, amount is calculated,
-- only manager/owner change status, stock goes down on approve and back on cancel.
create or replace function public.orders_before_write()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role  text := public.my_role();
  v_item  record;
  v_prod  record;
  v_total numeric := 0;
  v_items jsonb := '[]'::jsonb;
begin
  if tg_op = 'INSERT' then
    new.status       := 'pending';
    new.approved_by  := null;
    new.approved_at  := null;
    new.paid_at      := null;
    new.cancelled_at := null;
    if auth.uid() is not null then
      new.created_by := auth.uid();
    end if;
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;

  -- (Re)build the item list and amount when the order is new or its items change
  if tg_op = 'INSERT' or new.items is distinct from old.items then
    if tg_op = 'UPDATE' and old.status <> 'pending' then
      raise exception 'Only orders waiting for approval can be changed.';
    end if;
    if jsonb_typeof(new.items) <> 'array' or jsonb_array_length(new.items) = 0 then
      raise exception 'Please add at least one fertilizer to the order.';
    end if;
    for v_item in
      select (e->>'product_id')::uuid as pid, (e->>'bags')::int as bags
      from jsonb_array_elements(new.items) e
    loop
      if v_item.bags is null or v_item.bags <= 0 then
        raise exception 'Number of bags must be more than 0.';
      end if;
      select p.id, p.name, p.price_per_bag into v_prod
      from public.products p where p.id = v_item.pid and p.active;
      if not found then
        raise exception 'One of the fertilizers in this order is not available.';
      end if;
      v_items := v_items || jsonb_build_object(
        'product_id', v_prod.id, 'name', v_prod.name,
        'bags', v_item.bags, 'price', v_prod.price_per_bag);
      v_total := v_total + v_item.bags * v_prod.price_per_bag;
    end loop;
    new.items  := v_items;
    new.amount := round(v_total, 2);
  end if;

  if tg_op = 'UPDATE' then
    if new.status is distinct from old.status then
      if auth.uid() is not null and coalesce(v_role, '') not in ('manager','owner') then
        raise exception 'Only a manager or the owner can change the order status.';
      end if;

      if old.status = 'pending' and new.status = 'approved' then
        for v_item in
          select (e->>'product_id')::uuid as pid, sum((e->>'bags')::int) as bags
          from jsonb_array_elements(new.items) e group by 1
        loop
          select p.id, p.name, p.stock_bags into v_prod
          from public.products p where p.id = v_item.pid for update;
          if not found then
            raise exception 'One of the fertilizers in this order no longer exists.';
          end if;
          if v_prod.stock_bags < v_item.bags then
            raise exception '% has only % bags in stock, not enough for % bags.',
              v_prod.name, v_prod.stock_bags, v_item.bags;
          end if;
          update public.products set stock_bags = stock_bags - v_item.bags where id = v_item.pid;
        end loop;
        new.approved_by := auth.uid();
        new.approved_at := now();

      elsif old.status = 'approved' and new.status = 'paid' then
        new.paid_at := now();

      elsif old.status = 'approved' and new.status = 'cancelled' then
        for v_item in
          select (e->>'product_id')::uuid as pid, sum((e->>'bags')::int) as bags
          from jsonb_array_elements(new.items) e group by 1
        loop
          update public.products set stock_bags = stock_bags + v_item.bags where id = v_item.pid;
        end loop;
        new.cancelled_at := now();

      elsif old.status = 'pending' and new.status = 'cancelled' then
        new.cancelled_at := now();

      else
        raise exception 'This status change is not allowed.';
      end if;
    else
      new.approved_by  := old.approved_by;
      new.approved_at  := old.approved_at;
      new.paid_at      := old.paid_at;
      new.cancelled_at := old.cancelled_at;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists orders_before_write on public.orders;
create trigger orders_before_write
  before insert or update on public.orders
  for each row execute function public.orders_before_write();

-- ---------------------------------------------------------------------
-- 6. AI BRIEFS (checked AI reports)
-- ---------------------------------------------------------------------
create table if not exists public.ai_briefs (
  id         uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  created_by uuid default auth.uid() references auth.users(id) on delete set null,
  title      text not null default '',
  prompt     text not null default '',
  content    text not null,
  checked    boolean not null default false check (checked)
);

-- ---------------------------------------------------------------------
-- 7. AUDIT TRIGGERS
-- ---------------------------------------------------------------------
create or replace function public.audit_orders()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.write_audit('create', 'orders', new.id::text,
      jsonb_build_object('customer', new.customer_name, 'amount', new.amount));
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    perform public.write_audit('status_change', 'orders', new.id::text,
      jsonb_build_object('customer', new.customer_name, 'from', old.status, 'to', new.status));
  elsif tg_op = 'DELETE' then
    perform public.write_audit('delete', 'orders', old.id::text,
      jsonb_build_object('customer', old.customer_name, 'amount', old.amount, 'status', old.status));
  end if;
  return null;
end; $$;

drop trigger if exists audit_orders on public.orders;
create trigger audit_orders
  after insert or update or delete on public.orders
  for each row execute function public.audit_orders();

create or replace function public.audit_products()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform public.write_audit('create', 'products', new.id::text,
      jsonb_build_object('name', new.name, 'price', new.price_per_bag, 'stock', new.stock_bags));
  elsif tg_op = 'UPDATE' then
    if new.stock_bags is distinct from old.stock_bags then
      perform public.write_audit('stock_change', 'products', new.id::text,
        jsonb_build_object('name', new.name, 'from', old.stock_bags, 'to', new.stock_bags));
    end if;
    if new.price_per_bag is distinct from old.price_per_bag
       or new.name is distinct from old.name
       or new.active is distinct from old.active then
      perform public.write_audit('update', 'products', new.id::text,
        jsonb_build_object('name', new.name, 'price', new.price_per_bag, 'active', new.active));
    end if;
  elsif tg_op = 'DELETE' then
    perform public.write_audit('delete', 'products', old.id::text, jsonb_build_object('name', old.name));
  end if;
  return null;
end; $$;

drop trigger if exists audit_products on public.products;
create trigger audit_products
  after insert or update or delete on public.products
  for each row execute function public.audit_products();

-- Only the owner (or the SQL Editor) may change role or active; log it
create or replace function public.profiles_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.role is distinct from old.role or new.active is distinct from old.active) then
    if auth.uid() is not null and coalesce(public.my_role(), '') <> 'owner' then
      raise exception 'Only the owner can change roles or switch accounts on/off.';
    end if;
    perform public.write_audit('role_change', 'profiles', new.id::text,
      jsonb_build_object('email', new.email,
        'role_from', old.role, 'role_to', new.role,
        'active_from', old.active, 'active_to', new.active));
  end if;
  new.id := old.id;
  new.email := old.email;
  return new;
end; $$;

drop trigger if exists profiles_guard on public.profiles;
create trigger profiles_guard
  before update on public.profiles
  for each row execute function public.profiles_guard();

create or replace function public.audit_settings()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  new.updated_at := now();
  if new.value is distinct from old.value then
    perform public.write_audit('setting_change', 'settings', new.key,
      jsonb_build_object('from', old.value, 'to', new.value));
  end if;
  return new;
end; $$;

drop trigger if exists audit_settings on public.settings;
create trigger audit_settings
  before update on public.settings
  for each row execute function public.audit_settings();

-- ---------------------------------------------------------------------
-- 8. ROW LEVEL SECURITY
-- ---------------------------------------------------------------------
alter table public.profiles  enable row level security;
alter table public.settings  enable row level security;
alter table public.audit_log enable row level security;
alter table public.products  enable row level security;
alter table public.orders    enable row level security;
alter table public.ai_briefs enable row level security;

-- profiles
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.my_role() in ('manager','owner'));
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using ((id = auth.uid() and public.my_role() is not null) or public.my_role() = 'owner')
  with check ((id = auth.uid() and public.my_role() is not null) or public.my_role() = 'owner');
drop policy if exists profiles_delete on public.profiles;
create policy profiles_delete on public.profiles for delete to authenticated
  using (public.my_role() = 'owner');

-- settings
drop policy if exists settings_select on public.settings;
create policy settings_select on public.settings for select to authenticated
  using (public.my_role() is not null);
drop policy if exists settings_owner_all on public.settings;
create policy settings_owner_all on public.settings for all to authenticated
  using (public.my_role() = 'owner') with check (public.my_role() = 'owner');

-- audit_log (read only; rows are written by triggers)
drop policy if exists audit_select on public.audit_log;
create policy audit_select on public.audit_log for select to authenticated
  using (public.my_role() in ('manager','owner'));

-- products
drop policy if exists products_select on public.products;
create policy products_select on public.products for select to authenticated
  using (public.my_role() is not null);
drop policy if exists products_insert on public.products;
create policy products_insert on public.products for insert to authenticated
  with check (public.my_role() in ('manager','owner'));
drop policy if exists products_update on public.products;
create policy products_update on public.products for update to authenticated
  using (public.my_role() in ('manager','owner'))
  with check (public.my_role() in ('manager','owner'));
drop policy if exists products_delete on public.products;
create policy products_delete on public.products for delete to authenticated
  using (public.my_role() = 'owner');

-- orders
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (public.my_role() in ('manager','owner')
         or (public.my_role() = 'staff' and created_by = auth.uid()));
drop policy if exists orders_insert on public.orders;
create policy orders_insert on public.orders for insert to authenticated
  with check (public.my_role() is not null and created_by = auth.uid());
drop policy if exists orders_update on public.orders;
create policy orders_update on public.orders for update to authenticated
  using (public.my_role() in ('manager','owner')
         or (public.my_role() = 'staff' and created_by = auth.uid() and status = 'pending'))
  with check (public.my_role() in ('manager','owner')
         or (public.my_role() = 'staff' and created_by = auth.uid() and status = 'pending'));
drop policy if exists orders_delete on public.orders;
create policy orders_delete on public.orders for delete to authenticated
  using (public.my_role() = 'owner');

-- ai_briefs (owner only, matches the Report page)
drop policy if exists ai_briefs_owner_all on public.ai_briefs;
create policy ai_briefs_owner_all on public.ai_briefs for all to authenticated
  using (public.my_role() = 'owner') with check (public.my_role() = 'owner');

-- ---------------------------------------------------------------------
-- 9. ACCESS FOR LOGGED-IN USERS ONLY
-- ---------------------------------------------------------------------
revoke all on public.profiles, public.settings, public.audit_log,
              public.products, public.orders, public.ai_briefs from anon;
grant usage on schema public to authenticated;
grant select, insert, update, delete on public.profiles, public.settings,
      public.products, public.orders, public.ai_briefs to authenticated;
grant select on public.audit_log to authenticated;
revoke execute on function public.my_role() from public, anon;
grant execute on function public.my_role() to authenticated;

-- Done. Next: sign up in the app, then make yourself the owner (see instructions).
