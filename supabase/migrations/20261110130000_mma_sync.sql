-- MMA ScoreCard: keep the mma_ tables in sync with Sherdog.
--
-- The mma-sync Edge Function (supabase/functions/mma-sync) scrapes Sherdog
-- and hands what it parsed to the functions below, which match rows the same
-- way the original import did and insert or update them in one transaction.
-- pg_cron calls the Edge Function every hour. Only the service role can run
-- these functions.

alter table public.mma_events add column synced_at timestamptz;
alter table public.mma_fighters add column synced_at timestamptz;

comment on column public.mma_events.synced_at is 'Last time mma-sync refreshed this event''s fights';
comment on column public.mma_fighters.synced_at is 'Last time mma-sync refreshed this fighter from Sherdog';

-- Names are compared case- and whitespace-insensitively ("anb Arena" is
-- "ANB Arena", "Rogers Arena,  Vancouver" is "Rogers Arena, Vancouver").
create function public.mma_norm(p text)
returns text
language sql
immutable
set search_path = ''
as $$
  select lower(regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g'))
$$;

create function public.mma_country_id(p_name text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  select id into v_id from public.mma_countries
  where public.mma_norm(name) = public.mma_norm(p_name)
  order by id limit 1;
  if v_id is null then
    insert into public.mma_countries (name) values (nullif(btrim(p_name), ''))
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

create function public.mma_city_id(p_name text, p_country_id bigint)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  select id into v_id from public.mma_cities
  where country_id = p_country_id and public.mma_norm(name) = public.mma_norm(p_name)
  order by id limit 1;
  if v_id is null then
    insert into public.mma_cities (name, country_id) values (nullif(btrim(p_name), ''), p_country_id)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- Sherdog writes "Venue, City, Region, Country". The last part is the
-- country, the one before it the city, and the rest (joined the way the
-- original import did) the venue.
create function public.mma_location_id(p_text text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_parts text[] := string_to_array(coalesce(p_text, ''), ',');
  v_n integer := coalesce(array_length(v_parts, 1), 0);
  v_city_id bigint;
  v_venue text;
  v_id bigint;
begin
  if v_n >= 3 then
    v_city_id := public.mma_city_id(v_parts[v_n - 1], public.mma_country_id(v_parts[v_n]));
    v_venue := array_to_string(v_parts[1:v_n - 2], ', ');
  elsif v_n = 2 then
    v_city_id := public.mma_city_id(v_parts[1], public.mma_country_id(v_parts[2]));
  else
    v_city_id := public.mma_city_id(null, public.mma_country_id(v_parts[1]));
  end if;

  select id into v_id from public.mma_locations
  where city_id = v_city_id and public.mma_norm(name) = public.mma_norm(v_venue)
  order by id limit 1;
  if v_id is null then
    insert into public.mma_locations (name, city_id) values (nullif(btrim(v_venue), ''), v_city_id)
    returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- "Middleweight" reuses the existing Middleweight row; "Catchweight" reuses
-- the catchweight with no weight; a number in the text ("Catchweight 150 lbs")
-- picks or creates the catchweight with that limit.
create function public.mma_category_id(p_text text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_weight integer := substring(coalesce(p_text, '') from '(\d+)')::integer;
  v_name text := btrim(regexp_replace(coalesce(p_text, ''), '\(?\s*\d+\s*(lbs?\.?)?\s*\)?', '', 'gi'));
  v_id bigint;
begin
  if v_name = '' then
    return null;
  end if;
  if v_weight is not null then
    select id into v_id from public.mma_categories
    where public.mma_norm(name) = public.mma_norm(v_name) and weight = v_weight
    order by id limit 1;
  else
    select id into v_id from public.mma_categories
    where public.mma_norm(name) = public.mma_norm(v_name)
    order by (weight is not null), id limit 1;
  end if;
  if v_id is null then
    insert into public.mma_categories (name, weight) values (v_name, v_weight) returning id into v_id;
  end if;
  return v_id;
end;
$$;

create function public.mma_referee_id(p_name text)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if public.mma_norm(p_name) = '' then
    return null;
  end if;
  select id into v_id from public.mma_referees
  where public.mma_norm(name) = public.mma_norm(p_name)
  order by id limit 1;
  if v_id is null then
    insert into public.mma_referees (name) values (btrim(p_name)) returning id into v_id;
  end if;
  return v_id;
end;
$$;

-- p: {name, nickname, city, country, birthday, died, height, weight, link}.
-- Values Sherdog doesn't show (null) keep what the row already has.
create function public.mma_upsert_fighter(p jsonb)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  v_id bigint;
begin
  insert into public.mma_fighters as f
    (name, nickname, city_id, birthday, died, height, weight, link, synced_at)
  values (
    p->>'name',
    nullif(btrim(p->>'nickname'), ''),
    public.mma_city_id(p->>'city', public.mma_country_id(p->>'country')),
    (p->>'birthday')::date,
    (p->>'died')::date,
    coalesce((p->>'height')::numeric, 0),
    coalesce((p->>'weight')::numeric, 0),
    p->>'link',
    now())
  on conflict (link) do update set
    name = excluded.name,
    nickname = excluded.nickname,
    city_id = excluded.city_id,
    birthday = coalesce(excluded.birthday, f.birthday),
    died = coalesce(excluded.died, f.died),
    height = case when (p->>'height') is null then f.height else excluded.height end,
    weight = case when (p->>'weight') is null then f.weight else excluded.weight end,
    synced_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

-- p: [{name, matchup, date, link, status, location}]. Returns how many rows
-- were inserted or changed.
create function public.mma_upsert_events(p jsonb)
returns integer
language plpgsql
set search_path = ''
as $$
declare
  v_event jsonb;
  v_count integer := 0;
  v_rows integer;
begin
  for v_event in select * from jsonb_array_elements(p) loop
    insert into public.mma_events as e (name, matchup, date, link, status, location_id)
    values (
      v_event->>'name',
      nullif(btrim(v_event->>'matchup'), ''),
      (v_event->>'date')::date,
      v_event->>'link',
      v_event->>'status',
      public.mma_location_id(v_event->>'location'))
    on conflict (link) do update set
      name = excluded.name,
      matchup = excluded.matchup,
      date = excluded.date,
      status = excluded.status,
      location_id = excluded.location_id
    where (e.name, e.matchup, e.date, e.status, e.location_id)
      is distinct from (excluded.name, excluded.matchup, excluded.date, excluded.status, excluded.location_id);
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;
  return v_count;
end;
$$;

-- Replaces an event's card with what Sherdog shows. p_fights:
-- [{position, fighter_one_link, fighter_two_link, category, referee,
--   main_event, title_fight, status, method, decision, round, time_seconds, winner}].
-- A bout is matched by its two fighters (either order). When fighters aren't
-- stored yet nothing is written and their links come back in
-- missing_fighters, so the caller can fetch them and call again.
create function public.mma_sync_event_fights(p_event_link text, p_fights jsonb)
returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_event_id bigint;
  v_fight jsonb;
  v_missing text[];
  v_one bigint;
  v_two bigint;
  v_id bigint;
  v_keep bigint[] := '{}';
  v_skipped integer := 0;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_deleted integer := 0;
  v_rows integer;
begin
  select id into v_event_id from public.mma_events where link = p_event_link;
  if v_event_id is null then
    raise exception 'mma event not found: %', p_event_link;
  end if;

  select array_agg(distinct l) into v_missing
  from (
    select f->>'fighter_one_link' as l from jsonb_array_elements(p_fights) f
    union
    select f->>'fighter_two_link' from jsonb_array_elements(p_fights) f
  ) links
  where l is not null and not exists (select 1 from public.mma_fighters where link = l);
  if v_missing is not null then
    return jsonb_build_object('missing_fighters', to_jsonb(v_missing));
  end if;

  for v_fight in select * from jsonb_array_elements(p_fights) loop
    select id into v_one from public.mma_fighters where link = v_fight->>'fighter_one_link';
    select id into v_two from public.mma_fighters where link = v_fight->>'fighter_two_link';
    if v_one is null or v_two is null or v_one = v_two then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    select id into v_id from public.mma_fights
    where event_id = v_event_id
      and ((fighter_one_id = v_one and fighter_two_id = v_two) or (fighter_one_id = v_two and fighter_two_id = v_one))
    order by id limit 1;

    if v_id is null then
      insert into public.mma_fights (
        event_id, position, category_id, fighter_one_id, fighter_two_id, referee_id,
        main_event, title_fight, status, method, decision, round, time_seconds, winner)
      values (
        v_event_id, (v_fight->>'position')::integer, public.mma_category_id(v_fight->>'category'),
        v_one, v_two, public.mma_referee_id(v_fight->>'referee'),
        coalesce((v_fight->>'main_event')::boolean, false), coalesce((v_fight->>'title_fight')::boolean, false),
        v_fight->>'status', nullif(v_fight->>'method', ''), nullif(v_fight->>'decision', ''),
        (v_fight->>'round')::smallint, (v_fight->>'time_seconds')::integer, (v_fight->>'winner')::smallint)
      returning id into v_id;
      v_inserted := v_inserted + 1;
    else
      update public.mma_fights set
        position = (v_fight->>'position')::integer,
        category_id = public.mma_category_id(v_fight->>'category'),
        fighter_one_id = v_one,
        fighter_two_id = v_two,
        referee_id = public.mma_referee_id(v_fight->>'referee'),
        main_event = coalesce((v_fight->>'main_event')::boolean, false),
        title_fight = coalesce((v_fight->>'title_fight')::boolean, false),
        status = v_fight->>'status',
        method = nullif(v_fight->>'method', ''),
        decision = nullif(v_fight->>'decision', ''),
        round = (v_fight->>'round')::smallint,
        time_seconds = (v_fight->>'time_seconds')::integer,
        winner = (v_fight->>'winner')::smallint
      where id = v_id
        and (position, category_id, fighter_one_id, fighter_two_id, referee_id, main_event, title_fight,
             status, method, decision, round, time_seconds, winner)
          is distinct from (
            (v_fight->>'position')::integer, public.mma_category_id(v_fight->>'category'), v_one, v_two,
            public.mma_referee_id(v_fight->>'referee'), coalesce((v_fight->>'main_event')::boolean, false),
            coalesce((v_fight->>'title_fight')::boolean, false), v_fight->>'status',
            nullif(v_fight->>'method', ''), nullif(v_fight->>'decision', ''), (v_fight->>'round')::smallint,
            (v_fight->>'time_seconds')::integer, (v_fight->>'winner')::smallint);
      get diagnostics v_rows = row_count;
      v_updated := v_updated + v_rows;
    end if;
    v_keep := v_keep || v_id;
  end loop;

  -- Bouts no longer on the card (cancelled) go, but only when every bout on
  -- the page was matched, so a half-parsed page never deletes anything.
  if jsonb_array_length(p_fights) > 0 and v_skipped = 0 then
    delete from public.mma_fights where event_id = v_event_id and not (id = any (v_keep));
    get diagnostics v_deleted = row_count;
  end if;

  update public.mma_events set synced_at = now() where id = v_event_id;
  return jsonb_build_object(
    'inserted', v_inserted, 'updated', v_updated, 'deleted', v_deleted, 'skipped', v_skipped);
end;
$$;

-- What one mma-sync run should refresh: event pages (new ones first, then
-- the ones closest to today) and the fighters checked least recently.
create function public.mma_sync_plan(p_event_limit integer, p_fighter_limit integer)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(link)
      from (
        select e.link
        from public.mma_events e
        where
          -- Never refreshed and no fights stored yet (new events).
          (e.synced_at is null and not exists (select 1 from public.mma_fights f where f.event_id = e.id))
          -- Fight night: results come in during the event.
          or (e.date between current_date - 2 and current_date + 1
              and (e.synced_at is null or e.synced_at < now() - interval '50 minutes'))
          -- Upcoming cards change as bouts are added or cancelled.
          or (e.status = 'upcoming' and (e.synced_at is null or e.synced_at < now() - interval '6 hours'))
          -- Past events still showing unfought bouts, and the last two weeks.
          or ((e.date >= current_date - 14
               or (e.date < current_date
                   and exists (select 1 from public.mma_fights f where f.event_id = e.id and f.status = 'pending')))
              and (e.synced_at is null or e.synced_at < now() - interval '12 hours'))
        order by
          (e.synced_at is null and not exists (select 1 from public.mma_fights f where f.event_id = e.id)) desc,
          abs(e.date - current_date)
        limit p_event_limit
      ) picked), '[]'::jsonb),
    'fighters', coalesce((
      select jsonb_agg(link)
      from (
        select fi.link
        from public.mma_fighters fi
        order by
          exists (
            select 1 from public.mma_fights f join public.mma_events e on e.id = f.event_id
            where e.status = 'upcoming' and fi.id in (f.fighter_one_id, f.fighter_two_id)) desc,
          fi.synced_at nulls first,
          fi.id
        limit p_fighter_limit
      ) picked), '[]'::jsonb))
$$;

revoke all on function public.mma_norm(text) from public, anon, authenticated;
revoke all on function public.mma_country_id(text) from public, anon, authenticated;
revoke all on function public.mma_city_id(text, bigint) from public, anon, authenticated;
revoke all on function public.mma_location_id(text) from public, anon, authenticated;
revoke all on function public.mma_category_id(text) from public, anon, authenticated;
revoke all on function public.mma_referee_id(text) from public, anon, authenticated;
revoke all on function public.mma_upsert_fighter(jsonb) from public, anon, authenticated;
revoke all on function public.mma_upsert_events(jsonb) from public, anon, authenticated;
revoke all on function public.mma_sync_event_fights(text, jsonb) from public, anon, authenticated;
revoke all on function public.mma_sync_plan(integer, integer) from public, anon, authenticated;

grant execute on function public.mma_norm(text) to service_role;
grant execute on function public.mma_country_id(text) to service_role;
grant execute on function public.mma_city_id(text, bigint) to service_role;
grant execute on function public.mma_location_id(text) to service_role;
grant execute on function public.mma_category_id(text) to service_role;
grant execute on function public.mma_referee_id(text) to service_role;
grant execute on function public.mma_upsert_fighter(jsonb) to service_role;
grant execute on function public.mma_upsert_events(jsonb) to service_role;
grant execute on function public.mma_sync_event_fights(text, jsonb) to service_role;
grant execute on function public.mma_sync_plan(integer, integer) to service_role;

-- Hourly run. The function URL and the shared secret live in Vault (set once
-- by hand, see docs/mma/schema.md) so no secret is stored in git; until they
-- exist the job just fails quietly in cron.job_run_details.
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron with schema pg_catalog;

select cron.schedule(
  'mma-sync',
  '17 * * * *',
  $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'mma_sync_url'),
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-sync-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'mma_sync_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 150000)
  $cron$
);
