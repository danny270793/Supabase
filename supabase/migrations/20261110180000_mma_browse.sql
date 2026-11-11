-- MMA ScoreCard: the Browse tab.
--
-- mma_browse lists countries, cities and locations that hosted events (with
-- how many) and fighters and referees with fights (with how many),
-- alphabetically, filtered by name and paged. mma_browse_events and
-- mma_browse_fights return what one of them was involved in, in the shapes the
-- app already reads (events with their location; bouts with both fighters,
-- weight class, referee and their event). Read-only, so the app may call them.

-- An event as the app reads it from mma_events.
create function public.mma_event_json(p_event_id bigint)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select jsonb_build_object(
    'name', e.name, 'matchup', e.matchup, 'date', e.date, 'link', e.link, 'status', e.status,
    'sherdog_id', e.sherdog_id,
    'location', jsonb_build_object(
      'name', l.name,
      'city', jsonb_build_object('name', c.name, 'country', jsonb_build_object('name', co.name))))
  from public.mma_events e
  join public.mma_locations l on l.id = e.location_id
  join public.mma_cities c on c.id = l.city_id
  join public.mma_countries co on co.id = c.country_id
  where e.id = p_event_id
$$;

create function public.mma_browse(
  p_kind text, p_query text default '', p_offset integer default 0, p_limit integer default 100)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pattern text := '%' || replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_rows jsonb;
begin
  if p_kind = 'countries' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', null, 'count', n) order by name, id) into v_rows
    from (
      select co.id, co.name, count(distinct e.id) as n
      from public.mma_countries co
      join public.mma_cities c on c.country_id = co.id
      join public.mma_locations l on l.city_id = c.id
      join public.mma_events e on e.location_id = l.id
      where co.name ilike v_pattern
      group by co.id, co.name
      order by co.name, co.id offset v_offset limit v_limit) x;
  elsif p_kind = 'cities' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', country, 'count', n) order by name, id) into v_rows
    from (
      select c.id, coalesce(c.name, '—') as name, co.name as country, count(distinct e.id) as n
      from public.mma_cities c
      join public.mma_countries co on co.id = c.country_id
      join public.mma_locations l on l.city_id = c.id
      join public.mma_events e on e.location_id = l.id
      where c.name ilike v_pattern or co.name ilike v_pattern
      group by c.id, c.name, co.name
      order by coalesce(c.name, '—'), c.id offset v_offset limit v_limit) x;
  elsif p_kind = 'locations' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', place, 'count', n) order by name, id) into v_rows
    from (
      select l.id,
             coalesce(nullif(regexp_replace(btrim(l.name), '\s+', ' ', 'g'), ''), c.name, '—') as name,
             concat_ws(', ', c.name, co.name) as place,
             count(e.id) as n
      from public.mma_locations l
      join public.mma_cities c on c.id = l.city_id
      join public.mma_countries co on co.id = c.country_id
      join public.mma_events e on e.location_id = l.id
      where l.name ilike v_pattern or c.name ilike v_pattern or co.name ilike v_pattern
      group by l.id, l.name, c.name, co.name
      order by 2, l.id offset v_offset limit v_limit) x;
  elsif p_kind = 'fighters' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', nickname, 'count', n, 'link', link)
                     order by name, id) into v_rows
    from (
      select f.id, f.name, f.nickname, f.link, count(x.id) as n
      from public.mma_fighters f
      join public.mma_fights x on f.id in (x.fighter_one_id, x.fighter_two_id)
      where f.sherdog_id is not null and (f.name ilike v_pattern or f.nickname ilike v_pattern)
      group by f.id, f.name, f.nickname, f.link
      order by f.name, f.id offset v_offset limit v_limit) y;
  elsif p_kind = 'referees' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', null, 'count', n) order by name, id) into v_rows
    from (
      select r.id, r.name, count(x.id) as n
      from public.mma_referees r
      join public.mma_fights x on x.referee_id = r.id
      where r.name ilike v_pattern
      group by r.id, r.name
      order by r.name, r.id offset v_offset limit v_limit) y;
  else
    raise exception 'unknown browse kind: %', p_kind;
  end if;
  return coalesce(v_rows, '[]'::jsonb);
end;
$$;

-- Events held in a country, city or location, newest first.
create function public.mma_browse_events(
  p_kind text, p_id bigint, p_offset integer default 0, p_limit integer default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(public.mma_event_json(id) order by date desc, id desc), '[]'::jsonb)
  from (
    select e.id, e.date
    from public.mma_events e
    join public.mma_locations l on l.id = e.location_id
    join public.mma_cities c on c.id = l.city_id
    where (p_kind = 'locations' and l.id = p_id)
       or (p_kind = 'cities' and c.id = p_id)
       or (p_kind = 'countries' and c.country_id = p_id)
    order by e.date desc, e.id desc
    offset greatest(0, coalesce(p_offset, 0)) limit greatest(1, least(coalesce(p_limit, 100), 200))
  ) picked
$$;

-- Bouts of a fighter or a referee, newest first, each with its event.
create function public.mma_browse_fights(
  p_kind text, p_id bigint, p_offset integer default 0, p_limit integer default 100)
returns jsonb
language sql
stable
set search_path = ''
as $$
  select coalesce(jsonb_agg(row order by date desc, position desc, id), '[]'::jsonb)
  from (
    select x.id, e.date, x.position, jsonb_build_object(
      'event', public.mma_event_json(e.id),
      'fight', jsonb_build_object(
        'position', x.position, 'main_event', x.main_event, 'title_fight', x.title_fight, 'status', x.status,
        'method', x.method, 'decision', x.decision, 'round', x.round, 'time_seconds', x.time_seconds,
        'winner', x.winner,
        'one', jsonb_build_object('name', f1.name, 'link', f1.link),
        'two', jsonb_build_object('name', f2.name, 'link', f2.link),
        'category', case when cat.id is null then null else jsonb_build_object('name', cat.name) end,
        'referee', case when r.id is null then null else jsonb_build_object('name', r.name) end)) as row
    from public.mma_fights x
    join public.mma_events e on e.id = x.event_id
    join public.mma_fighters f1 on f1.id = x.fighter_one_id
    join public.mma_fighters f2 on f2.id = x.fighter_two_id
    left join public.mma_categories cat on cat.id = x.category_id
    left join public.mma_referees r on r.id = x.referee_id
    where (p_kind = 'fighters' and p_id in (x.fighter_one_id, x.fighter_two_id))
       or (p_kind = 'referees' and x.referee_id = p_id)
    order by e.date desc, x.position desc, x.id
    offset greatest(0, coalesce(p_offset, 0)) limit greatest(1, least(coalesce(p_limit, 100), 200))
  ) picked
$$;

revoke all on function public.mma_event_json(bigint) from public;
revoke all on function public.mma_browse(text, text, integer, integer) from public;
revoke all on function public.mma_browse_events(text, bigint, integer, integer) from public;
revoke all on function public.mma_browse_fights(text, bigint, integer, integer) from public;
grant execute on function public.mma_event_json(bigint) to anon, authenticated, service_role;
grant execute on function public.mma_browse(text, text, integer, integer) to anon, authenticated, service_role;
grant execute on function public.mma_browse_events(text, bigint, integer, integer) to anon, authenticated, service_role;
grant execute on function public.mma_browse_fights(text, bigint, integer, integer) to anon, authenticated, service_role;
