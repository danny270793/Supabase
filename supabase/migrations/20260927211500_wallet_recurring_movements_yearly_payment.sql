-- Yearly payment lives on recurring charges. The amount stored is the full
-- year; the app shows and projects one twelfth. Existing rows stay false.
alter table public.wallet_transactions
  drop column if exists "yearlyPayment";

alter table public.wallet_recurring_movements
  add column "yearlyPayment" boolean not null default false;
