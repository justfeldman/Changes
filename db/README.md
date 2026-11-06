# TasteTO database

Backend: **Supabase**, which gives you a Postgres database with PostGIS for map queries, sign-in, photo storage and an auto-generated API. The app (`sql.html`) stays a static page and talks to it with `supabase-js`. The Claude call moves into a Supabase Edge Function, so the API key is on the server, not in the browser.

## Files

| File | What it does |
| --- | --- |
| `schema.sql` | Tables, map search, views, the prototype importer and the access rules. |
| `storage.sql` | The private `visit-photos` bucket and who can read or upload photos. Supabase only. |
| `seed.sql` | The six starting places from the prototype. Four are made-up demo places; delete them before real users arrive. |
| `tests/` | A local stand-in for Supabase sign-in and a test that checks the access rules with three users. |

## Tables

- **profiles**: one per signed-in user. Holds the home pin and whether new visits default to private, friends or public.
- **friendships**: friend requests. Only the person asked can accept.
- **places**: one shared catalog of restaurants with a map point, plus date-night details (vibes, noise, tip).
- **visits**: one per meal: dish, rating 1-10, review, visibility. Also stores what the AI suggested, so you can measure how often people correct it.
- **visit_photos**: up to 10 per visit. Points at files in storage.
- **lists**, **list_items**, **list_members**: "Date night with Sarah" and other lists, shareable with friends.
- **bookings**: reservations, private to the person who made them.

## What the app calls

- `find_places(lat, lng, radius_m, name_hint)`: the snap flow. Returns places within 150 m of the photo. If the AI read a name off a sign, close name matches within 2 km come first.
- `my_cleared_points()`: the points where the map's fog clears.
- `my_place_stats`, `place_stats`, `friend_feed`: views for the pin pop-ups and the Friends tab.
- `import_prototype_export(json)`: loads the "Raw data (JSON)" section of the prototype's PDF export into the signed-in account. Running it twice adds nothing new.

## Who can see what

Every table has row-level security on:
- You see your own visits, friends' visits marked *friends* or *public*, and everyone's *public* visits.
- Only you can change your visits, bookings and photos.
- Places are readable by everyone, and only the person who added a place can edit it.
- Lists are visible to the owner and the friends it's shared with.

## Set up on Supabase

1. Create a project at supabase.com.
2. In the SQL editor, run `schema.sql`, then `storage.sql`, then `seed.sql`.
3. Copy the project URL and anon key into the app. The anon key is meant to be public: the access rules above protect the data.

## Run the tests locally

You need Postgres 15 or later with PostGIS.

```sh
createdb tasteto_test
psql -d tasteto_test -f db/tests/auth_stub.sql -f db/schema.sql -f db/seed.sql
psql -d tasteto_test -f db/tests/access_test.sql
```

`auth_stub.sql` is a test-only stand-in for Supabase's sign-in tables. Never run it on Supabase.
