-- Optional nominal annual interest rate per card, as a percentage (16.5 = 16.5%).
-- The app no longer uses cards' description, so the view stops exposing it
-- (the column stays on wallet_cards so existing values are kept).
alter table public.wallet_cards
  add column "nominalInterestRate" numeric(7, 4)
    constraint wallet_cards_nominal_interest_rate_range
      check ("nominalInterestRate" >= 0);

drop view if exists public.wallet_cards_with_balance;

create view public.wallet_cards_with_balance
with (security_invoker = true)
as
select
  c.id,
  c."userId",
  c.name,
  c."cutDay",
  c."payDay",
  c."nominalInterestRate",
  c."createdAt",
  c."updatedAt",
  c."deletedAt",
  coalesce(agg.total, 0)::numeric as balance
from public.wallet_cards c
left join (
  select
    wt."cardId",
    sum(wt.value)::numeric as total
  from public.wallet_transactions wt
  where wt."deletedAt" is null
    and wt."cardId" is not null
    and wt."creditId" is null
  group by wt."cardId"
) agg on agg."cardId" = c.id;

grant select on public.wallet_cards_with_balance to authenticated;
grant select on public.wallet_cards_with_balance to service_role;
