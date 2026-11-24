-- The app now shows weights in lb and kg side by side, so the per-exercise
-- display unit from 20261109120000 is unused. Every row held the default 'lb'.
alter table public.gym_exercises drop column "weightUnit";
