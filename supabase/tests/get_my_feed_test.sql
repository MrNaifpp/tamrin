-- Home feed suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/get_my_feed_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-000000000001', 'owner@test.local'),
  ('00000000-0000-0000-0000-000000000002', 'member@test.local'),
  ('00000000-0000-0000-0000-000000000003', 'stranger@test.local'),
  ('00000000-0000-0000-0000-000000000004', 'second@test.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-000000000001', 'المالك'),
  ('00000000-0000-0000-0000-000000000002', 'عضو'),
  ('00000000-0000-0000-0000-000000000003', 'غريب'),
  ('00000000-0000-0000-0000-000000000004', 'عضو ثاني');

-- Two workspaces the owner runs, one he has nothing to do with. Both members
-- apologize for the first exercise, which is what gives Section 3 two rows to
-- tell apart.
create or replace function pg_temp.world(out e_a uuid) language plpgsql as $$
declare
  w_a uuid; w_b uuid; w_other uuid;
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي أ', '00000000-0000-0000-0000-000000000001') returning id into w_a;
  insert into public.workspaces (name, owner_id)
  values ('نادي ب', '00000000-0000-0000-0000-000000000001') returning id into w_b;
  insert into public.workspaces (name, owner_id)
  values ('نادي غريب', '00000000-0000-0000-0000-000000000003') returning id into w_other;

  insert into public.workspace_members (workspace_id, user_id) values
    (w_a, '00000000-0000-0000-0000-000000000001'),
    (w_a, '00000000-0000-0000-0000-000000000002'),
    (w_a, '00000000-0000-0000-0000-000000000004'),
    (w_b, '00000000-0000-0000-0000-000000000001'),
    (w_other, '00000000-0000-0000-0000-000000000003');

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_a, '00000000-0000-0000-0000-000000000001', 'تمرين أ', now() + interval '1 day', now())
  returning id into e_a;

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_b, '00000000-0000-0000-0000-000000000001', 'تمرين ب', now() + interval '2 days', now());

  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_other, '00000000-0000-0000-0000-000000000003', 'تمرين غريب', now() + interval '1 day', now());

  -- The owner holds a seat, so there is a roster to find.
  insert into public.event_participants (event_id, user_id)
  values (e_a, '00000000-0000-0000-0000-000000000001');

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  perform public.decline_event(e_a, 'travel', 'مسافر');
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000004');
  perform public.decline_event(e_a, 'travel', 'مشغول');
end;
$$;

-- ============================================================
-- Section 1: the feed spans the caller's workspaces and stops there.
-- ============================================================
do $$
declare
  feed json;
begin
  perform pg_temp.world();
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_feed();

  if json_array_length(feed->'workspaces') <> 2 then
    raise exception 'FAIL: % workspaces returned, expected 2', json_array_length(feed->'workspaces');
  end if;
  if json_array_length(feed->'events') <> 2 then
    raise exception 'FAIL: % events returned, expected 2', json_array_length(feed->'events');
  end if;
  if feed::text like '%تمرين غريب%' then
    raise exception 'FAIL: the feed leaked an exercise from a workspace the caller is not in';
  end if;
end $$;

-- ============================================================
-- Section 2: rosters arrive with the events, keyed by event, in
-- the shape get_event_participants already returns.
-- ============================================================
do $$
declare
  feed json;
  row_one json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_feed();

  if json_array_length(feed->'participants') < 1 then
    raise exception 'FAIL: no rosters in the feed';
  end if;

  row_one := feed->'participants'->0;
  if (row_one->>'event_id') is null then
    raise exception 'FAIL: a participant row has no event_id to group it by';
  end if;
  if (row_one->>'participant_id') is null or (row_one->>'display_name') is null then
    raise exception 'FAIL: a participant row is not shaped like get_event_participants';
  end if;
end $$;

-- ============================================================
-- Section 3: an apology is the organizer's to read. He sees both;
-- the member who wrote one sees only his own.
-- ============================================================
do $$
declare
  feed json;
  mine integer;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  feed := public.get_my_feed();
  if json_array_length(feed->'responses') <> 2 then
    raise exception 'FAIL: the organizer sees % apologies, expected 2',
      json_array_length(feed->'responses');
  end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  feed := public.get_my_feed();

  select count(*) into mine
  from json_array_elements(feed->'responses') r
  where r->>'user_id' <> '00000000-0000-0000-0000-000000000002';
  if mine > 0 then
    raise exception 'FAIL: a member read another member''s apology';
  end if;

  if json_array_length(feed->'workspaces') <> 1 then
    raise exception 'FAIL: the member sees % workspaces, expected 1',
      json_array_length(feed->'workspaces');
  end if;
end $$;

-- ============================================================
-- Section 4: a finished exercise the member still owes stays in
-- the feed, flagged. This is the whole reason the shelf can offer
-- «دفع القطة»: the archive is read only, and the registration
-- guard refuses the next occurrence until the debt is declared, so
-- dropping the row here strands the member with no way to pay.
-- ============================================================
do $$
declare
  w_id uuid;
  e_id uuid;
  feed json;
  row_json json;
begin
  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000001');
  w_id := (public.create_workspace('نادي الدين', 'soccer'::public.sport)->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id)
  values (w_id, '00000000-0000-0000-0000-000000000002');

  -- Seated while it was still ahead, because joining an exercise that has
  -- already ended is refused, then moved into the past the way time does it.
  insert into public.events (workspace_id, creator_id, name, start_date, end_date,
                             total_price, max_participants, published_at)
  values (w_id, '00000000-0000-0000-0000-000000000001', 'تمرين فات',
          now() + interval '1 hour', now() + interval '3 hours', 100, 10, now())
  returning id into e_id;

  insert into public.event_participants (event_id, user_id, payment_status)
  values (e_id, '00000000-0000-0000-0000-000000000002', 'pending');

  update public.events
  set start_date = now() - interval '1 day',
      end_date = now() - interval '22 hours'
  where id = e_id;

  perform pg_temp.set_auth('00000000-0000-0000-0000-000000000002');
  feed := public.get_my_feed();

  select value into row_json
  from json_array_elements(feed->'events') value
  where value->>'id' = e_id::text;

  if row_json is null then
    raise exception 'FAIL: an unpaid finished exercise fell out of the feed, so nothing can offer to pay it';
  end if;
  if (row_json->>'requires_payment_action')::boolean is not true then
    raise exception 'FAIL: the unpaid finished exercise is not flagged, so the shelf will not offer «دفع القطة»';
  end if;

  -- And once declared, it stops being held back.
  update public.event_participants
  set payment_declared_at = now()
  where event_id = e_id and user_id = '00000000-0000-0000-0000-000000000002';

  feed := public.get_my_feed();
  if exists (
    select 1 from json_array_elements(feed->'events') value
    where value->>'id' = e_id::text
  ) then
    raise exception 'FAIL: a declared finished exercise is still held on the shelf';
  end if;
end $$;

select 'get_my_feed: all sections passed' as result;

rollback;
