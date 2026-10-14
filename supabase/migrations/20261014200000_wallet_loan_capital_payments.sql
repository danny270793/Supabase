-- Extra payments straight to a loan's principal. The app recomputes the
-- remaining installments from the balance left after each one.

create table public.wallet_loan_capital_payments (
  id          uuid primary key default gen_random_uuid(),
  "userId"    uuid not null references auth.users(id) on delete cascade,
  "loanId"    uuid not null references public.wallet_loans(id) on delete cascade,
  value       numeric not null
    constraint wallet_loan_capital_payments_value_positive check (value > 0),
  "paidAt"    date not null,
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz
);

create trigger wallet_loan_capital_payments_set_updated_at
  before update on public.wallet_loan_capital_payments
  for each row execute function public.set_updated_at();

create index wallet_loan_capital_payments_user_id_idx
  on public.wallet_loan_capital_payments ("userId");
create index wallet_loan_capital_payments_loan_id_idx
  on public.wallet_loan_capital_payments ("loanId");
create index wallet_loan_capital_payments_deleted_at_idx
  on public.wallet_loan_capital_payments ("deletedAt");

alter table public.wallet_loan_capital_payments enable row level security;

revoke all on public.wallet_loan_capital_payments from anon;

create policy "users can select own loan capital payments"
  on public.wallet_loan_capital_payments for select
  using (auth.uid() = "userId" and "deletedAt" is null);

create policy "users can insert own loan capital payments"
  on public.wallet_loan_capital_payments for insert
  with check (
    auth.uid() = "userId"
    and exists (
      select 1 from public.wallet_loans l
      where l.id = "loanId" and l."userId" = auth.uid()
    )
  );

create policy "users can update own loan capital payments"
  on public.wallet_loan_capital_payments for update
  using (auth.uid() = "userId");

create or replace function public.soft_delete_wallet_loan_capital_payment(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  n int;
begin
  update public.wallet_loan_capital_payments
  set "deletedAt" = now()
  where id = p_id
    and "userId" = auth.uid()
    and "deletedAt" is null;
  get diagnostics n = row_count;
  return n > 0;
end;
$$;

revoke all on function public.soft_delete_wallet_loan_capital_payment(uuid) from public;
grant execute on function public.soft_delete_wallet_loan_capital_payment(uuid) to authenticated;
