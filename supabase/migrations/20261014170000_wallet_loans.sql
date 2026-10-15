-- Loans owed from an account, tracked on their own (not linked to transactions yet).
-- "paymentDate" is the first installment's due date; later installments fall on
-- the same day of each following month.

create table public.wallet_loans (
  id                    uuid primary key default gen_random_uuid(),
  "userId"              uuid not null references auth.users(id) on delete cascade,
  "accountId"           uuid not null references public.wallet_accounts(id),
  name                  text not null,
  value                 numeric not null
    constraint wallet_loans_value_positive check (value > 0),
  "nominalInterestRate" numeric(7, 4)
    constraint wallet_loans_nominal_interest_rate_range
      check ("nominalInterestRate" >= 0),
  "termMonths"          integer not null
    constraint wallet_loans_term_months_positive check ("termMonths" > 0),
  "paymentDate"         date not null,
  "createdAt"           timestamptz not null default now(),
  "updatedAt"           timestamptz not null default now(),
  "deletedAt"           timestamptz
);

create trigger wallet_loans_set_updated_at
  before update on public.wallet_loans
  for each row execute function public.set_updated_at();

create index wallet_loans_user_id_idx on public.wallet_loans ("userId");
create index wallet_loans_account_id_idx on public.wallet_loans ("accountId");
create index wallet_loans_deleted_at_idx on public.wallet_loans ("deletedAt");

alter table public.wallet_loans enable row level security;

revoke all on public.wallet_loans from anon;

create policy "users can select own loans"
  on public.wallet_loans for select
  using (auth.uid() = "userId" and "deletedAt" is null);

create policy "users can insert own loans"
  on public.wallet_loans for insert
  with check (
    auth.uid() = "userId"
    and exists (
      select 1 from public.wallet_accounts a
      where a.id = "accountId" and a."userId" = auth.uid()
    )
  );

create policy "users can update own loans"
  on public.wallet_loans for update
  using (auth.uid() = "userId")
  with check (
    auth.uid() = "userId"
    and exists (
      select 1 from public.wallet_accounts a
      where a.id = "accountId" and a."userId" = auth.uid()
    )
  );

create or replace function public.soft_delete_wallet_loan(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  update public.wallet_loans
  set "deletedAt" = now()
  where id = p_id
    and "userId" = auth.uid()
    and "deletedAt" is null;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

revoke all on function public.soft_delete_wallet_loan(uuid) from public;
grant execute on function public.soft_delete_wallet_loan(uuid) to authenticated;
