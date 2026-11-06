-- Photo storage for TasteTO. Supabase only (uses its `storage` schema).
-- Run after schema.sql.
--
-- Files live at visit-photos/<user_id>/<visit_id>/<n>.jpg, so the first folder
-- in the path says who owns the file.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('visit-photos', 'visit-photos', false, 5 * 1024 * 1024, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

-- Upload, replace and delete only inside your own folder.
create policy "visit photos: owner writes" on storage.objects for insert to authenticated
  with check (bucket_id = 'visit-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "visit photos: owner updates" on storage.objects for update to authenticated
  using (bucket_id = 'visit-photos' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "visit photos: owner deletes" on storage.objects for delete to authenticated
  using (bucket_id = 'visit-photos' and (storage.foldername(name))[1] = auth.uid()::text);

-- Read a photo if you can read the visit it belongs to (the visits table's own rules decide).
create policy "visit photos: readable with the visit" on storage.objects for select to authenticated
  using (
    bucket_id = 'visit-photos'
    and exists (
      select 1 from public.visit_photos ph
      where ph.storage_path = storage.objects.name
    )
  );
