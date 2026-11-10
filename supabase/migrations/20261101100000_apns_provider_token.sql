-- One APNs provider token shared by every send-push call.
--
-- Apple wants the provider token (the JWT signed with our APNs key) reused for
-- 20 to 60 minutes, and answers 429 TooManyProviderTokenUpdates when it
-- changes more often. send-push signed a new one per call, and every recipient
-- of a group push is its own call, so from 2026-10-15 bursts were refused.
-- send-push now reads the token from here and replaces it once it is old.

create table if not exists public.apns_provider_token (
  id         int primary key default 1 check (id = 1),
  token      text not null,
  issued_at  timestamptz not null
);

-- Only send-push, holding service_role, reads or writes it.
alter table public.apns_provider_token enable row level security;
revoke all on public.apns_provider_token from anon, authenticated;

-- Stores p_token unless the stored token is younger than p_max_age_seconds
-- (counted from p_issued_at), and returns whichever token is stored. When a
-- burst of calls all find the old token expired, the first claim wins and the
-- rest get its token back, so the burst still shares one token.
create or replace function public.claim_apns_provider_token(
  p_token text,
  p_issued_at timestamptz,
  p_max_age_seconds int
)
returns text
language plpgsql
set search_path = public
as $$
declare
  v_token text;
begin
  insert into public.apns_provider_token as t (id, token, issued_at)
  values (1, p_token, p_issued_at)
  on conflict (id) do update
    set token = excluded.token,
        issued_at = excluded.issued_at
    where t.issued_at <= excluded.issued_at - make_interval(secs => p_max_age_seconds)
  returning token into v_token;

  if v_token is null then
    select token into v_token from public.apns_provider_token where id = 1;
  end if;
  return v_token;
end;
$$;

revoke all on function public.claim_apns_provider_token(text, timestamptz, int)
  from public, anon, authenticated;
grant execute on function public.claim_apns_provider_token(text, timestamptz, int)
  to service_role;
