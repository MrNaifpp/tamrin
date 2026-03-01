-- Fix infinite recursion between events and event_participants SELECT policies.
-- Run if you already applied 20260130100000_create_events.sql.

-- Helper: event IDs visible to user (bypasses RLS to avoid policy recursion)
create or replace function public.get_event_ids_visible_to_user(uid uuid)
returns setof uuid
language sql
security definer
set search_path = public
stable
as $$
  select id from public.events where creator_id = uid
  union
  select event_id from public.event_participants where user_id = uid;
$$;

grant execute on function public.get_event_ids_visible_to_user(uuid) to authenticated;

-- events: use function so SELECT policy does not read event_participants (breaks cycle)
drop policy if exists "Users can select events they created or participate in" on public.events;
create policy "Users can select events they created or participate in"
  on public.events for select
  using (id in (select get_event_ids_visible_to_user(auth.uid())));

-- event_participants: keep non-recursive policy (only references events by creator_id)
drop policy if exists "Users can select participants for visible events" on public.event_participants;
create policy "Users can select participants for visible events"
  on public.event_participants for select
  using (
    user_id = auth.uid()
    or event_id in (
      select id from public.events where creator_id = auth.uid()
    )
  );
