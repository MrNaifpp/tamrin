-- STC Pay: waitlist for full paid events.
-- When seats are full, joiners sit here. Seat-frees push all waiters; first
-- to call submit_payment wins.

create table if not exists public.event_waitlist (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index if not exists idx_event_waitlist_event_id on public.event_waitlist(event_id);
create index if not exists idx_event_waitlist_user_id on public.event_waitlist(user_id);

alter table public.event_waitlist enable row level security;

-- Users can see their own waitlist rows.
create policy "Users can select own waitlist rows"
  on public.event_waitlist for select
  using (user_id = auth.uid());

-- Users can insert/delete their own waitlist rows directly (defense in depth;
-- normal path is through join_waitlist / leave_waitlist RPCs).
create policy "Users can join waitlist for self"
  on public.event_waitlist for insert
  with check (user_id = auth.uid());

create policy "Users can leave waitlist for self"
  on public.event_waitlist for delete
  using (user_id = auth.uid());
