-- MMA ScoreCard: Browse lists can be sorted by name or by how many events or
-- bouts each item has (p_sort = 'count'). Replaces mma_browse; the old
-- signature is dropped so PostgREST sees one function.

drop function public.mma_browse(text, text, integer, integer);

create function public.mma_browse(
  p_kind text, p_query text default '', p_offset integer default 0, p_limit integer default 100,
  p_sort text default 'name')
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_pattern text := '%' || replace(replace(replace(btrim(coalesce(p_query, '')), '\', '\\'), '%', '\%'), '_', '\_') || '%';
  v_limit integer := greatest(1, least(coalesce(p_limit, 100), 200));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  -- 'count': most events or bouts first (ties by name); otherwise by name.
  v_by_count boolean := p_sort = 'count';
  v_rows jsonb;
begin
  if p_kind = 'countries' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', null, 'count', n) order by case when v_by_count then -n else 0 end, name, id) into v_rows
    from (
      select co.id, co.name, count(distinct e.id) as n
      from public.mma_countries co
      join public.mma_cities c on c.country_id = co.id
      join public.mma_locations l on l.city_id = c.id
      join public.mma_events e on e.location_id = l.id
      where co.name ilike v_pattern
      group by co.id, co.name
      order by case when v_by_count then -count(distinct e.id) else 0 end, co.name, co.id offset v_offset limit v_limit) x;
  elsif p_kind = 'cities' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', country, 'count', n) order by case when v_by_count then -n else 0 end, name, id) into v_rows
    from (
      select c.id, coalesce(c.name, '—') as name, co.name as country, count(distinct e.id) as n
      from public.mma_cities c
      join public.mma_countries co on co.id = c.country_id
      join public.mma_locations l on l.city_id = c.id
      join public.mma_events e on e.location_id = l.id
      where c.name ilike v_pattern or co.name ilike v_pattern
      group by c.id, c.name, co.name
      order by case when v_by_count then -count(distinct e.id) else 0 end, coalesce(c.name, '—'), c.id offset v_offset limit v_limit) x;
  elsif p_kind = 'locations' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', place, 'count', n) order by case when v_by_count then -n else 0 end, name, id) into v_rows
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
      order by case when v_by_count then -count(e.id) else 0 end, 2, l.id offset v_offset limit v_limit) x;
  elsif p_kind = 'fighters' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', nickname, 'count', n, 'link', link)
                     order by case when v_by_count then -n else 0 end, name, id) into v_rows
    from (
      select f.id, f.name, f.nickname, f.link, count(x.id) as n
      from public.mma_fighters f
      join public.mma_fights x on f.id in (x.fighter_one_id, x.fighter_two_id)
      where f.sherdog_id is not null and (f.name ilike v_pattern or f.nickname ilike v_pattern)
      group by f.id, f.name, f.nickname, f.link
      order by case when v_by_count then -count(x.id) else 0 end, f.name, f.id offset v_offset limit v_limit) y;
  elsif p_kind = 'referees' then
    select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'subtitle', null, 'count', n) order by case when v_by_count then -n else 0 end, name, id) into v_rows
    from (
      select r.id, r.name, count(x.id) as n
      from public.mma_referees r
      join public.mma_fights x on x.referee_id = r.id
      where r.name ilike v_pattern
      group by r.id, r.name
      order by case when v_by_count then -count(x.id) else 0 end, r.name, r.id offset v_offset limit v_limit) y;
  else
    raise exception 'unknown browse kind: %', p_kind;
  end if;
  return coalesce(v_rows, '[]'::jsonb);
end;
$$;

revoke all on function public.mma_browse(text, text, integer, integer, text) from public;
grant execute on function public.mma_browse(text, text, integer, integer, text) to anon, authenticated, service_role;
