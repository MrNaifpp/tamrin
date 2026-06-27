-- Guests: a joiner can register friends. Each friend is its own row with a
-- null user_id (no account), a guest_name, and added_by = the paying joiner.

-- Allow guest rows (no account).
alter table public.event_participants
  alter column user_id drop not null,
  add column if not exists guest_name text,
  add column if not exists added_by uuid references auth.users(id) on delete cascade;

-- Replace the (event_id, user_id) unique constraint with a partial unique index
-- so multiple guest rows (null user_id) can coexist, while a real user still
-- can't join the same event twice.
alter table public.event_participants
  drop constraint if exists event_participants_event_id_user_id_key;

create unique index if not exists event_participants_event_user_uniq
  on public.event_participants (event_id, user_id)
  where user_id is not null;

create index if not exists idx_event_participants_added_by
  on public.event_participants(added_by);
