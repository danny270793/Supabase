-- MMA ScoreCard: store each fighter's full Sherdog profile so the app can show
-- the fighter screen from Supabase. `profile` is the page as the app's
-- FighterProfile JSON (record, KO/submission/decision breakdowns, team and
-- every professional and amateur bout, including non-UFC fights).

alter table public.mma_fighters add column profile jsonb;

comment on column public.mma_fighters.profile is
  'Full Sherdog profile in the app''s FighterProfile JSON shape; null until fetched';

create or replace function public.mma_upsert_fighter(p jsonb)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.mma_fighters as f
    (name, nickname, city_id, birthday, died, height, weight, link, profile, synced_at)
  values (
    p->>'name',
    nullif(btrim(p->>'nickname'), ''),
    public.mma_city_id(p->>'city', public.mma_country_id(p->>'country')),
    (p->>'birthday')::date,
    (p->>'died')::date,
    coalesce((p->>'height')::numeric, 0),
    coalesce((p->>'weight')::numeric, 0),
    p->>'link',
    p->'profile',
    now())
  on conflict (sherdog_id) do update set
    name = excluded.name,
    nickname = excluded.nickname,
    city_id = excluded.city_id,
    birthday = coalesce(excluded.birthday, f.birthday),
    died = coalesce(excluded.died, f.died),
    height = case when (p->>'height') is null then f.height else excluded.height end,
    weight = case when (p->>'weight') is null then f.weight else excluded.weight end,
    link = excluded.link,
    profile = coalesce(excluded.profile, f.profile),
    synced_at = now()
  returning id into v_id;
  return v_id;
end;
$$;
