-- TasteTO database schema
-- Target: Supabase (PostgreSQL 15+ with PostGIS). Runs on any Postgres that has
-- an `auth` schema with auth.users and auth.uid(), which Supabase provides.
--
-- Run order: schema.sql, then storage.sql (Supabase only), then seed.sql.

create extension if not exists postgis;
create extension if not exists pg_trgm;   -- fuzzy matching of restaurant names read by the AI
create extension if not exists citext;    -- case-insensitive usernames

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type visibility        as enum ('private', 'friends', 'public');
create type friendship_status as enum ('pending', 'accepted', 'blocked');
create type place_source      as enum ('seed', 'user', 'osm', 'google');
create type list_kind         as enum ('date_night', 'want_to_try', 'custom');
create type booking_status    as enum ('requested', 'confirmed', 'cancelled');

-- ---------------------------------------------------------------------------
-- Shared helpers
-- ---------------------------------------------------------------------------
create or replace function set_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- People
-- ---------------------------------------------------------------------------
create table profiles (
  id                 uuid primary key references auth.users (id) on delete cascade,
  username           citext unique check (username ~ '^[a-z0-9_]{3,24}$'),
  display_name       text not null default '',
  avatar_path        text,                                  -- storage path, not a URL
  home_location      geography(point, 4326),                -- the "H" pin; fog starts here
  default_visibility visibility not null default 'friends', -- used when logging a visit
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create trigger profiles_updated before update on profiles
  for each row execute function set_updated_at();

-- Create a profile row whenever someone signs up.
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', ''));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function handle_new_user();

create table friendships (
  requester_id uuid not null references profiles (id) on delete cascade,
  addressee_id uuid not null references profiles (id) on delete cascade,
  status       friendship_status not null default 'pending',
  created_at   timestamptz not null default now(),
  responded_at timestamptz,
  primary key (requester_id, addressee_id),
  check (requester_id <> addressee_id)
);
-- One friendship per pair, whichever direction it was requested in.
create unique index friendships_pair_uq
  on friendships (least(requester_id, addressee_id), greatest(requester_id, addressee_id));
create index friendships_addressee_idx on friendships (addressee_id);

-- security definer so RLS policies can call it without recursing into friendships' own RLS.
create or replace function are_friends(a uuid, b uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester_id = a and addressee_id = b) or (requester_id = b and addressee_id = a))
  );
$$;

-- ---------------------------------------------------------------------------
-- Places: one shared catalog of restaurants, cafes and bars
-- ---------------------------------------------------------------------------
create table places (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(trim(name)) > 0),
  category    text,                          -- "Thai", "Wine bar"
  area        text,                          -- "King West"
  address     text,
  location    geography(point, 4326) not null,
  source      place_source not null default 'user',
  external_id text,                          -- OSM / Google id, or the prototype's id ("khao")
  created_by  uuid references profiles (id) on delete set null,
  -- Date-night details shown on the Date night tab
  is_date_spot boolean not null default false,
  vibes        text[] not null default '{}',
  noise_level  smallint check (noise_level between 1 and 3),  -- 1 quiet, 2 lively, 3 loud
  tip          text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (source, external_id)
);
create index places_location_gix on places using gist (location);
create index places_name_trgm on places using gin (name gin_trgm_ops);
create trigger places_updated before update on places
  for each row execute function set_updated_at();

-- ---------------------------------------------------------------------------
-- Visits: one row per meal logged
-- ---------------------------------------------------------------------------
create table visits (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references profiles (id) on delete cascade,
  place_id    uuid not null references places (id) on delete restrict,
  dish        text not null check (length(trim(dish)) > 0),
  rating      smallint not null check (rating between 1 and 10),
  review      text,
  visited_at  timestamptz not null default now(),
  visibility  visibility not null default 'friends',
  -- Where the photo was taken (from the snap flow), kept separate from the place's own pin
  captured_at_location geography(point, 4326),
  -- What the AI suggested, kept so you can measure how often people accept or correct it
  ai_dish       text,
  ai_cuisine    text,
  ai_restaurant text,
  ai_model      text,
  ai_raw        jsonb,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index visits_user_time_idx  on visits (user_id, visited_at desc);
create index visits_place_idx      on visits (place_id);
create index visits_public_time_idx on visits (visited_at desc) where visibility <> 'private';
create trigger visits_updated before update on visits
  for each row execute function set_updated_at();

create table visit_photos (
  id           uuid primary key default gen_random_uuid(),
  visit_id     uuid not null references visits (id) on delete cascade,
  storage_path text not null,               -- "<user_id>/<visit_id>/<n>.jpg" in the visit-photos bucket
  position     smallint not null default 0 check (position between 0 and 9),  -- up to 10 per visit; 0 is the cover
  width        integer,
  height       integer,
  created_at   timestamptz not null default now(),
  unique (visit_id, position)
);

-- ---------------------------------------------------------------------------
-- Lists ("Date night with Sarah") and bookings
-- ---------------------------------------------------------------------------
create table lists (
  id         uuid primary key default gen_random_uuid(),
  owner_id   uuid not null default auth.uid() references profiles (id) on delete cascade,
  name       text not null,
  kind       list_kind not null default 'custom',
  created_at timestamptz not null default now()
);
create index lists_owner_idx on lists (owner_id);

-- People a list is shared with (e.g. your partner), who can add and edit items.
create table list_members (
  list_id  uuid not null references lists (id) on delete cascade,
  user_id  uuid not null references profiles (id) on delete cascade,
  added_at timestamptz not null default now(),
  primary key (list_id, user_id)
);
create index list_members_user_idx on list_members (user_id);

create or replace function can_use_list(l uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lists where id = l and owner_id = auth.uid())
      or exists (select 1 from list_members where list_id = l and user_id = auth.uid());
$$;

create table list_items (
  list_id  uuid not null references lists (id) on delete cascade,
  place_id uuid not null references places (id) on delete cascade,
  note     text,                       -- "Book the corner booth. Go after 8."
  planned  boolean not null default false,
  added_by uuid default auth.uid() references profiles (id) on delete set null,
  added_at timestamptz not null default now(),
  primary key (list_id, place_id)
);

create table bookings (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references profiles (id) on delete cascade,
  place_id   uuid not null references places (id) on delete restrict,
  list_id    uuid references lists (id) on delete set null,
  party_size smallint not null check (party_size between 1 and 20),
  starts_at  timestamptz not null,
  status     booking_status not null default 'requested',
  notes      text,
  created_at timestamptz not null default now()
);
create index bookings_user_time_idx on bookings (user_id, starts_at);

-- ---------------------------------------------------------------------------
-- Views (security_invoker: they respect the caller's row-level security)
-- ---------------------------------------------------------------------------

-- Ratings per place across every visit the caller is allowed to see.
create view place_stats with (security_invoker = true) as
select p.id as place_id,
       count(v.id)                    as visit_count,
       round(avg(v.rating), 1)        as avg_rating,
       count(distinct v.user_id)      as visitor_count,
       max(v.visited_at)              as last_visited_at
from places p
left join visits v on v.place_id = p.id
group by p.id;

-- The caller's own stats per place (the "Your avg 9.0/10 · 1 visit" pop-up line).
create view my_place_stats with (security_invoker = true) as
select v.place_id,
       count(*)                 as visit_count,
       round(avg(v.rating), 1)  as avg_rating,
       max(v.visited_at)        as last_visited_at,
       bool_or(v.rating <= 3)   as has_skip   -- "Skip next time"
from visits v
where v.user_id = auth.uid()
group by v.place_id;

-- Friends tab: recent visits by friends, newest first.
create view friend_feed with (security_invoker = true) as
select v.id as visit_id, v.user_id, pr.display_name, pr.username,
       v.place_id, p.name as place_name, p.area,
       v.dish, v.rating, v.review, v.visited_at,
       (select storage_path from visit_photos ph where ph.visit_id = v.id order by position limit 1) as cover_photo
from visits v
join profiles pr on pr.id = v.user_id
join places p   on p.id = v.place_id
where v.user_id <> auth.uid()
  and are_friends(auth.uid(), v.user_id)
  and v.visibility in ('friends', 'public');

-- ---------------------------------------------------------------------------
-- Functions the app calls
-- ---------------------------------------------------------------------------

-- Snap flow: places near where the photo was taken, optionally ranked by how
-- closely their name matches the restaurant name the AI read from the photo.
create or replace function find_places(
  lat double precision,
  lng double precision,
  radius_m double precision default 150,
  name_hint text default null,
  max_results int default 10
) returns table (
  id uuid, name text, category text, area text,
  distance_m double precision, name_similarity real
)
language sql stable as $$
  with here as (select st_setsrid(st_makepoint(lng, lat), 4326)::geography as g)
  select p.id, p.name, p.category, p.area,
         st_distance(p.location, here.g) as distance_m,
         case when name_hint is null then null else similarity(p.name, name_hint) end as name_similarity
  from places p, here
  where st_dwithin(p.location, here.g, radius_m)
     or (name_hint is not null
         and st_dwithin(p.location, here.g, 2000)   -- a name match only counts within 2 km
         and p.name % name_hint)
  order by (case when name_hint is not null and p.name % name_hint then 0 else 1 end),
           st_distance(p.location, here.g)
  limit max_results;
$$;

-- Map fog: the points that are "cleared" for the caller (home plus every logged place).
create or replace function my_cleared_points()
returns table (lat double precision, lng double precision)
language sql stable as $$
  select st_y(home_location::geometry), st_x(home_location::geometry)
  from profiles where id = auth.uid() and home_location is not null
  union
  select st_y(p.location::geometry), st_x(p.location::geometry)
  from places p
  where exists (select 1 from visits v where v.place_id = p.id and v.user_id = auth.uid());
$$;

-- Bring in the prototype's "Raw data (JSON)" export (the last pages of the PDF)
-- for the signed-in user. Safe to run twice: places are matched by their
-- prototype id, then by name within 100 m, and visits that already exist are skipped.
create or replace function import_prototype_export(payload jsonb)
returns jsonb
language plpgsql as $$
declare
  me        uuid := auth.uid();
  yr        int  := coalesce(extract(year from (payload ->> 'exportedAt')::timestamptz), extract(year from now()))::int;
  pl        jsonb;
  vi        jsonb;
  pid       uuid;
  idmap     jsonb := '{}';
  dn_list   uuid;
  n_places  int := 0;
  n_visits  int := 0;
  vdate     timestamptz;
begin
  if me is null then
    raise exception 'Sign in before importing';
  end if;

  for pl in select * from jsonb_array_elements(coalesce(payload -> 'places', '[]')) loop
    if pl ->> 'lat' is null or pl ->> 'lng' is null then
      continue;
    end if;
    select id into pid from places
     where external_id = pl ->> 'id' and source in ('seed', 'user');
    if pid is null then
      select id into pid from places
       where lower(name) = lower(pl ->> 'name')
         and st_dwithin(location, st_setsrid(st_makepoint((pl ->> 'lng')::float8, (pl ->> 'lat')::float8), 4326)::geography, 100)
       limit 1;
    end if;
    if pid is null then
      insert into places (name, category, area, location, source, external_id, created_by,
                          is_date_spot, vibes, noise_level, tip)
      values (pl ->> 'name', pl ->> 'cat', pl ->> 'area',
              st_setsrid(st_makepoint((pl ->> 'lng')::float8, (pl ->> 'lat')::float8), 4326)::geography,
              'user', pl ->> 'id', me,
              coalesce((pl ->> 'date')::boolean, false),
              coalesce(array(select jsonb_array_elements_text(pl -> 'vibe')), '{}'),
              (pl ->> 'noise')::smallint, pl ->> 'note')
      returning id into pid;
      n_places := n_places + 1;
    end if;
    idmap := idmap || jsonb_build_object(pl ->> 'id', pid);
  end loop;

  for vi in select * from jsonb_array_elements(coalesce(payload -> 'visits', '[]')) loop
    pid := (idmap ->> (vi ->> 'spot'))::uuid;
    if pid is null then
      continue;   -- visit for a place that wasn't in the export
    end if;
    -- The prototype stores dates like "Nov 5" with no year.
    begin
      vdate := to_date((vi ->> 'date') || ' ' || yr, 'Mon DD YYYY');
    exception when others then
      vdate := now();
    end;
    if not exists (select 1 from visits where user_id = me and place_id = pid
                     and dish = vi ->> 'dish' and visited_at::date = vdate::date) then
      insert into visits (user_id, place_id, dish, rating, review, visited_at, visibility)
      values (me, pid, vi ->> 'dish', (vi ->> 'rating')::smallint, nullif(vi ->> 'review', ''), vdate,
              (select default_visibility from profiles where id = me));
      n_visits := n_visits + 1;
    end if;
  end loop;

  -- Date night: saved places, plans and notes go into one list.
  if jsonb_array_length(coalesce(payload #> '{dateNight,saved}', '[]')) > 0
     or jsonb_array_length(coalesce(payload #> '{dateNight,planned}', '[]')) > 0
     or coalesce(payload #> '{dateNight,notes}', '{}') <> '{}' then
    select id into dn_list from lists where owner_id = me and kind = 'date_night' order by created_at limit 1;
    if dn_list is null then
      insert into lists (owner_id, name, kind) values (me, 'Date night', 'date_night') returning id into dn_list;
    end if;
    insert into list_items (list_id, place_id, note, planned)
    select dn_list, (idmap ->> k)::uuid,
           payload #>> array['dateNight', 'notes', k],
           coalesce(payload #> '{dateNight,planned}', '[]') ? k
    from (select jsonb_array_elements_text(coalesce(payload #> '{dateNight,saved}', '[]')) as k
          union
          select jsonb_array_elements_text(coalesce(payload #> '{dateNight,planned}', '[]'))
          union
          select jsonb_object_keys(coalesce(payload #> '{dateNight,notes}', '{}'))) keys
    where idmap ? k
    on conflict (list_id, place_id) do update
      set note = coalesce(excluded.note, list_items.note), planned = excluded.planned;
  end if;

  return jsonb_build_object('places_added', n_places, 'visits_added', n_visits, 'date_night_list', dn_list);
end $$;

-- ---------------------------------------------------------------------------
-- Row-level security
-- ---------------------------------------------------------------------------
alter table profiles     enable row level security;
alter table friendships  enable row level security;
alter table places       enable row level security;
alter table visits       enable row level security;
alter table visit_photos enable row level security;
alter table lists        enable row level security;
alter table list_members enable row level security;
alter table list_items   enable row level security;
alter table bookings     enable row level security;

-- Profiles: any signed-in user can look people up (to add friends); you edit only your own.
create policy profiles_read   on profiles for select to authenticated using (true);
create policy profiles_update on profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- Friendships: you see requests you're part of; you send as yourself;
-- only the person asked can accept or block; either side can remove it.
create policy friendships_read on friendships for select to authenticated
  using (auth.uid() in (requester_id, addressee_id));
create policy friendships_request on friendships for insert to authenticated
  with check (requester_id = auth.uid() and status = 'pending');
create policy friendships_respond on friendships for update to authenticated
  using (addressee_id = auth.uid()) with check (addressee_id = auth.uid());
create policy friendships_remove on friendships for delete to authenticated
  using (auth.uid() in (requester_id, addressee_id));

-- Places: a shared catalog everyone reads; you can add places and edit the ones you added.
create policy places_read   on places for select to authenticated using (true);
create policy places_insert on places for insert to authenticated
  with check (created_by = auth.uid() and source = 'user');
create policy places_update on places for update to authenticated
  using (created_by = auth.uid()) with check (created_by = auth.uid());
create policy places_delete on places for delete to authenticated
  using (created_by = auth.uid());

-- Visits: yours, plus friends' visits shared with friends, plus anything public.
create policy visits_read on visits for select to authenticated
  using (user_id = auth.uid()
         or visibility = 'public'
         or (visibility = 'friends' and are_friends(auth.uid(), user_id)));
create policy visits_insert on visits for insert to authenticated with check (user_id = auth.uid());
create policy visits_update on visits for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy visits_delete on visits for delete to authenticated using (user_id = auth.uid());

-- Photos follow their visit.
create policy visit_photos_read on visit_photos for select to authenticated
  using (exists (select 1 from visits v where v.id = visit_id));   -- visits RLS applies inside
create policy visit_photos_write on visit_photos for all to authenticated
  using (exists (select 1 from visits v where v.id = visit_id and v.user_id = auth.uid()))
  with check (exists (select 1 from visits v where v.id = visit_id and v.user_id = auth.uid()));

-- Lists: the owner and members can see and edit items; only the owner renames,
-- deletes or shares the list.
-- owner_id is checked directly so a new list can be read back in the same insert (insert ... returning).
create policy lists_read   on lists for select to authenticated using (owner_id = auth.uid() or can_use_list(id));
create policy lists_insert on lists for insert to authenticated with check (owner_id = auth.uid());
create policy lists_update on lists for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy lists_delete on lists for delete to authenticated using (owner_id = auth.uid());

create policy list_members_read on list_members for select to authenticated using (can_use_list(list_id));
create policy list_members_manage on list_members for all to authenticated
  using (exists (select 1 from lists l where l.id = list_id and l.owner_id = auth.uid()))
  with check (exists (select 1 from lists l where l.id = list_id and l.owner_id = auth.uid())
              and are_friends(auth.uid(), user_id));   -- share only with friends

create policy list_items_all on list_items for all to authenticated
  using (can_use_list(list_id)) with check (can_use_list(list_id));

-- Bookings are private to the person who made them.
create policy bookings_own on bookings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Supabase grants table access to the `authenticated` role by default; on plain
-- Postgres these grants make the policies above the only gate.
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on all functions in schema public to authenticated;
