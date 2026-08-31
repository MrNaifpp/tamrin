-- The finished card lingers exactly while it is owed. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/linger_unpaid_occurrence_test.sql
--
-- Nothing here withholds the next occurrence. The only per-member difference
-- is whether last week's card is still on the shelf, and that ends when the
-- debt does — by declaring, or by the waiver 24h after the exercise started.

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text,
    true
  );
end;
$$;

insert into auth.users (id, email) values
  ('63000000-0000-0000-0000-000000000001', 'linger-owner@test.local'),
  ('63000000-0000-0000-0000-000000000002', 'linger-owes@test.local'),
  ('63000000-0000-0000-0000-000000000003', 'linger-settled@test.local');

insert into public.workspaces (id, name, owner_id)
values ('63000000-0000-0000-0000-0000000000a1', 'Linger WS',
        '63000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id)
values ('63000000-0000-0000-0000-0000000000a1', '63000000-0000-0000-0000-000000000001'),
       ('63000000-0000-0000-0000-0000000000a1', '63000000-0000-0000-0000-000000000002'),
       ('63000000-0000-0000-0000-0000000000a1', '63000000-0000-0000-0000-000000000003');

-- Built in the future and filled, then moved back: a seat cannot be taken on
-- an exercise that has already ended.
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at,
   max_participants, total_price, price_per_person)
values ('63000000-0000-0000-0000-0000000000b1',
        '63000000-0000-0000-0000-000000000001',
        '63000000-0000-0000-0000-0000000000a1',
        'الأحد الماضي', now() + interval '1 day', now() + interval '1 day 2 hours',
        now(), 12, 120, 10);

insert into public.event_participants (event_id, user_id, payment_status, payment_declared_at)
values ('63000000-0000-0000-0000-0000000000b1', '63000000-0000-0000-0000-000000000002', 'pending', null),
       ('63000000-0000-0000-0000-0000000000b1', '63000000-0000-0000-0000-000000000003', 'confirmed', now());

-- Finished two hours ago: inside the 24h grace.
update public.events
set start_date = now() - interval '4 hours',
    end_date = now() - interval '2 hours'
where id = '63000000-0000-0000-0000-0000000000b1';

do $$
declare
  v_feed json;
  v_count integer;
begin
  perform pg_temp.set_auth('63000000-0000-0000-0000-000000000002');
  v_feed := public.get_workspace_events('63000000-0000-0000-0000-0000000000a1');
  select count(*) into v_count from json_array_elements(v_feed) item
  where (item->>'id')::uuid = '63000000-0000-0000-0000-0000000000b1'
    and (item->>'requires_payment_action')::boolean is true;
  if v_count <> 1 then
    raise exception 'FAIL: an owing member lost the finished card inside the window: %', v_feed;
  end if;

  perform pg_temp.set_auth('63000000-0000-0000-0000-000000000003');
  v_feed := public.get_workspace_events('63000000-0000-0000-0000-0000000000a1');
  select count(*) into v_count from json_array_elements(v_feed) item
  where (item->>'id')::uuid = '63000000-0000-0000-0000-0000000000b1';
  if v_count <> 0 then
    raise exception 'FAIL: a settled member still sees the finished card: %', v_feed;
  end if;
end;
$$;

-- Push past the deadline and let the waiver run, as the cron would.
update public.events
set start_date = now() - interval '25 hours',
    end_date = now() - interval '23 hours'
where id = '63000000-0000-0000-0000-0000000000b1';

do $$
declare
  v_feed json;
  v_count integer;
begin
  perform public.waive_expired_event_debts();

  if (select payment_status from public.event_participants
      where event_id = '63000000-0000-0000-0000-0000000000b1'
        and user_id = '63000000-0000-0000-0000-000000000002') <> 'waived' then
    raise exception 'FAIL: the debt did not expire at the deadline';
  end if;

  perform pg_temp.set_auth('63000000-0000-0000-0000-000000000002');
  v_feed := public.get_workspace_events('63000000-0000-0000-0000-0000000000a1');
  select count(*) into v_count from json_array_elements(v_feed) item
  where (item->>'id')::uuid = '63000000-0000-0000-0000-0000000000b1';
  if v_count <> 0 then
    raise exception 'FAIL: the card outlived the debt that held it: %', v_feed;
  end if;
end;
$$;

rollback;
