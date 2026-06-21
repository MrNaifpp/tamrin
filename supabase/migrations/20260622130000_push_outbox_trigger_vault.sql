-- Hosted Supabase forbids `ALTER DATABASE ... SET` for custom GUCs (postgres is
-- not a superuser), so the trigger reads the function URL + shared secret from
-- Vault instead of current_setting. Store the two secrets named 'send_push_url'
-- and 'send_push_secret' via vault.create_secret (see push-db-settings.md).

create or replace function public.fire_push_outbox()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'send_push_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'send_push_secret';

  -- If not configured yet, skip silently (keeps db reset / CI green).
  if v_url is null or v_url = '' then
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'Authorization', 'Bearer ' || coalesce(v_secret, '')),
    body    := jsonb_build_object('outbox_id', new.id)
  );
  return new;
end;
$$;
