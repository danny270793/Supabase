-- Card network. Nullable so cards created before this migration load; the app
-- requires it whenever a card is created or edited.
alter table public.wallet_cards
  add column type text
    constraint wallet_cards_type_check
      check (type in ('visa', 'mastercard', 'diners', 'discover', 'amex', 'other'));

drop view if exists public.wallet_cards_with_balance;

create view public.wallet_cards_with_balance
with (security_invoker = true)
as
select
  c.id,
  c."userId",
  c.name,
  c.type,
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
