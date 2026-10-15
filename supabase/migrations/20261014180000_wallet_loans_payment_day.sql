-- Loans are paid on a day of the month (1–30), like cards' "payDay", not on a
-- calendar date. Existing rows keep the day of the date they had (31 becomes 30).
alter table public.wallet_loans
  add column "paymentDay" smallint;

update public.wallet_loans
set "paymentDay" = least(extract(day from "paymentDate")::int, 30);

alter table public.wallet_loans
  alter column "paymentDay" set not null,
  add constraint wallet_loans_payment_day_range
    check ("paymentDay" between 1 and 30),
  drop column "paymentDate";
