-- Starter places from the TasteTO prototype (sql.html).
-- Khao San Road and Salus Fresh Foods are real restaurants placed near their
-- real addresses. The other four are demo places with made-up locations:
-- remove them before real users see the catalog.
-- external_id keeps the prototype's ids, so import_prototype_export() maps exported visits onto these rows.

insert into places (name, category, area, location, source, external_id, is_date_spot, vibes, noise_level, tip) values
  ('Khao San Road',     'Thai',             'Adelaide and Charlotte', st_setsrid(st_makepoint(-79.3935, 43.6466), 4326)::geography, 'seed', 'khao',    false, '{}', null, null),
  ('Salus Fresh Foods', 'Healthy bowls',    'Downtown',               st_setsrid(st_makepoint(-79.3872, 43.6452), 4326)::geography, 'seed', 'salus',   false, '{}', null, null),
  ('Lantern Room',      'Cocktail bar',     'Queen West',             st_setsrid(st_makepoint(-79.4021, 43.6487), 4326)::geography, 'seed', 'lantern', true,  '{Candlelit,Intimate}',            1, 'Book the corner booth. Go after 8.'),
  ('Marrow and Vine',   'Wine bar',         'King West',              st_setsrid(st_makepoint(-79.4006, 43.6443), 4326)::geography, 'seed', 'marrow',  true,  '{"Natural wine","Small plates"}', 2, 'Walk-ins only on Thursdays.'),
  ('Ash and Ember',     'Wood-fired grill', 'Front Street',           st_setsrid(st_makepoint(-79.3946, 43.6433), 4326)::geography, 'seed', 'ash',     true,  '{"Open kitchen","Dress up a bit"}', 2, 'Ask for the chef''s counter.'),
  ('Kiln Coffee',       'Coffee',           'Richmond',               st_setsrid(st_makepoint(-79.3906, 43.6497), 4326)::geography, 'seed', 'kiln',    false, '{}', null, null)
on conflict (source, external_id) do nothing;
