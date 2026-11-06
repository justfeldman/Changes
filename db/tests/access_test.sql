-- Access-control and function tests: three users (Me, Dev = friend, Stranger).
-- Run on a scratch database after auth_stub.sql, schema.sql and seed.sql. See db/README.md.
\set ON_ERROR_STOP 1
\pset footer off
\pset format unaligned
\pset tuples_only on
insert into auth.users (id, raw_user_meta_data) values
 ('aaaaaaaa-0000-0000-0000-000000000001','{"display_name":"Me"}'),
 ('bbbbbbbb-0000-0000-0000-000000000002','{"display_name":"Dev"}'),
 ('cccccccc-0000-0000-0000-000000000003','{"display_name":"Stranger"}');
\set A 'aaaaaaaa-0000-0000-0000-000000000001'
\set B 'bbbbbbbb-0000-0000-0000-000000000002'
\set C 'cccccccc-0000-0000-0000-000000000003'
select 'profiles auto-created: '||count(*) from profiles;
set role authenticated;

-- Me logs two visits: one for friends, one private
select set_config('request.jwt.claim.sub', :'A', false);
insert into visits (place_id, dish, rating, review, visibility) select id,'Khao soi',9,'Great','friends' from places where external_id='khao';
insert into visits (place_id, dish, rating, visibility) select id,'Salmon bowl',2,'private' from places where external_id='salus';
-- Dev sends a friend request, Me accepts
select set_config('request.jwt.claim.sub', :'B', false);
insert into friendships (requester_id, addressee_id) values (:'B', :'A');
with x as (update friendships set status='accepted' where requester_id=:'B' returning 1) select 'Dev tries to accept own request, rows changed: '||count(*) from x;
select set_config('request.jwt.claim.sub', :'A', false);
update friendships set status='accepted', responded_at=now() where requester_id=:'B';

select set_config('request.jwt.claim.sub', :'B', false);
select 'Dev (friend) sees Me''s visits: '||coalesce(string_agg(dish,', '),'none') from visits where user_id=:'A';
select 'Dev friend_feed: '||coalesce(string_agg(display_name||' had '||dish||' at '||place_name,', '),'none') from friend_feed;
select set_config('request.jwt.claim.sub', :'C', false);
select 'Stranger sees Me''s visits: '||coalesce(string_agg(dish,', '),'none') from visits where user_id=:'A';
with x as (update visits set rating=1 where user_id=:'A' returning 1) select 'Stranger edits Me''s visit, rows changed: '||count(*) from x;
do $$ begin
  insert into visits (user_id, place_id, dish, rating) select 'aaaaaaaa-0000-0000-0000-000000000001', id, 'Fake', 1 from places limit 1;
  raise notice 'FAIL: stranger posted as Me';
exception when insufficient_privilege then raise notice 'Stranger posting as Me: blocked';
end $$;
do $$ begin
  update places set name='Hacked' where external_id='khao';
  if found then raise notice 'FAIL: stranger edited seed place'; else raise notice 'Stranger editing a seed place: blocked (0 rows)'; end if;
end $$;

-- Snap flow lookups
select set_config('request.jwt.claim.sub', :'A', false);
select 'Standing at Khao San Road: '||string_agg(name||' '||round(distance_m)||' m',', ') from find_places(43.64665,-79.39345);
select 'AI read "Khao San Rd" from 600 m away: '||string_agg(name||' sim '||round(name_similarity::numeric,2),', ') from find_places(43.6490,-79.3880,150,'Khao San Rd');
select 'Me cleared fog points: '||count(*) from my_cleared_points();
select 'Me stats: '||string_agg(p.name||' avg '||s.avg_rating||coalesce(case when s.has_skip then ' (skip)' end,''),', ') from my_place_stats s join places p on p.id=s.place_id;

-- Import the prototype export twice (second run should add nothing)
\set payload '{"exportedAt":"2026-11-05T17:29:24.278Z","places":[{"id":"khao","name":"Khao San Road","cat":"Thai","area":"Adelaide and Charlotte","lat":43.6466,"lng":-79.3935},{"id":"lantern","name":"Lantern Room","cat":"Cocktail bar","area":"Queen West","lat":43.6487,"lng":-79.4021,"date":true,"vibe":["Candlelit","Intimate"],"noise":1,"note":"Book the corner booth. Go after 8."},{"id":"c1793881763635","name":"Pai Northern Thai","cat":"Thai","area":"Duncan St","lat":43.6479,"lng":-79.3871,"custom":true}],"visits":[{"id":1793881763636,"date":"Nov 5","spot":"c1793881763635","dish":"Khao soi with crispy noodles","rating":9,"review":"Rich curry"},{"id":1,"spot":"khao","dish":"Khao soi","rating":9,"review":"Sample entry.","date":"Oct 30"}],"dateNight":{"saved":["c1793881763635"],"planned":["lantern"],"notes":{"lantern":"Anniversary, 8pm"},"bookings":{}}}'
select 'Import 1: '||import_prototype_export(:'payload'::jsonb)::text;
select 'Import 2: '||import_prototype_export(:'payload'::jsonb)::text;
select 'Me visits now: '||count(*)||' ('||string_agg(dish||' '||to_char(visited_at,'Mon DD YYYY'),'; ' order by visited_at)||')' from visits where user_id=:'A';
select 'Date night list: '||string_agg(p.name||case when planned then ' [planned]' else '' end||coalesce(' "'||note||'"',''),', ') from list_items i join places p on p.id=i.place_id;

-- Share the date night list with Dev (a friend) but not the stranger
insert into list_members (list_id, user_id) select id, :'B' from lists where kind='date_night';
do $$ begin
  insert into list_members (list_id, user_id) select id, 'cccccccc-0000-0000-0000-000000000003' from lists where kind='date_night';
  raise notice 'FAIL: shared list with a non-friend';
exception when insufficient_privilege then raise notice 'Sharing list with a non-friend: blocked';
end $$;
select set_config('request.jwt.claim.sub', :'B', false);
select 'Dev sees shared list items: '||count(*) from list_items;
select set_config('request.jwt.claim.sub', :'C', false);
select 'Stranger sees list items: '||count(*) from list_items;
select 'Stranger sees Pai (shared catalog): '||count(*) from places where name='Pai Northern Thai';
