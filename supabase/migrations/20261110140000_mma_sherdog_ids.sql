-- MMA ScoreCard: match events and fighters by Sherdog's numeric id.
--
-- Sherdog renames page addresses but keeps the trailing number: a placeholder
-- "UFC-Fight-Night-London-110783" becomes "UFC-Fight-Night-270-Evloev-vs-Murphy-110783",
-- and "Charlie-Radtke-175669" becomes "Charles-Radtke-175669". Matching on the
-- full link added those as new rows, so rows are now keyed by that number,
-- duplicates are merged into the oldest row, and syncing updates the link.

create function public.mma_sherdog_id(p_link text)
returns bigint
language sql
immutable
set search_path = ''
as $$
  select substring(p_link from '-(\d+)$')::bigint
$$;

alter table public.mma_events
  add column sherdog_id bigint generated always as (public.mma_sherdog_id(link)) stored;
alter table public.mma_fighters
  add column sherdog_id bigint generated always as (public.mma_sherdog_id(link)) stored;

comment on column public.mma_events.sherdog_id is 'Number at the end of the Sherdog link; stable when the address is renamed';
comment on column public.mma_fighters.sherdog_id is 'Number at the end of the Sherdog link; null for placeholders such as "Unknown Fighter"';

-- Merge duplicate fighters into the oldest row.
update public.mma_fights x set fighter_one_id = k.keep_id
from public.mma_fighters f
join (select sherdog_id, min(id) as keep_id from public.mma_fighters
      where sherdog_id is not null group by sherdog_id having count(*) > 1) k on k.sherdog_id = f.sherdog_id
where x.fighter_one_id = f.id and f.id <> k.keep_id;

update public.mma_fights x set fighter_two_id = k.keep_id
from public.mma_fighters f
join (select sherdog_id, min(id) as keep_id from public.mma_fighters
      where sherdog_id is not null group by sherdog_id having count(*) > 1) k on k.sherdog_id = f.sherdog_id
where x.fighter_two_id = f.id and f.id <> k.keep_id;

delete from public.mma_fighters f
using (select sherdog_id, min(id) as keep_id from public.mma_fighters
       where sherdog_id is not null group by sherdog_id having count(*) > 1) k
where f.sherdog_id = k.sherdog_id and f.id <> k.keep_id;

-- Merge duplicate events into the oldest row; the newer row's card moves
-- over when the oldest has none, and the oldest is refreshed next run so it
-- picks up Sherdog's current name and link.
update public.mma_fights x set event_id = k.keep_id
from public.mma_events e
join (select sherdog_id, min(id) as keep_id from public.mma_events
      where sherdog_id is not null group by sherdog_id having count(*) > 1) k on k.sherdog_id = e.sherdog_id
where x.event_id = e.id and e.id <> k.keep_id
  and not exists (select 1 from public.mma_fights y where y.event_id = k.keep_id);

update public.mma_events e set synced_at = null
from (select sherdog_id, min(id) as keep_id from public.mma_events
      where sherdog_id is not null group by sherdog_id having count(*) > 1) k
where e.id = k.keep_id;

delete from public.mma_events e
using (select sherdog_id, min(id) as keep_id from public.mma_events
       where sherdog_id is not null group by sherdog_id having count(*) > 1) k
where e.sherdog_id = k.sherdog_id and e.id <> k.keep_id;

alter table public.mma_events add constraint mma_events_sherdog_id_unique unique (sherdog_id);
alter table public.mma_fighters add constraint mma_fighters_sherdog_id_unique unique (sherdog_id);

-- Fighter id for a Sherdog link: by number, or by the exact link for placeholders.
create function public.mma_fighter_id(p_link text)
returns bigint
language sql
stable
set search_path = ''
as $$
  select id from public.mma_fighters
  where (public.mma_sherdog_id(p_link) is not null and sherdog_id = public.mma_sherdog_id(p_link))
     or (public.mma_sherdog_id(p_link) is null and link = p_link)
  order by id limit 1
$$;

create or replace function public.mma_upsert_fighter(p jsonb)
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
  on conflict (sherdog_id) do update set
    name = excluded.name,
    nickname = excluded.nickname,
    city_id = excluded.city_id,
    birthday = coalesce(excluded.birthday, f.birthday),
    died = coalesce(excluded.died, f.died),
    height = case when (p->>'height') is null then f.height else excluded.height end,
    weight = case when (p->>'weight') is null then f.weight else excluded.weight end,
    link = excluded.link,
    synced_at = now()
  returning id into v_id;
  return v_id;
end;
$$;

create or replace function public.mma_upsert_events(p jsonb)
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
    on conflict (sherdog_id) do update set
      name = excluded.name,
      matchup = excluded.matchup,
      date = excluded.date,
      link = excluded.link,
      status = excluded.status,
      location_id = excluded.location_id
    where (e.name, e.matchup, e.date, e.link, e.status, e.location_id)
      is distinct from (excluded.name, excluded.matchup, excluded.date, excluded.link, excluded.status, excluded.location_id);
    get diagnostics v_rows = row_count;
    v_count := v_count + v_rows;
  end loop;
  return v_count;
end;
$$;

create or replace function public.mma_sync_event_fights(p_event_link text, p_fights jsonb)
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
  select id into v_event_id from public.mma_events
  where sherdog_id = public.mma_sherdog_id(p_event_link) or link = p_event_link
  order by id limit 1;
  if v_event_id is null then
    raise exception 'mma event not found: %', p_event_link;
  end if;

  select array_agg(distinct l) into v_missing
  from (
    select f->>'fighter_one_link' as l from jsonb_array_elements(p_fights) f
    union
    select f->>'fighter_two_link' from jsonb_array_elements(p_fights) f
  ) links
  where l is not null and public.mma_fighter_id(l) is null;
  if v_missing is not null then
    return jsonb_build_object('missing_fighters', to_jsonb(v_missing));
  end if;

  for v_fight in select * from jsonb_array_elements(p_fights) loop
    v_one := public.mma_fighter_id(v_fight->>'fighter_one_link');
    v_two := public.mma_fighter_id(v_fight->>'fighter_two_link');
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

  if jsonb_array_length(p_fights) > 0 and v_skipped = 0 then
    delete from public.mma_fights where event_id = v_event_id and not (id = any (v_keep));
    get diagnostics v_deleted = row_count;
  end if;

  update public.mma_events set synced_at = now() where id = v_event_id;
  return jsonb_build_object(
    'inserted', v_inserted, 'updated', v_updated, 'deleted', v_deleted, 'skipped', v_skipped);
end;
$$;

revoke all on function public.mma_sherdog_id(text) from public, anon, authenticated;
revoke all on function public.mma_fighter_id(text) from public, anon, authenticated;
grant execute on function public.mma_sherdog_id(text) to service_role;
grant execute on function public.mma_fighter_id(text) to service_role;
