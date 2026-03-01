-- Events and event_participants tables for home feed and event details.
-- Run in Supabase SQL Editor or: supabase db push

-- events: created by a user; shown to creator and participants
create table if not exists public.events (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  location text not null default '',
  description text not null default '',
  start_date timestamptz not null,
  end_date timestamptz,
  image_url text,
  max_participants int,
  created_at timestamptz not null default now()
);

-- event_participants: who is in an event (creator is added on create)
create table if not exists public.event_participants (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (event_id, user_id)
);

create index if not exists idx_events_creator_id on public.events(creator_id);
create index if not exists idx_events_start_date on public.events(start_date);
create index if not exists idx_event_participants_event_id on public.event_participants(event_id);
create index if not exists idx_event_participants_user_id on public.event_participants(user_id);

-- RLS
alter table public.events enable row level security;
alter table public.event_participants enable row level security;

-- Helper: event IDs visible to user (creator or participant). Bypasses RLS to avoid policy recursion.
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

-- events: select if user is creator or participant (uses function to avoid recursion)
create policy "Users can select events they created or participate in"
  on public.events for select
  using (id in (select get_event_ids_visible_to_user(auth.uid())));

-- events: insert own (creator_id = self)
create policy "Users can insert own events"
  on public.events for insert
  with check (creator_id = auth.uid());

-- events: update/delete only creator
create policy "Creators can update own events"
  on public.events for update
  using (creator_id = auth.uid());

create policy "Creators can delete own events"
  on public.events for delete
  using (creator_id = auth.uid());

-- event_participants: select own rows or rows for events user created (avoids RLS recursion)
create policy "Users can select participants for visible events"
  on public.event_participants for select
  using (
    user_id = auth.uid()
    or event_id in (
      select id from public.events where creator_id = auth.uid()
    )
  );

-- event_participants: insert for self (join event)
create policy "Users can join events"
  on public.event_participants for insert
  with check (user_id = auth.uid());

-- event_participants: delete own row (leave event)
create policy "Users can leave events"
  on public.event_participants for delete
  using (user_id = auth.uid());
