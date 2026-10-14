-- Date of the first installment; later ones fall on "paymentDay" of each
-- following month. Existing rows get the first "paymentDay" on or after the day
-- they were created, which is what the app showed before this column existed.
alter table public.wallet_loans
  add column "firstPaymentDate" date;

update public.wallet_loans l
set "firstPaymentDate" = case
  when make_date(
         extract(year from l."createdAt")::int,
         extract(month from l."createdAt")::int,
         least(l."paymentDay", extract(day from (date_trunc('month', l."createdAt") + interval '1 month - 1 day'))::int)
       ) >= l."createdAt"::date
  then make_date(
         extract(year from l."createdAt")::int,
         extract(month from l."createdAt")::int,
         least(l."paymentDay", extract(day from (date_trunc('month', l."createdAt") + interval '1 month - 1 day'))::int)
       )
  else make_date(
         extract(year from l."createdAt" + interval '1 month')::int,
         extract(month from l."createdAt" + interval '1 month')::int,
         least(l."paymentDay", extract(day from (date_trunc('month', l."createdAt" + interval '1 month') + interval '1 month - 1 day'))::int)
       )
end;

alter table public.wallet_loans
  alter column "firstPaymentDate" set not null;
