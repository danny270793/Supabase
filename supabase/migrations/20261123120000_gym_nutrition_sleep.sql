-- Gym Tracker: nutrition (daily goals + food log) and sleep log.
--
-- Same conventions as 20261108120000_gym_tracker.sql: every table carries
-- "userId" so row level security is a plain equality check, and the
-- logs are soft-deleted ("deletedAt").

-- ---------------------------------------------------------------------------
-- nutrition profile: the inputs used to estimate daily calories and protein
-- (one row per user). Weight is kg and height is cm, whatever unit the app shows.
-- ---------------------------------------------------------------------------
create table public.gym_nutrition_profiles (
  "userId" uuid primary key default auth.uid() references auth.users(id) on delete cascade,
  sex text not null check (sex in ('male', 'female')),
  age integer not null check (age between 14 and 100),
  "weightKg" numeric(5, 1) not null check ("weightKg" between 30 and 300),
  "heightCm" numeric(4, 1) not null check ("heightCm" between 120 and 230),
  activity text not null check (activity in ('sedentary', 'light', 'moderate', 'high', 'extreme')),
  goal text not null check (goal in ('lose', 'maintain', 'gain')),
  "updatedAt" timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- food log: protein (g), calories (kcal) and a description per entry
-- ---------------------------------------------------------------------------
create table public.gym_food_entries (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date timestamptz not null,
  meal text not null default 'snack' check (meal in ('breakfast', 'lunch', 'dinner', 'snack')),
  "proteinGrams" numeric(7, 2) not null default 0 check ("proteinGrams" >= 0),
  calories numeric(8, 2) not null default 0 check (calories >= 0),
  details text not null default '',
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz
);

create index gym_food_entries_user_date_idx
  on public.gym_food_entries ("userId", date desc) where "deletedAt" is null;

-- ---------------------------------------------------------------------------
-- sleep log: a night (stages + wake-ups) or a nap (start and end only)
-- ---------------------------------------------------------------------------
create table public.gym_sleep_entries (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  "startAt" timestamptz not null,
  "endAt" timestamptz not null,
  "isNap" boolean not null default false,
  -- Share of the session in deep / REM sleep (0-100). Null for naps.
  "deepPercent" numeric(5, 2) check ("deepPercent" is null or "deepPercent" between 0 and 100),
  "remPercent" numeric(5, 2) check ("remPercent" is null or "remPercent" between 0 and 100),
  -- Times woken up and total minutes awake during the session. Null for naps.
  awakenings integer check (awakenings is null or awakenings >= 0),
  "awakeMinutes" integer check ("awakeMinutes" is null or "awakeMinutes" >= 0),
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz,
  check ("endAt" > "startAt"),
  check ("endAt" - "startAt" <= interval '24 hours'),
  check (coalesce("deepPercent", 0) + coalesce("remPercent", 0) <= 100),
  check (
    not "isNap"
    or ("deepPercent" is null and "remPercent" is null and awakenings is null and "awakeMinutes" is null)
  )
);

create index gym_sleep_entries_user_end_idx
  on public.gym_sleep_entries ("userId", "endAt" desc) where "deletedAt" is null;

-- ---------------------------------------------------------------------------
-- row level security: users only see and change their own rows
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'gym_nutrition_profiles',
    'gym_food_entries',
    'gym_sleep_entries'
  ] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('alter table public.%I force row level security', t);
    execute format('revoke all on table public.%I from anon', t);
    execute format('revoke all on table public.%I from public', t);
    execute format(
      'grant select, insert, update, delete on table public.%I to authenticated', t
    );
    execute format(
      'create policy "Users can select their own rows" on public.%I
         for select to authenticated using ((select auth.uid()) = "userId")', t
    );
    execute format(
      'create policy "Users can insert their own rows" on public.%I
         for insert to authenticated with check ((select auth.uid()) = "userId")', t
    );
    execute format(
      'create policy "Users can update their own rows" on public.%I
         for update to authenticated
         using ((select auth.uid()) = "userId")
         with check ((select auth.uid()) = "userId")', t
    );
    execute format(
      'create policy "Users can delete their own rows" on public.%I
         for delete to authenticated using ((select auth.uid()) = "userId")', t
    );
  end loop;
end
$$;
