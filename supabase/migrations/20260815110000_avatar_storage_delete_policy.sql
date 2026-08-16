-- 20260815100000_avatar_storage_policies.sql gave the bucket select, insert and
-- update: enough to upload a photo and replace it, which was all the client
-- could do at the time. Removing one is now a real action in the profile sheet,
-- and without a delete policy it comes back 403 the same way uploading did.
--
-- Deleting is done through the storage API, not `delete from storage.objects` —
-- the SQL route drops the metadata row and leaves the blob in the backend. So
-- the check that matters is this policy, not table privileges.
--
-- Same predicate as the others, `lower(name)` included: Swift's UUID.uuidString
-- is uppercase and auth.uid()::text is lowercase, so comparing them unfolded
-- never matches.

drop policy if exists "Users delete their own avatar" on storage.objects;
create policy "Users delete their own avatar"
  on storage.objects
  for delete
  to authenticated
  using (
    bucket_id = 'tamrin-stg'
    and lower(name) = auth.uid()::text || '.jpg'
  );
