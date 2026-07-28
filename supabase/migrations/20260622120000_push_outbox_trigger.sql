-- Fires the send-push Edge Function via pg_net whenever a push_outbox row is
-- inserted. Passes ONLY the row id; the function re-reads the row.

create extension if not exists pg_net with schema extensions;

create or replace function public.fire_push_outbox()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_url    text := current_setting('app.send_push_url', true);
  v_secret text := current_setting('app.send_push_secret', true);
begin
  -- If env not configured (e.g. CI / fresh local reset), skip silently.
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

drop trigger if exists trg_fire_push_outbox on public.push_outbox;
create trigger trg_fire_push_outbox
  after insert on public.push_outbox
  for each row execute function public.fire_push_outbox();
