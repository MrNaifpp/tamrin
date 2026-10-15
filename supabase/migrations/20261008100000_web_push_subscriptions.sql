-- Web Push for the member web app.
--
-- A browser that allows notifications hands the site a subscription: an
-- endpoint on its push service and two keys to encrypt for. send-push reads
-- these rows beside device_tokens and delivers each push_outbox row to both.
--
-- The endpoint is the key: one browser profile is one subscription. When a
-- different account signs in on the same browser, saving again moves the row
-- to them, so a shared phone never notifies the account that signed out.

create table if not exists public.web_push_subscriptions (
  endpoint      text primary key,
  user_id       uuid not null references auth.users(id) on delete cascade,
  p256dh        text not null,
  auth          text not null,
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

create index if not exists idx_web_push_subscriptions_user_id
  on public.web_push_subscriptions(user_id);

-- Clients reach the table only through the two RPCs below.
alter table public.web_push_subscriptions enable row level security;
revoke all on public.web_push_subscriptions from anon, authenticated;

-- send-push POSTs to whatever endpoint is stored, so only real push services
-- are accepted: FCM (Chrome, Samsung Internet, Opera, Edge on Android),
-- Mozilla (Firefox), WNS (Edge on Windows) and Apple (Safari).
create or replace function public.save_web_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if coalesce(p_endpoint, '') !~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+(\.[a-z0-9-]+)*\.notify\.windows\.com|web\.push\.apple\.com)/' then
    raise exception 'Invalid push subscription';
  end if;
  if coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'Invalid push subscription';
  end if;

  insert into public.web_push_subscriptions (endpoint, user_id, p256dh, auth)
  values (p_endpoint, v_uid, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set user_id = excluded.user_id,
        p256dh = excluded.p256dh,
        auth = excluded.auth,
        last_seen_at = now();
end;
$$;

create or replace function public.delete_web_push_subscription(p_endpoint text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  delete from public.web_push_subscriptions
  where endpoint = p_endpoint
    and user_id = auth.uid();
end;
$$;

revoke execute on function public.save_web_push_subscription(text, text, text) from public, anon;
grant execute on function public.save_web_push_subscription(text, text, text) to authenticated;
revoke execute on function public.delete_web_push_subscription(text) from public, anon;
grant execute on function public.delete_web_push_subscription(text) to authenticated;

notify pgrst, 'reload schema';
