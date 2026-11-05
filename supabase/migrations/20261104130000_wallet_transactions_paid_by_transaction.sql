-- A deferred credit can be paid off before its installments fall due: the user records
-- one payment transaction and every pending installment points at it through
-- "paidByTransactionId". The app leaves paid installments out of every list and total.
alter table public.wallet_transactions
  add column "paidByTransactionId" uuid
    references public.wallet_transactions(id) on delete set null;

comment on column public.wallet_transactions."paidByTransactionId" is
  'Installment settled early by the transaction with this id. Cleared when that payment is deleted, so the installment becomes pending again.';

create index wallet_transactions_paid_by_transaction_id_idx
  on public.wallet_transactions ("paidByTransactionId")
  where "paidByTransactionId" is not null;

-- Soft-deleting the payment (soft_delete_wallet_transaction) releases its installments.
create or replace function public.wallet_transactions_release_paid_installments()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new."deletedAt" is not null and old."deletedAt" is null then
    update public.wallet_transactions
    set "paidByTransactionId" = null
    where "paidByTransactionId" = new.id
      and "userId" = new."userId";
  end if;
  return new;
end;
$$;

create trigger wallet_transactions_release_paid_installments
  after update of "deletedAt" on public.wallet_transactions
  for each row execute function public.wallet_transactions_release_paid_installments();
