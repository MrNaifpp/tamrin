-- Fill milestone notifications to the event owner. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/event_fill_notifications_test.sql

begin;

-- trg_announce_event_fill is deferred to end of transaction, and this suite
-- never commits. `set constraints all immediate` after each seating action is
-- what makes the trigger run at a point the assertions can observe.

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

-- Counts owner-bound pushes of one type for one event.
create or replace function pg_temp.fill_pushes(p_event_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id and type = p_type;
$$;

insert into auth.users (id, email) values
  ('46000000-0000-0000-0000-000000000001', 'fill-owner@test.local'),
  ('46000000-0000-0000-0000-000000000002', 'fill-member-b@test.local'),
  ('46000000-0000-0000-0000-000000000003', 'fill-member-c@test.local');

insert into public.users (user_id, name) values
  ('46000000-0000-0000-0000-000000000001', 'مشرف الامتلاء'),
  ('46000000-0000-0000-0000-000000000002', 'عضو ب'),
  ('46000000-0000-0000-0000-000000000003', 'عضو ج');

do $$
declare
  v_workspace json;
  v_workspace_id uuid;
  v_event json;
  v_big_event_id uuid;
  v_batch_event_id uuid;
  v_uncapped_event_id uuid;
  v_draft_event_id uuid;
  v_small_event_id uuid;
  v_result json;
  v_mark int;
begin
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_workspace := public.create_workspace('مجموعة الامتلاء');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '46000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '46000000-0000-0000-0000-000000000003');

  -- ---------------------------------------------------------------------
  -- A 16 seat session announces each quarter exactly once. The owner's own
  -- seat from create_event is already one of the sixteen.
  -- ---------------------------------------------------------------------
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين كبير',
    p_start_date => now() + interval '3 days',
    p_max_participants => 16
  );
  v_big_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_big_event_id);

  -- 1/16 = 6%: nothing yet.
  set constraints all immediate;

  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_25') <> 0 then
    raise exception 'FAIL: announced a quarter at one seat';
  end if;

  -- Member B takes 3 seats -> 4/16 = 25%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ب1', 'ضيف ب2']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_25') <> 1 then
    raise exception 'FAIL: quarter not announced at 4/16';
  end if;

  -- Member C takes 4 seats -> 8/16 = 50%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ج1', 'ضيف ج2', 'ضيف ج3']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: half not announced at 8/16';
  end if;

  -- Four more of member C's guests -> 12/16 = 75%.
  v_result := public.register_event_guests(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ج4', 'ضيف ج5', 'ضيف ج6', 'ضيف ج7']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_75') <> 1 then
    raise exception 'FAIL: three quarters not announced at 12/16';
  end if;

  -- Four more -> 16/16 = 100%.
  v_result := public.register_event_guests(
    p_event_id => v_big_event_id,
    p_guest_names => array['ضيف ج8', 'ضيف ج9', 'ضيف ج10', 'ضيف ج11']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_big_event_id, 'event_full') <> 1 then
    raise exception 'FAIL: full not announced at 16/16';
  end if;

  -- Each quarter announced once, not repeatedly on the way past.
  set constraints all immediate;

  if pg_temp.fill_pushes(v_big_event_id, 'event_fill_25') <> 1
     or pg_temp.fill_pushes(v_big_event_id, 'event_fill_50') <> 1
     or pg_temp.fill_pushes(v_big_event_id, 'event_fill_75') <> 1 then
    raise exception 'FAIL: a quarter announced more than once';
  end if;

  -- ---------------------------------------------------------------------
  -- A batch that vaults a milestone announces only the one it landed on.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين الدفعة',
    p_start_date => now() + interval '4 days',
    p_max_participants => 16
  );
  v_batch_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_batch_event_id);

  -- Owner holds 1. Member B takes 7 in one statement -> 8/16 = 50%,
  -- straight past 25%.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_batch_event_id,
    p_guest_names => array['د1', 'د2', 'د3', 'د4', 'د5', 'د6']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_batch_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: the landed milestone was not announced';
  end if;
  set constraints all immediate;

  if pg_temp.fill_pushes(v_batch_event_id, 'event_fill_25') <> 0 then
    raise exception 'FAIL: a vaulted milestone was announced too';
  end if;

  -- ---------------------------------------------------------------------
  -- Falling back under a milestone does not re-arm it.
  -- ---------------------------------------------------------------------
  v_result := public.leave_event(
    v_batch_event_id,
    '46000000-0000-0000-0000-000000000002'
  );
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(
    p_event_id => v_batch_event_id,
    p_guest_names => array['ه1', 'ه2', 'ه3', 'ه4', 'ه5', 'ه6']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_batch_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: half announced a second time after a withdrawal';
  end if;

  -- ---------------------------------------------------------------------
  -- No capacity means no percentage.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين بلا سقف',
    p_start_date => now() + interval '5 days'
  );
  v_uncapped_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_uncapped_event_id);

  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(
    p_event_id => v_uncapped_event_id,
    p_guest_names => array['و1', 'و2', 'و3']
  );
  set constraints all immediate;

  select count(*) into v_mark from public.push_outbox
  where event_id = v_uncapped_event_id and type like 'event_fill%';
  if v_mark <> 0 then
    raise exception 'FAIL: an uncapped session announced a milestone';
  end if;

  -- ---------------------------------------------------------------------
  -- An unpublished session announces nothing, however full it is. A single
  -- seat is the whole capacity here, so create_event's own insert of the
  -- creator would be 100% if publication were not required.
  --
  -- It has to be tested this way round: guard_event_registration_insert
  -- rejects every other insert into a draft session with "Event is not
  -- published", so the creator's seat is the only one that can reach the
  -- fill trigger at all.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مسودة',
    p_start_date => now() + interval '6 days',
    p_max_participants => 1
  );
  v_draft_event_id := (v_event->>'id')::uuid;

  set constraints all immediate;

  select count(*) into v_mark from public.push_outbox
  where event_id = v_draft_event_id;
  if v_mark <> 0 then
    raise exception 'FAIL: a draft session announced a milestone';
  end if;

  select fill_notified_pct into v_mark from public.events
  where id = v_draft_event_id;
  if v_mark <> 0 then
    raise exception 'FAIL: a draft session advanced its mark';
  end if;

  -- ---------------------------------------------------------------------
  -- Under eight seats a quarter is one player, so only halves announce.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '46000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين صغير',
    p_start_date => now() + interval '7 days',
    p_max_participants => 6
  );
  v_small_event_id := (v_event->>'id')::uuid;
  v_result := public.publish_event(v_small_event_id);

  -- Member B joins the owner -> 2/6 = 33%: past a quarter, which under the
  -- halves rule is not a milestone at all.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000002');
  v_result := public.register_event_seat(p_event_id => v_small_event_id);
  set constraints all immediate;

  if pg_temp.fill_pushes(v_small_event_id, 'event_fill_25') <> 0 then
    raise exception 'FAIL: a small session announced a quarter';
  end if;

  -- Member C takes 2 -> 4/6 = 66%: the half.
  perform pg_temp.set_auth('46000000-0000-0000-0000-000000000003');
  v_result := public.register_event_seat(
    p_event_id => v_small_event_id,
    p_guest_names => array['ص1']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_small_event_id, 'event_fill_50') <> 1 then
    raise exception 'FAIL: a small session did not announce its half';
  end if;

  -- Two more of member C's guests -> 6/6 = 100%, passing 75% in silence.
  v_result := public.register_event_guests(
    p_event_id => v_small_event_id,
    p_guest_names => array['ص2', 'ص3']
  );
  set constraints all immediate;

  if pg_temp.fill_pushes(v_small_event_id, 'event_full') <> 1 then
    raise exception 'FAIL: a small session did not announce being full';
  end if;
  if pg_temp.fill_pushes(v_small_event_id, 'event_fill_75') <> 0 then
    raise exception 'FAIL: a small session announced three quarters';
  end if;

  raise notice 'ALL FILL NOTIFICATION TESTS PASSED';
end;
$$;

rollback;
