-- Moyasar card payments: the rows only the server may write.
--
-- payments is the money ledger. event_participants stays the seat. One payment
-- covers N seats (a member and their guests), so the seat points at the payment,
-- matching how payment_method_id already sits on the seat row.
--
-- authenticated gets select only. Every insert/update arrives through an Edge
-- Function holding service_role, and settle_payment() is the single place a
-- card-paid seat is confirmed. "The app cannot mark itself paid" is therefore a
-- grant, not a convention.

create table public.workspace_moyasar_recipients (
  workspace_id          uuid primary key references public.workspaces(id) on delete cascade,
  moyasar_recipient_id  text not null,
  recipient_type        text not null
                          check (recipient_type in ('Entity', 'Platform', 'Beneficiary')),
  status                text not null default 'pending'
                          check (status in ('pending', 'verified', 'disabled')),
  verified_at           timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create table public.payments (
  id                  uuid primary key default gen_random_uuid(),
  workspace_id        uuid not null references public.workspaces(id) on delete cascade,
  event_id            uuid not null references public.events(id) on delete cascade,
  user_id             uuid not null references auth.users(id) on delete cascade,
  seat_count          int  not null check (seat_count > 0),
  amount              int  not null check (amount >= 100),
  currency            text not null default 'SAR',
  status              text not null default 'pending'
                        check (status in ('pending', 'processing', 'paid',
                                          'failed', 'cancelled', 'refunded')),
  payment_method      text check (payment_method in ('creditcard', 'applepay',
                                                     'stcpay', 'token')),
  moyasar_payment_id  text unique,
  given_id            uuid not null unique default gen_random_uuid(),
  split_recipient_id  text,
  platform_fee        int  not null default 0 check (platform_fee >= 0),
  failure_code        text,
  failure_message     text,
  last_moyasar_status text,
  authorized_at       timestamptz,
  paid_at             timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create index idx_payments_event_user on public.payments(event_id, user_id);
create index idx_payments_pending
  on public.payments(created_at) where status = 'pending';

create table public.moyasar_webhook_events (
  id           text primary key,
  type         text not null,
  payment_id   uuid references public.payments(id) on delete set null,
  received_at  timestamptz not null default now(),
  raw          jsonb not null
);

alter table public.event_participants
  add column payment_id uuid references public.payments(id) on delete set null;

create index idx_event_participants_payment
  on public.event_participants(payment_id) where payment_id is not null;

-- updated_at upkeep
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger payments_touch before update on public.payments
  for each row execute function public.touch_updated_at();
create trigger recipients_touch before update on public.workspace_moyasar_recipients
  for each row execute function public.touch_updated_at();

-- RLS: read paths only.
alter table public.workspace_moyasar_recipients enable row level security;
alter table public.payments enable row level security;
alter table public.moyasar_webhook_events enable row level security;

create policy "Owners can see their Moyasar recipient"
  on public.workspace_moyasar_recipients for select
  using (exists (
    select 1 from public.workspaces w
    where w.id = workspace_id and w.owner_id = auth.uid()
  ));

create policy "Payers can see their payments"
  on public.payments for select
  using (user_id = auth.uid());

create policy "Owners can see their workspace's payments"
  on public.payments for select
  using (exists (
    select 1 from public.workspaces w
    where w.id = workspace_id and w.owner_id = auth.uid()
  ));

-- No policies on moyasar_webhook_events on purpose: clients never see it.

-- Grants: the default privileges in this project hand `all` to authenticated.
-- Take the write half back explicitly.
revoke insert, update, delete, truncate, references, trigger
  on public.workspace_moyasar_recipients from anon, authenticated;
revoke insert, update, delete, truncate, references, trigger
  on public.payments from anon, authenticated;
revoke all on public.moyasar_webhook_events from anon, authenticated;
grant select on public.workspace_moyasar_recipients to authenticated;
grant select on public.payments to authenticated;
