-- public.users was created by hand in the Studio SQL editor without a primary
-- key. 20260131000000_baseline_users_table.sql declares `user_id uuid primary
-- key`, but it is `create table if not exists`, so against an environment where
-- the table already existed the whole statement was a no-op and the constraint
-- never landed. Same divergence that hid the missing avatar_url column — see
-- 20260728100000_add_users_avatar_url.sql.
--
-- Two consequences, one already hit:
--
--   * upsert(onConflict: 'user_id') fails with 42P10 "no unique or exclusion
--     constraint matching the ON CONFLICT specification". AuthService therefore
--     writes the row with update-then-insert instead of a plain upsert.
--   * nothing prevented duplicate rows per user. getCurrentUserProfile reads
--     with .limit(1) and no ordering, so a duplicate would have made the
--     profile non-deterministic — a different name or avatar between launches.
--
-- Verified clean before writing this: `select user_id, count(*) from
-- public.users group by user_id having count(*) > 1` returned no rows, so the
-- key can be added without deduplicating anything first.
--
-- Adding it also implies NOT NULL on user_id and creates a supporting unique
-- index, so the existing .eq('user_id', ...) lookups get an index rather than a
-- sequential scan.

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conrelid = 'public.users'::regclass and contype = 'p'
  ) then
    -- A keyless table could have accepted a null user_id. Such a row belongs to
    -- nobody and cannot be repaired automatically, so fail loudly rather than
    -- delete someone's data as a side effect of a schema migration.
    if exists (select 1 from public.users where user_id is null) then
      raise exception
        'public.users contains rows with a null user_id; resolve those before adding the primary key';
    end if;

    alter table public.users add primary key (user_id);
  end if;
end $$;
