-- MMA ScoreCard: server-side search for the app's search tab.
--
-- Matches events by name, headline, venue, city or country and fighters by
-- name or nickname (case-insensitive, any part of the text). Events come back
-- in the same shape the app reads from mma_events (location nested with its
-- city and country), newest first. Read-only, so the app may call it.

create function public.mma_search(p_query text, p_limit integer default 50)
returns jsonb
language sql
stable
set search_path = ''
as $$
  with q as (
    select '%' || replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%' as pattern,
           btrim(coalesce(p_query, '')) <> '' as present
  )
  select jsonb_build_object(
    'events', coalesce((
      select jsonb_agg(row order by date desc, id desc)
      from (
        select e.id, e.date, jsonb_build_object(
          'name', e.name, 'matchup', e.matchup, 'date', e.date, 'link', e.link, 'status', e.status,
          'sherdog_id', e.sherdog_id,
          'location', jsonb_build_object(
            'name', l.name,
            'city', jsonb_build_object('name', c.name, 'country', jsonb_build_object('name', co.name)))) as row
        from public.mma_events e
        join public.mma_locations l on l.id = e.location_id
        join public.mma_cities c on c.id = l.city_id
        join public.mma_countries co on co.id = c.country_id, q
        where q.present
          and (e.name ilike q.pattern or e.matchup ilike q.pattern or l.name ilike q.pattern
               or c.name ilike q.pattern or co.name ilike q.pattern)
        order by e.date desc, e.id desc
        limit greatest(1, least(p_limit, 100))
      ) matched), '[]'::jsonb),
    'fighters', coalesce((
      select jsonb_agg(jsonb_build_object('name', name, 'nickname', nickname, 'link', link) order by name)
      from (
        select f.name, f.nickname, f.link
        from public.mma_fighters f, q
        where q.present and f.sherdog_id is not null and (f.name ilike q.pattern or f.nickname ilike q.pattern)
        order by f.name
        limit greatest(1, least(p_limit, 100))
      ) matched), '[]'::jsonb))
$$;

revoke all on function public.mma_search(text, integer) from public;
grant execute on function public.mma_search(text, integer) to anon, authenticated, service_role;
