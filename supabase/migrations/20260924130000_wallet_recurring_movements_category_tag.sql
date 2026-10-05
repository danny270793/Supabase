-- Category and tag on recurring movements, same references as wallet_transactions.
-- Nullable so rows created before this migration stay valid; the app requires both on save.

alter table public.wallet_recurring_movements
  add column "categoryId" uuid references public.wallet_categories(id) on delete set null,
  add column "tagId"      uuid references public.wallet_tags(id) on delete set null;

create index wallet_recurring_movements_category_id_idx
  on public.wallet_recurring_movements ("categoryId");
create index wallet_recurring_movements_tag_id_idx
  on public.wallet_recurring_movements ("tagId");
