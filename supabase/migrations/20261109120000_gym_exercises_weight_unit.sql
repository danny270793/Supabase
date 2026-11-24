-- Per-exercise display unit for weight exercises. Loads stay stored in
-- pounds; this only says whether the exercise is logged and shown in lb or
-- kg. Existing rows default to lb.
alter table public.gym_exercises
  add column "weightUnit" text not null default 'lb'
    check ("weightUnit" in ('lb', 'kg'));
