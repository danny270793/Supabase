-- Paying off a deferred credit folds every pending installment into one row dated today.
-- When nothing was paid yet, the credit ends up with a single installment, so the term
-- can now be 1 (the app still requires >= 2 when creating a credit).
alter table public.wallet_credits
  drop constraint if exists "wallet_credits_termMonths_check";

alter table public.wallet_credits
  add constraint "wallet_credits_termMonths_check"
  check ("termMonths" >= 1 and "termMonths" <= 600);
