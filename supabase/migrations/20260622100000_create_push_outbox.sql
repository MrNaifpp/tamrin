-- Outbox for server-driven push notifications. RPCs insert rows; a trigger
-- (next migration) fires the send-push Edge Function. The row is the durable
-- log of every push attempt + result.

create table if not exists public.push_outbox (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references auth.users(id) on delete cascade, -- recipient
  type        text not null,            -- 'payment_submitted' (more types later)
  event_id    uuid,                     -- deep link + event-name lookup
  status      text not null default 'pending',  -- pending | sent | failed
  attempts    int  not null default 0,
  last_error  text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);

create index if not exists idx_push_outbox_pending
  on public.push_outbox(status) where status = 'pending';

alter table public.push_outbox enable row level security;
-- No policies on purpose: normal clients cannot see or touch this table.
-- SECURITY DEFINER RPCs insert; the Edge Function uses the service role.
