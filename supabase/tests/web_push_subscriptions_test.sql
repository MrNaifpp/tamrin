-- Web Push subscriptions: saving, moving between accounts, deleting, and the
-- endpoint allow-list.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/web_push_subscriptions_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    case when uid is null then '{}'
         else json_build_object('sub', uid, 'role', 'authenticated')::text end,
    true
  );
end;
$$;

insert into auth.users (id, email) values
  ('48000000-0000-0000-0000-000000000001', 'push-a@test.local'),
  ('48000000-0000-0000-0000-000000000002', 'push-b@test.local');

do $$
declare
  A constant uuid := '48000000-0000-0000-0000-000000000001';
  B constant uuid := '48000000-0000-0000-0000-000000000002';
  E constant text := 'https://fcm.googleapis.com/fcm/send/test-endpoint-1';
  v_owner uuid;
  v_count int;
  v_raised boolean;
begin
  -- 1. Saving stores the subscription for the caller.
  perform pg_temp.set_auth(A);
  perform public.save_web_push_subscription(E, 'p256dh-a', 'auth-a');
  select user_id into v_owner from public.web_push_subscriptions where endpoint = E;
  assert v_owner = A, 'save should store the caller as owner';

  -- 2. The same browser signed in as someone else moves the row to them.
  perform pg_temp.set_auth(B);
  perform public.save_web_push_subscription(E, 'p256dh-b', 'auth-b');
  select count(*) into v_count from public.web_push_subscriptions where endpoint = E;
  assert v_count = 1, 'one browser is one row';
  select user_id into v_owner from public.web_push_subscriptions where endpoint = E;
  assert v_owner = B, 'the row should move to the account now signed in';
  assert (select p256dh from public.web_push_subscriptions where endpoint = E) = 'p256dh-b',
    'keys should be replaced';

  -- 3. Someone else cannot delete it.
  perform pg_temp.set_auth(A);
  perform public.delete_web_push_subscription(E);
  select count(*) into v_count from public.web_push_subscriptions where endpoint = E;
  assert v_count = 1, 'another account must not delete the row';

  -- 4. The owner can.
  perform pg_temp.set_auth(B);
  perform public.delete_web_push_subscription(E);
  select count(*) into v_count from public.web_push_subscriptions where endpoint = E;
  assert v_count = 0, 'the owner deletes the row';

  -- 5. Every allowed push service is accepted.
  perform public.save_web_push_subscription('https://updates.push.services.mozilla.com/wpush/v2/x', 'k', 'a');
  perform public.save_web_push_subscription('https://wns2-db5p.notify.windows.com/w/?token=x', 'k', 'a');
  perform public.save_web_push_subscription('https://web.push.apple.com/x', 'k', 'a');
  select count(*) into v_count from public.web_push_subscriptions where user_id = B;
  assert v_count = 3, 'mozilla, windows and apple endpoints are accepted';

  -- 6. An endpoint off the allow-list is refused.
  v_raised := false;
  begin
    perform public.save_web_push_subscription('https://evil.example.com/fcm.googleapis.com/x', 'k', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'an unknown host must be refused';

  v_raised := false;
  begin
    perform public.save_web_push_subscription('http://fcm.googleapis.com/fcm/send/x', 'k', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'plain http must be refused';

  -- 7. Missing keys are refused.
  v_raised := false;
  begin
    perform public.save_web_push_subscription(E, '', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'an empty p256dh must be refused';

  -- 8. Signed out is refused.
  perform pg_temp.set_auth(null);
  v_raised := false;
  begin
    perform public.save_web_push_subscription(E, 'k', 'a');
  exception when others then v_raised := true;
  end;
  assert v_raised, 'saving without a session must be refused';

  -- 9. Clients cannot read the table directly.
  v_raised := false;
  begin
    execute 'set local role authenticated';
    perform 1 from public.web_push_subscriptions limit 1;
  exception when insufficient_privilege then v_raised := true;
  end;
  execute 'reset role';
  assert v_raised, 'authenticated must not select from the table';

  raise notice 'web_push_subscriptions: PASSED';
end;
$$;

rollback;
