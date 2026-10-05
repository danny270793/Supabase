-- /cards shows three amounts per card: `balance` (regular purchases and payments),
-- `creditBalance` (deferred installments, i.e. wallet_transactions.creditId set) and
-- their sum as the total debt, computed client side.

drop view if exists public.wallet_cards_with_balance;

create view public.wallet_cards_with_balance
with (security_invoker = true)
as
select
  c.id,
  c."userId",
  c.name,
  c.description,
  c."cutDay",
  c."payDay",
  c."createdAt",
  c."updatedAt",
  c."deletedAt",
  coalesce(agg.total, 0)::numeric as balance,
  coalesce(agg.credit_total, 0)::numeric as "creditBalance"
from public.wallet_cards c
left join (
  select
    wt."cardId",
    sum(wt.value) filter (where wt."creditId" is null)::numeric as total,
    sum(wt.value) filter (where wt."creditId" is not null)::numeric as credit_total
  from public.wallet_transactions wt
  where wt."deletedAt" is null
    and wt."cardId" is not null
  group by wt."cardId"
) agg on agg."cardId" = c.id;

grant select on public.wallet_cards_with_balance to authenticated;
grant select on public.wallet_cards_with_balance to service_role;
