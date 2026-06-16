-- STC Pay: APNs device tokens for push notifications.
-- Upserted from the iOS client on every successful APNs registration.

create table if not exists public.device_tokens (
  user_id uuid not null references auth.users(id) on delete cascade,
  apns_token text not null,
  platform text not null default 'ios',
  updated_at timestamptz not null default now(),
  primary key (user_id, apns_token)
);

create index if not exists idx_device_tokens_user_id on public.device_tokens(user_id);

alter table public.device_tokens enable row level security;

-- Users can upsert and read their own tokens.
create policy "Users can manage own device tokens"
  on public.device_tokens for all
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

-- Touch updated_at on every upsert (trigger).
create or replace function public.touch_device_tokens_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_device_tokens_updated_at on public.device_tokens;
create trigger trg_device_tokens_updated_at
  before update on public.device_tokens
  for each row execute function public.touch_device_tokens_updated_at();
