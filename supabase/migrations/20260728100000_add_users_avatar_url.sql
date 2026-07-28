-- public.users was created by hand in the Studio SQL editor without an
-- avatar_url column. 20260131000000_baseline_users_table.sql documents the
-- table *with* that column, but it is `create table if not exists`, so against
-- an environment where the table already existed the whole statement was a
-- no-op and the declared schema silently diverged from reality.
--
-- The gap shows up as 42703 "column usr.avatar_url does not exist" from any RPC
-- that reads it. Six RPCs already work around it by emitting
-- `null::text as avatar_url` (see 20260130800000_fix_participants_rpc.sql, whose
-- comment records the discovery). Two read the column directly and therefore
-- fail outright:
--
--   * get_workspace (20260702100200)          -> team details shows an empty
--                                                member roster; the client
--                                                swallows it via `try?`
--   * get_event_member_responses (20260725120000) -> organizer apology reasons
--                                                never load
--
-- Add the column instead of adding a seventh workaround: the baseline migration
-- already declares it, AuthService.UserRecord already maps it, updateProfile
-- already writes it, and uploadAvatar already produces a URL to store. Both
-- functions above then work as written, with no redefinition needed — Postgres
-- invalidates their cached plans on this DDL.
--
-- Nullable with no default, so this is a catalog-only change: no table rewrite,
-- no lock beyond a brief ACCESS EXCLUSIVE, and existing rows read as NULL,
-- which is exactly what the Swift client's `String?` expects.

alter table public.users
  add column if not exists avatar_url text;
