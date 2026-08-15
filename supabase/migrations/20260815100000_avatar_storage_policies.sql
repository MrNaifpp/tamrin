-- The tamrin-stg storage bucket was created by hand in the Studio SQL editor and
-- never committed, the same divergence 20260728100000_add_users_avatar_url.sql
-- documents for public.users. It drifted differently in each project:
--
--   * sandbox (kpcdinxusxycenfnitjc) — bucket exists, no insert policy. Every
--     avatar upload comes back 403 "new row violates row-level security policy".
--   * prod (hzsxwnmbdkrmipjtfzlp)    — no bucket at all: "Bucket not found".
--
-- Either way AuthService.uploadAvatar returns nil, and saveProfile carries the
-- old URL forward behind `if let`, so the picked photo shows until the next
-- launch and then is gone. Nothing surfaces: the failure is swallowed at the
-- call site and only reaches the log.
--
-- Declaring bucket and policies here is what stops the two projects drifting
-- again. Both statements are idempotent, so this is a no-op wherever the object
-- already matches.

-- Public, because the client hands out getPublicURL(path:) and renders it with
-- AsyncImage — no signed URL is ever minted. Left otherwise as-is on conflict:
-- sandbox serves avatars today and this must not restate its limits.
insert into storage.buckets (id, name, public)
values ('tamrin-stg', 'tamrin-stg', true)
on conflict (id) do nothing;

-- One object per user, named "<user id>.jpg" by uploadAvatar, so ownership is
-- readable straight off the object name and needs no join.
--
-- Swift's UUID.uuidString is UPPERCASE ("E621E1F8-…") while auth.uid()::text is
-- lowercase. Comparing them directly never matches — which would leave the 403
-- exactly where it is — so the object name is folded before comparison.

drop policy if exists "Avatars are publicly readable" on storage.objects;
create policy "Avatars are publicly readable"
  on storage.objects
  for select
  using (bucket_id = 'tamrin-stg');

drop policy if exists "Users upload their own avatar" on storage.objects;
create policy "Users upload their own avatar"
  on storage.objects
  for insert
  to authenticated
  with check (
    bucket_id = 'tamrin-stg'
    and lower(name) = auth.uid()::text || '.jpg'
  );

-- uploadAvatar passes upsert: true, so replacing a photo updates the existing
-- row rather than inserting a second one. Without this the first upload of a
-- user's life succeeds and every replacement 403s.
drop policy if exists "Users replace their own avatar" on storage.objects;
create policy "Users replace their own avatar"
  on storage.objects
  for update
  to authenticated
  using (
    bucket_id = 'tamrin-stg'
    and lower(name) = auth.uid()::text || '.jpg'
  )
  with check (
    bucket_id = 'tamrin-stg'
    and lower(name) = auth.uid()::text || '.jpg'
  );
