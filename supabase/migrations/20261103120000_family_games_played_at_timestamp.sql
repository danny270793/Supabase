-- Store the time a match was played, not just the date.
-- Existing rows keep their date and get 00:00:00 as the time.
-- "timestamp" (no time zone) keeps the wall-clock value the user picked,
-- the same way the old "date" column did.

alter table public.fg_matches
  alter column played_at drop default;

alter table public.fg_matches
  alter column played_at type timestamp without time zone
  using played_at::timestamp;

alter table public.fg_matches
  alter column played_at set default (now() at time zone 'utc');

drop function if exists public.fg_save_match(uuid, uuid, date, jsonb);

create or replace function public.fg_save_match(
  p_match_id uuid,
  p_game_id uuid,
  p_played_at timestamp without time zone,
  p_scores jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_type text;
  v_id uuid;
  v_elem jsonb;
  v_user uuid;
  v_email text;
  v_seen uuid[] := '{}';
  v_points int;
  v_maravilla int;
  v_monedas int;
  v_rojo int;
  v_azul int;
  v_amarillo int;
  v_verde int;
  v_morado int;
  v_count int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not public.fg_can_access_game(p_game_id) then
    raise exception 'not_a_member';
  end if;

  select g.type into v_type
  from public.fg_games g
  where g.id = p_game_id;

  if v_type is null then
    raise exception 'game_not_found';
  end if;

  v_count := jsonb_array_length(coalesce(p_scores, '[]'::jsonb));
  if v_count < 2 then
    raise exception 'at_least_two_players';
  end if;

  if p_match_id is null then
    insert into public.fg_matches (game_id, played_at, created_by)
    values (p_game_id, coalesce(p_played_at, (now() at time zone 'utc')), auth.uid())
    returning id into v_id;
  else
    update public.fg_matches
    set played_at = coalesce(p_played_at, played_at),
        updated_at = now()
    where id = p_match_id
      and game_id = p_game_id
    returning id into v_id;

    if v_id is null then
      raise exception 'match_not_found';
    end if;

    delete from public.fg_match_scores where match_id = v_id;
  end if;

  for v_elem in select jsonb_array_elements(p_scores)
  loop
    v_user := (v_elem->>'user_id')::uuid;
    if v_user = any (v_seen) then
      raise exception 'duplicate_player';
    end if;
    v_seen := array_append(v_seen, v_user);

    select m.email into v_email
    from public.fg_game_members m
    where m.game_id = p_game_id
      and m.user_id = v_user;

    if v_email is null then
      raise exception 'player_not_in_game';
    end if;

    v_maravilla := coalesce((v_elem->>'maravilla')::int, 0);
    v_monedas := coalesce((v_elem->>'monedas')::int, 0);
    v_rojo := coalesce((v_elem->>'rojo')::int, 0);
    v_azul := coalesce((v_elem->>'azul')::int, 0);
    v_amarillo := coalesce((v_elem->>'amarillo')::int, 0);
    v_verde := coalesce((v_elem->>'verde')::int, 0);
    v_morado := coalesce((v_elem->>'morado')::int, 0);

    if v_type = 'seven_wonders' then
      v_points := v_maravilla + v_monedas + v_rojo + v_azul + v_amarillo + v_verde + v_morado;
    else
      v_points := coalesce((v_elem->>'points')::int, 0);
      v_maravilla := 0;
      v_monedas := 0;
      v_rojo := 0;
      v_azul := 0;
      v_amarillo := 0;
      v_verde := 0;
      v_morado := 0;
    end if;

    insert into public.fg_match_scores (
      match_id, user_id, email, points,
      maravilla, monedas, rojo, azul, amarillo, verde, morado
    ) values (
      v_id, v_user, v_email, v_points,
      v_maravilla, v_monedas, v_rojo, v_azul, v_amarillo, v_verde, v_morado
    );
  end loop;

  return v_id;
end;
$$;

revoke all on function public.fg_save_match(uuid, uuid, timestamp without time zone, jsonb) from public, anon;
grant execute on function public.fg_save_match(uuid, uuid, timestamp without time zone, jsonb) to authenticated;
