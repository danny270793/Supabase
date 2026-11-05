-- Insurance charged each month as a percentage of the principal still owed
-- (0.1258 = 0.1258% a month), and changes of the nominal interest rate from a
-- given date for adjustable loans. Installments due on or after a change use
-- its rate; earlier ones keep the rate they had.

alter table public.wallet_loans
  add column "monthlyInsuranceRate" numeric(7, 4)
    constraint wallet_loans_monthly_insurance_rate_range
      check ("monthlyInsuranceRate" >= 0);

create table public.wallet_loan_rate_changes (
  id                    uuid primary key default gen_random_uuid(),
  "userId"              uuid not null references auth.users(id) on delete cascade,
  "loanId"              uuid not null references public.wallet_loans(id) on delete cascade,
  "nominalInterestRate" numeric(7, 4) not null
    constraint wallet_loan_rate_changes_rate_range
      check ("nominalInterestRate" >= 0),
  "effectiveFrom"       date not null,
  "createdAt"           timestamptz not null default now(),
  "updatedAt"           timestamptz not null default now(),
  "deletedAt"           timestamptz
);

create trigger wallet_loan_rate_changes_set_updated_at
  before update on public.wallet_loan_rate_changes
  for each row execute function public.set_updated_at();

create index wallet_loan_rate_changes_user_id_idx
  on public.wallet_loan_rate_changes ("userId");
create index wallet_loan_rate_changes_loan_id_idx
  on public.wallet_loan_rate_changes ("loanId");
create index wallet_loan_rate_changes_deleted_at_idx
  on public.wallet_loan_rate_changes ("deletedAt");

alter table public.wallet_loan_rate_changes enable row level security;

revoke all on public.wallet_loan_rate_changes from anon;

create policy "users can select own loan rate changes"
  on public.wallet_loan_rate_changes for select
  using (auth.uid() = "userId" and "deletedAt" is null);

create policy "users can insert own loan rate changes"
  on public.wallet_loan_rate_changes for insert
  with check (
    auth.uid() = "userId"
    and exists (
      select 1 from public.wallet_loans l
      where l.id = "loanId" and l."userId" = auth.uid()
    )
  );

create policy "users can update own loan rate changes"
  on public.wallet_loan_rate_changes for update
  using (auth.uid() = "userId");

create or replace function public.soft_delete_wallet_loan_rate_change(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  update public.wallet_loan_rate_changes
  set "deletedAt" = now()
  where id = p_id
    and "userId" = auth.uid()
    and "deletedAt" is null;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

revoke all on function public.soft_delete_wallet_loan_rate_change(uuid) from public;
grant execute on function public.soft_delete_wallet_loan_rate_change(uuid) to authenticated;
