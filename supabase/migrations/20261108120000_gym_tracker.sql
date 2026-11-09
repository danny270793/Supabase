-- Gym Tracker: exercises, routines (weekly plan), workouts and exercise photos.
--
-- Every table carries "userId" so row level security is a plain equality check.
-- Child rows reference their parent through ("parentId", "userId"), so a row
-- can never point at another user's exercise, routine or workout.
-- Exercises, routines and workouts are soft-deleted ("deletedAt"); workout
-- history keeps pointing at exercises that were removed from the list.
-- Loads are numeric: pounds for weight exercises, disc count for stack
-- exercises ("loadType" = 'discs').

-- ---------------------------------------------------------------------------
-- exercises
-- ---------------------------------------------------------------------------
create table public.gym_exercises (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null check (length(btrim(name)) > 0),
  "primaryMuscles" text[] not null default '{}',
  "secondaryMuscles" text[] not null default '{}',
  equipment text not null default 'other',
  "loadType" text not null default 'weight' check ("loadType" in ('weight', 'discs')),
  notes text,
  -- Object paths in the gym-exercise-images bucket: '<userId>/<uuid>.jpg'.
  "imagePaths" text[] not null default '{}',
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz,
  unique (id, "userId")
);

create index gym_exercises_user_idx on public.gym_exercises ("userId") where "deletedAt" is null;

-- ---------------------------------------------------------------------------
-- routines (a reusable training day) and their planned exercises
-- ---------------------------------------------------------------------------
create table public.gym_routines (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (length(btrim(title)) > 0),
  notes text,
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz,
  unique (id, "userId")
);

create index gym_routines_user_idx on public.gym_routines ("userId") where "deletedAt" is null;

create table public.gym_routine_exercises (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  "routineId" uuid not null,
  "exerciseId" uuid not null,
  position integer not null check (position > 0),
  sets integer not null check (sets > 0),
  reps integer not null check (reps > 0),
  load numeric(8, 2) check (load is null or load >= 0),
  notes text,
  foreign key ("routineId", "userId") references public.gym_routines (id, "userId") on delete cascade,
  foreign key ("exerciseId", "userId") references public.gym_exercises (id, "userId"),
  unique ("routineId", position)
);

create index gym_routine_exercises_exercise_idx on public.gym_routine_exercises ("exerciseId");

-- ---------------------------------------------------------------------------
-- weekly plan: weekday (1 = Monday .. 7 = Sunday) -> routine; no row = rest
-- ---------------------------------------------------------------------------
create table public.gym_weekly_plan (
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  weekday smallint not null check (weekday between 1 and 7),
  "routineId" uuid not null,
  "updatedAt" timestamptz not null default now(),
  primary key ("userId", weekday),
  foreign key ("routineId", "userId") references public.gym_routines (id, "userId") on delete cascade
);

-- ---------------------------------------------------------------------------
-- workouts (a logged day), their exercises and sets
-- ---------------------------------------------------------------------------
create table public.gym_workouts (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  date timestamptz not null,
  "routineId" uuid,
  title text not null default '',
  notes text,
  "finishedAt" timestamptz,
  "createdAt" timestamptz not null default now(),
  "updatedAt" timestamptz not null default now(),
  "deletedAt" timestamptz,
  unique (id, "userId"),
  foreign key ("routineId", "userId") references public.gym_routines (id, "userId")
    on delete set null ("routineId")
);

create index gym_workouts_user_date_idx on public.gym_workouts ("userId", date desc) where "deletedAt" is null;

create table public.gym_workout_exercises (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  "workoutId" uuid not null,
  "exerciseId" uuid not null,
  position integer not null check (position > 0),
  -- Snapshot of the plan when the workout started; null when added ad hoc.
  "plannedSets" integer check ("plannedSets" is null or "plannedSets" > 0),
  "plannedReps" integer check ("plannedReps" is null or "plannedReps" > 0),
  "plannedLoad" numeric(8, 2) check ("plannedLoad" is null or "plannedLoad" >= 0),
  notes text,
  unique (id, "userId"),
  foreign key ("workoutId", "userId") references public.gym_workouts (id, "userId") on delete cascade,
  foreign key ("exerciseId", "userId") references public.gym_exercises (id, "userId")
);

create index gym_workout_exercises_workout_idx on public.gym_workout_exercises ("workoutId");
create index gym_workout_exercises_exercise_idx on public.gym_workout_exercises ("exerciseId");

create table public.gym_workout_sets (
  id uuid primary key default gen_random_uuid(),
  "userId" uuid not null default auth.uid() references auth.users(id) on delete cascade,
  "workoutExerciseId" uuid not null,
  position integer not null check (position > 0),
  reps integer not null default 0 check (reps >= 0),
  load numeric(8, 2) not null default 0 check (load >= 0),
  completed boolean not null default false,
  foreign key ("workoutExerciseId", "userId")
    references public.gym_workout_exercises (id, "userId") on delete cascade,
  unique ("workoutExerciseId", position)
);

-- ---------------------------------------------------------------------------
-- row level security: users only see and change their own rows
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  foreach t in array array[
    'gym_exercises',
    'gym_routines',
    'gym_routine_exercises',
    'gym_weekly_plan',
    'gym_workouts',
    'gym_workout_exercises',
    'gym_workout_sets'
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

-- ---------------------------------------------------------------------------
-- RPCs: save a routine / workout with its children in one transaction.
-- Payloads use the app's JSON shape. security invoker: RLS still applies.
-- ---------------------------------------------------------------------------
create or replace function public.gym_save_routine(p_routine jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := (p_routine ->> 'id')::uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  insert into public.gym_routines (id, "userId", title, notes, "createdAt", "updatedAt", "deletedAt")
  values (
    v_id,
    v_uid,
    p_routine ->> 'title',
    p_routine ->> 'notes',
    coalesce((p_routine ->> 'createdAt')::timestamptz, now()),
    now(),
    null
  )
  on conflict (id) do update
    set title = excluded.title,
        notes = excluded.notes,
        "updatedAt" = now(),
        "deletedAt" = null
    where public.gym_routines."userId" = v_uid;

  -- The id exists but belongs to someone else: the upsert updated nothing.
  if not found then
    raise exception 'not found' using errcode = '42501';
  end if;

  delete from public.gym_routine_exercises
  where "routineId" = v_id and "userId" = v_uid;

  insert into public.gym_routine_exercises
    ("userId", "routineId", "exerciseId", position, sets, reps, load, notes)
  select
    v_uid,
    v_id,
    (e.value ->> 'exerciseId')::uuid,
    e.ordinality::integer,
    (e.value ->> 'sets')::integer,
    (e.value ->> 'reps')::integer,
    (e.value ->> 'load')::numeric,
    e.value ->> 'notes'
  from jsonb_array_elements(coalesce(p_routine -> 'exercises', '[]'::jsonb))
    with ordinality as e(value, ordinality);
end;
$$;

create or replace function public.gym_delete_routine(p_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.gym_routines
  set "deletedAt" = now(), "updatedAt" = now()
  where id = p_id and "userId" = (select auth.uid());

  delete from public.gym_weekly_plan
  where "routineId" = p_id and "userId" = (select auth.uid());
end;
$$;

create or replace function public.gym_save_workout(p_workout jsonb)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid := (p_workout ->> 'id')::uuid;
begin
  if v_uid is null then
    raise exception 'not authenticated' using errcode = '28000';
  end if;

  insert into public.gym_workouts
    (id, "userId", date, "routineId", title, notes, "finishedAt", "createdAt", "updatedAt", "deletedAt")
  values (
    v_id,
    v_uid,
    (p_workout ->> 'date')::timestamptz,
    (p_workout ->> 'routineId')::uuid,
    coalesce(p_workout ->> 'title', ''),
    p_workout ->> 'notes',
    (p_workout ->> 'finishedAt')::timestamptz,
    coalesce((p_workout ->> 'createdAt')::timestamptz, now()),
    now(),
    null
  )
  on conflict (id) do update
    set date = excluded.date,
        "routineId" = excluded."routineId",
        title = excluded.title,
        notes = excluded.notes,
        "finishedAt" = excluded."finishedAt",
        "updatedAt" = now(),
        "deletedAt" = null
    where public.gym_workouts."userId" = v_uid;

  -- The id exists but belongs to someone else: the upsert updated nothing.
  if not found then
    raise exception 'not found' using errcode = '42501';
  end if;

  -- Sets go with their exercise row (on delete cascade).
  delete from public.gym_workout_exercises
  where "workoutId" = v_id and "userId" = v_uid;

  insert into public.gym_workout_exercises
    (id, "userId", "workoutId", "exerciseId", position, "plannedSets", "plannedReps", "plannedLoad", notes)
  select
    (e.value ->> 'id')::uuid,
    v_uid,
    v_id,
    (e.value ->> 'exerciseId')::uuid,
    e.ordinality::integer,
    (e.value -> 'planned' ->> 'sets')::integer,
    (e.value -> 'planned' ->> 'reps')::integer,
    (e.value -> 'planned' ->> 'load')::numeric,
    e.value ->> 'notes'
  from jsonb_array_elements(coalesce(p_workout -> 'exercises', '[]'::jsonb))
    with ordinality as e(value, ordinality);

  insert into public.gym_workout_sets
    ("userId", "workoutExerciseId", position, reps, load, completed)
  select
    v_uid,
    (e.value ->> 'id')::uuid,
    s.ordinality::integer,
    coalesce((s.value ->> 'reps')::integer, 0),
    coalesce((s.value ->> 'load')::numeric, 0),
    coalesce((s.value ->> 'completed')::boolean, false)
  from jsonb_array_elements(coalesce(p_workout -> 'exercises', '[]'::jsonb)) as e(value),
    jsonb_array_elements(coalesce(e.value -> 'sets', '[]'::jsonb))
      with ordinality as s(value, ordinality);
end;
$$;

revoke all on function public.gym_save_routine(jsonb) from public, anon;
revoke all on function public.gym_delete_routine(uuid) from public, anon;
revoke all on function public.gym_save_workout(jsonb) from public, anon;
grant execute on function public.gym_save_routine(jsonb) to authenticated;
grant execute on function public.gym_delete_routine(uuid) to authenticated;
grant execute on function public.gym_save_workout(jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- storage: private bucket, one folder per user ('<userId>/<file>')
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'gym-exercise-images',
  'gym-exercise-images',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp', 'image/heic']
)
on conflict (id) do nothing;

create policy "Gym users can read their own exercise images"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'gym-exercise-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Gym users can upload their own exercise images"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'gym-exercise-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Gym users can update their own exercise images"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'gym-exercise-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'gym-exercise-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "Gym users can delete their own exercise images"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'gym-exercise-images'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
