-- Family Games: shared games, players, and match scores.
-- 7 Wonders stores seven categories; other games store one point value.
-- Highest total wins. Everyone below that total takes a loss. A tie at the
-- top counts as a win for each tied player.

create table public.fg_games (
  id uuid primary key default gen_random_uuid(),
  created_by uuid not null references auth.users (id) on delete cascade,
  name text not null,
  type text not null,
  description text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint fg_games_name_not_blank check (char_length(btrim(name)) > 0),
  constraint fg_games_type_check check (type in ('seven_wonders', 'other'))
);

create table public.fg_game_members (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.fg_games (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now(),
  unique (game_id, user_id)
);

create table public.fg_matches (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references public.fg_games (id) on delete cascade,
  played_at date not null default (now() at time zone 'utc')::date,
  created_by uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.fg_match_scores (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.fg_matches (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  email text not null,
  points integer not null default 0,
  maravilla integer not null default 0,
  monedas integer not null default 0,
  rojo integer not null default 0,
  azul integer not null default 0,
  amarillo integer not null default 0,
  verde integer not null default 0,
  morado integer not null default 0,
  unique (match_id, user_id)
);

create index fg_game_members_game_id_idx on public.fg_game_members (game_id);
create index fg_game_members_user_id_idx on public.fg_game_members (user_id);
create index fg_matches_game_id_idx on public.fg_matches (game_id);
create index fg_match_scores_match_id_idx on public.fg_match_scores (match_id);

create or replace function public.fg_can_access_game(p_game_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.fg_games g
    where g.id = p_game_id
      and (
        g.created_by = auth.uid()
        or exists (
          select 1
          from public.fg_game_members m
          where m.game_id = g.id
            and m.user_id = auth.uid()
        )
      )
  );
$$;

alter table public.fg_games enable row level security;
alter table public.fg_game_members enable row level security;
alter table public.fg_matches enable row level security;
alter table public.fg_match_scores enable row level security;

create policy fg_games_select on public.fg_games
  for select to authenticated
  using (public.fg_can_access_game(id));

create policy fg_games_update on public.fg_games
  for update to authenticated
  using (public.fg_can_access_game(id))
  with check (public.fg_can_access_game(id));

create policy fg_games_delete on public.fg_games
  for delete to authenticated
  using (public.fg_can_access_game(id));

create policy fg_game_members_select on public.fg_game_members
  for select to authenticated
  using (public.fg_can_access_game(game_id));

create policy fg_game_members_delete on public.fg_game_members
  for delete to authenticated
  using (public.fg_can_access_game(game_id));

create policy fg_matches_select on public.fg_matches
  for select to authenticated
  using (public.fg_can_access_game(game_id));

create policy fg_matches_delete on public.fg_matches
  for delete to authenticated
  using (public.fg_can_access_game(game_id));

create policy fg_match_scores_select on public.fg_match_scores
  for select to authenticated
  using (
    exists (
      select 1
      from public.fg_matches m
      where m.id = match_id
        and public.fg_can_access_game(m.game_id)
    )
  );

revoke all on public.fg_games from anon, public;
revoke all on public.fg_game_members from anon, public;
revoke all on public.fg_matches from anon, public;
revoke all on public.fg_match_scores from anon, public;

grant select, update, delete on public.fg_games to authenticated;
grant select, delete on public.fg_game_members to authenticated;
grant select, delete on public.fg_matches to authenticated;
grant select on public.fg_match_scores to authenticated;

create or replace function public.fg_create_game(
  p_name text,
  p_type text,
  p_description text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if p_type not in ('seven_wonders', 'other') then
    raise exception 'invalid_type';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'name_required';
  end if;

  select u.email into v_email
  from auth.users u
  where u.id = auth.uid();

  insert into public.fg_games (created_by, name, type, description)
  values (auth.uid(), btrim(p_name), p_type, coalesce(p_description, ''))
  returning id into v_id;

  insert into public.fg_game_members (game_id, user_id, email)
  values (v_id, auth.uid(), coalesce(v_email, ''));

  return v_id;
end;
$$;

create or replace function public.fg_add_member(
  p_game_id uuid,
  p_email text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid;
  v_email text;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated';
  end if;
  if not public.fg_can_access_game(p_game_id) then
    raise exception 'not_a_member';
  end if;
  if p_email is null or char_length(btrim(p_email)) = 0 then
    raise exception 'user_not_found';
  end if;

  select u.id, u.email into v_user, v_email
  from auth.users u
  where lower(u.email) = lower(btrim(p_email))
  limit 1;

  if v_user is null then
    raise exception 'user_not_found';
  end if;

  begin
    insert into public.fg_game_members (game_id, user_id, email)
    values (p_game_id, v_user, v_email);
  exception
    when unique_violation then
      raise exception 'already_member';
  end;
end;
$$;

create or replace function public.fg_save_match(
  p_match_id uuid,
  p_game_id uuid,
  p_played_at date,
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
    values (p_game_id, coalesce(p_played_at, (now() at time zone 'utc')::date), auth.uid())
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

revoke all on function public.fg_can_access_game(uuid) from public, anon;
revoke all on function public.fg_create_game(text, text, text) from public, anon;
revoke all on function public.fg_add_member(uuid, text) from public, anon;
revoke all on function public.fg_save_match(uuid, uuid, date, jsonb) from public, anon;

grant execute on function public.fg_can_access_game(uuid) to authenticated;
grant execute on function public.fg_create_game(text, text, text) to authenticated;
grant execute on function public.fg_add_member(uuid, text) to authenticated;
grant execute on function public.fg_save_match(uuid, uuid, date, jsonb) to authenticated;
