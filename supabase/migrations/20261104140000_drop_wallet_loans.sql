-- Loans are gone from the apps: they are now recorded as recurring movements.
-- DESTRUCTIVE: deletes every loan, payment to capital and rate change.
drop function if exists public.soft_delete_wallet_loan_rate_change(uuid);
drop function if exists public.soft_delete_wallet_loan_capital_payment(uuid);
drop function if exists public.soft_delete_wallet_loan(uuid);

drop table if exists public.wallet_loan_rate_changes;
drop table if exists public.wallet_loan_capital_payments;
drop table if exists public.wallet_loans;
