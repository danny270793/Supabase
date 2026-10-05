-- Full annual amount stays in "value". Lists show one twelfth when this is true.
-- Existing rows stay false.
alter table public.wallet_transactions
  add column "yearlyPayment" boolean not null default false;
