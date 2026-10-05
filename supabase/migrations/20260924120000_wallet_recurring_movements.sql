-- Recurring movements: user-defined expected monthly income (positive value)
-- and outcome (negative value) entries, e.g. salary, rent, subscriptions.

create table public.wallet_recurring_movements (
  id          uuid primary key default gen_random_uuid(),
  "userId"    uuid not null references auth.users(id) on delete cascade,
  name        text not null,
  description text,
  value       numeric not null,
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz
);

create trigger wallet_recurring_movements_set_updated_at
  before update on public.wallet_recurring_movements
  for each row execute function public.set_updated_at();

create index wallet_recurring_movements_user_id_idx
  on public.wallet_recurring_movements ("userId");
create index wallet_recurring_movements_deleted_at_idx
  on public.wallet_recurring_movements ("deletedAt");

alter table public.wallet_recurring_movements enable row level security;

create policy "users can select own recurring movements"
  on public.wallet_recurring_movements for select
  using (auth.uid() = "userId" and "deletedAt" is null);

create policy "users can insert own recurring movements"
  on public.wallet_recurring_movements for insert
  with check (auth.uid() = "userId");

create policy "users can update own recurring movements"
  on public.wallet_recurring_movements for update
  using (auth.uid() = "userId");

create or replace function public.soft_delete_wallet_recurring_movement(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  update public.wallet_recurring_movements
  set "deletedAt" = now()
  where id = p_id
    and "userId" = auth.uid()
    and "deletedAt" is null;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

revoke all on function public.soft_delete_wallet_recurring_movement(uuid) from public;
grant execute on function public.soft_delete_wallet_recurring_movement(uuid) to authenticated;
