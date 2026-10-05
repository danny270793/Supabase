-- Deletes must bypass row level security on child tables. A normal delete
-- cascades into members, matches, and scores, and those tables reject the
-- cascade, which surfaces as a foreign-key error in the app.

create or replace function public.fg_delete_game(p_game_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not public.fg_can_access_game(p_game_id) then
    raise exception 'not_a_member';
  end if;
  delete from public.fg_games where id = p_game_id;
end;
$$;

create or replace function public.fg_remove_member(p_member_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select game_id into v_game
  from public.fg_game_members
  where id = p_member_id;

  if v_game is null then
    return;
  end if;
  if not public.fg_can_access_game(v_game) then
    raise exception 'not_a_member';
  end if;

  delete from public.fg_game_members where id = p_member_id;
end;
$$;

create or replace function public.fg_delete_match(p_match_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_game uuid;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;

  select game_id into v_game
  from public.fg_matches
  where id = p_match_id;

  if v_game is null then
    return;
  end if;
  if not public.fg_can_access_game(v_game) then
    raise exception 'not_a_member';
  end if;

  delete from public.fg_matches where id = p_match_id;
end;
$$;

revoke all on function public.fg_delete_game(uuid) from public, anon;
revoke all on function public.fg_remove_member(uuid) from public, anon;
revoke all on function public.fg_delete_match(uuid) from public, anon;

grant execute on function public.fg_delete_game(uuid) to authenticated;
grant execute on function public.fg_remove_member(uuid) to authenticated;
grant execute on function public.fg_delete_match(uuid) to authenticated;

notify pgrst, 'reload schema';
