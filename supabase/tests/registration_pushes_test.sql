-- Registration pushes to the organizer, fill milestones to the group.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/registration_pushes_test.sql

begin;

-- trg_announce_event_fill is deferred to commit and this suite never commits.
-- After each tap, `set constraints all immediate` runs it, and
-- `set constraints all deferred` puts it back: the mode otherwise stays
-- immediate for the rest of the transaction, and the next tap's own seat and
-- guests would be announced separately, which a real one-transaction tap never
-- does.

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

-- Pushes of one type for one event, to one recipient.
create or replace function pg_temp.pushes(p_event_id uuid, p_user_id uuid, p_type text)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id and user_id = p_user_id and type = p_type;
$$;

-- Every push this feature can produce for one event, to anyone.
create or replace function pg_temp.feature_pushes(p_event_id uuid)
returns int
language sql as $$
  select count(*)::int from public.push_outbox
  where event_id = p_event_id
    and (type in ('member_registered', 'member_added_guests', 'event_full')
         or type like 'event_fill_%');
$$;

insert into auth.users (id, email) values
  ('47000000-0000-0000-0000-000000000001', 'reg-owner@test.local'),
  ('47000000-0000-0000-0000-000000000002', 'reg-a@test.local'),
  ('47000000-0000-0000-0000-000000000003', 'reg-b@test.local'),
  ('47000000-0000-0000-0000-000000000004', 'reg-c@test.local');

insert into public.users (user_id, name) values
  ('47000000-0000-0000-0000-000000000001', 'منظم التسجيلات'),
  ('47000000-0000-0000-0000-000000000002', 'فهد'),
  ('47000000-0000-0000-0000-000000000003', 'سالم'),
  ('47000000-0000-0000-0000-000000000004', 'ناصر');

do $$
declare
  O constant uuid := '47000000-0000-0000-0000-000000000001';
  A constant uuid := '47000000-0000-0000-0000-000000000002';
  B constant uuid := '47000000-0000-0000-0000-000000000003';
  C constant uuid := '47000000-0000-0000-0000-000000000004';
  v_workspace_id uuid;
  v_e1 uuid;
  v_e2 uuid;
  v_e3 uuid;
  v_e4 uuid;
  v_e5 uuid;
  v_row public.push_outbox;
  v_result json;
  v_count int;
  v_before int;
begin
  perform pg_temp.set_auth(O);
  v_workspace_id := (public.create_workspace('مجموعة التسجيلات')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, A), (v_workspace_id, B), (v_workspace_id, C);

  -- -------------------------------------------------------------------
  -- E1: 16 seats. The owner's own seat from create_event is one of them.
  -- -------------------------------------------------------------------
  v_e1 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين الخميس',
    p_start_date => now() + interval '3 days',
    p_max_participants => 16
  )->>'id')::uuid;
  set constraints all immediate;
  set constraints all deferred;

  if pg_temp.feature_pushes(v_e1) <> 0 then
    raise exception 'FAIL: the owner''s own seat was announced';
  end if;

  -- 1. A registers alone -> 2/16. One push to the owner, no milestone.
  perform pg_temp.set_auth(A);
  v_result := public.register_event_seat(p_event_id => v_e1);
  set constraints all immediate;
  set constraints all deferred;

  select * into v_row from public.push_outbox
  where event_id = v_e1 and type = 'member_registered';
  if pg_temp.feature_pushes(v_e1) <> 1
     or v_row.user_id <> O
     or v_row.actor_id <> A
     or v_row.guest_count <> 0
     or v_row.fill_pct is not null then
    raise exception 'FAIL: lone registration pushed %', row_to_json(v_row);
  end if;

  -- 2. B registers with 2 guests -> 5/16 = 31%, crossing 25%.
  --    The owner gets ONE combined push, the group gets the milestone.
  perform pg_temp.set_auth(B);
  v_result := public.register_event_seat(
    p_event_id => v_e1,
    p_guest_names => array['ضيف سالم ١', 'ضيف سالم ٢']
  );
  set constraints all immediate;
  set constraints all deferred;

  select count(*) into v_count from public.push_outbox
  where event_id = v_e1 and actor_id = B;
  if v_count <> 1 then
    raise exception 'FAIL: one tap with guests queued % organizer pushes', v_count;
  end if;
  select * into v_row from public.push_outbox
  where event_id = v_e1 and actor_id = B;
  if v_row.type <> 'member_registered'
     or v_row.user_id <> O
     or v_row.guest_count <> 2
     or v_row.fill_pct <> 25 then
    raise exception 'FAIL: combined push was %', row_to_json(v_row);
  end if;
  if pg_temp.pushes(v_e1, O, 'event_fill_25') <> 0 then
    raise exception 'FAIL: the owner got the milestone twice';
  end if;
  if pg_temp.pushes(v_e1, A, 'event_fill_25') <> 1
     or pg_temp.pushes(v_e1, C, 'event_fill_25') <> 1 then
    raise exception 'FAIL: the group was not told about 25%%';
  end if;
  if pg_temp.pushes(v_e1, B, 'event_fill_25') <> 0 then
    raise exception 'FAIL: the player who crossed 25%% was told about it';
  end if;

  -- 3. A, already seated, adds one guest -> 6/16. Reads as guests only.
  perform pg_temp.set_auth(A);
  v_result := public.register_event_guests(
    p_event_id => v_e1,
    p_guest_names => array['ضيف فهد']
  );
  set constraints all immediate;
  set constraints all deferred;

  select * into v_row from public.push_outbox
  where event_id = v_e1 and type = 'member_added_guests';
  if pg_temp.pushes(v_e1, O, 'member_added_guests') <> 1
     or v_row.actor_id <> A
     or v_row.guest_count <> 1
     or v_row.fill_pct is not null then
    raise exception 'FAIL: guests-only push was %', row_to_json(v_row);
  end if;
  if pg_temp.pushes(v_e1, O, 'member_registered') <> 2 then
    raise exception 'FAIL: adding guests re-announced the member''s own seat';
  end if;

  -- -------------------------------------------------------------------
  -- 5. E2: the owner fills by hand to 4/8 = 50%. Nothing to the owner,
  --    the whole group hears it.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e2 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين المشرف',
    p_start_date => now() + interval '4 days',
    p_max_participants => 8
  )->>'id')::uuid;
  v_result := public.add_manual_participant(v_e2, 'يدوي ١');
  v_result := public.add_manual_participant(v_e2, 'يدوي ٢');
  v_result := public.add_manual_participant(v_e2, 'يدوي ٣');
  set constraints all immediate;
  set constraints all deferred;

  if pg_temp.pushes(v_e2, O, 'event_fill_50') <> 0
     or pg_temp.pushes(v_e2, O, 'member_registered') <> 0
     or pg_temp.pushes(v_e2, O, 'member_added_guests') <> 0 then
    raise exception 'FAIL: the owner was told about their own additions';
  end if;
  if pg_temp.pushes(v_e2, A, 'event_fill_50') <> 1
     or pg_temp.pushes(v_e2, B, 'event_fill_50') <> 1
     or pg_temp.pushes(v_e2, C, 'event_fill_50') <> 1 then
    raise exception 'FAIL: the group missed a milestone the owner caused';
  end if;

  -- -------------------------------------------------------------------
  -- 6. E3: 2 seats. A fills it, then B joins the waitlist: no push.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e3 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين صغير',
    p_start_date => now() + interval '5 days',
    p_max_participants => 2
  )->>'id')::uuid;
  set constraints all immediate;
  set constraints all deferred;

  perform pg_temp.set_auth(A);
  v_result := public.register_event_seat(p_event_id => v_e3);
  set constraints all immediate;
  set constraints all deferred;

  select * into v_row from public.push_outbox
  where event_id = v_e3 and type = 'member_registered';
  if v_row.fill_pct is distinct from 100 then
    raise exception 'FAIL: filling the last seat pushed %', row_to_json(v_row);
  end if;

  v_before := pg_temp.feature_pushes(v_e3);
  perform pg_temp.set_auth(B);
  v_result := public.register_event_seat(p_event_id => v_e3);
  if v_result->>'status' <> 'waitlisted' then
    raise exception 'FAIL: expected B on the waitlist, got %', v_result;
  end if;
  set constraints all immediate;
  set constraints all deferred;

  if pg_temp.feature_pushes(v_e3) <> v_before then
    raise exception 'FAIL: a waitlist join was announced';
  end if;

  -- -------------------------------------------------------------------
  -- 7. E4: no cap. Registrations push, milestones never do.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e4 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين بلا سقف',
    p_start_date => now() + interval '6 days'
  )->>'id')::uuid;

  perform pg_temp.set_auth(A);
  v_result := public.register_event_seat(
    p_event_id => v_e4,
    p_guest_names => array['ضيف ١', 'ضيف ٢', 'ضيف ٣']
  );
  set constraints all immediate;
  set constraints all deferred;

  if pg_temp.pushes(v_e4, O, 'member_registered') <> 1 then
    raise exception 'FAIL: an uncapped workout did not announce a registration';
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_e4 and (type like 'event_fill_%' or type = 'event_full');
  if v_count <> 0 then
    raise exception 'FAIL: an uncapped workout announced a milestone';
  end if;

  -- -------------------------------------------------------------------
  -- 8. E5: seats inserted by the system (no auth.uid(), like the weekly
  --    roll-over) crossing 50%: the owner alone, as before. Those seats
  --    are marked, so C adding a guest later reads as guests only.
  -- -------------------------------------------------------------------
  perform pg_temp.set_auth(O);
  v_e5 := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مُرحّل',
    p_start_date => now() + interval '7 days',
    p_max_participants => 8
  )->>'id')::uuid;
  set constraints all immediate;
  set constraints all deferred;

  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  insert into public.event_participants (event_id, user_id, payment_status) values
    (v_e5, A, 'confirmed'),
    (v_e5, B, 'confirmed'),
    (v_e5, C, 'confirmed');
  set constraints all immediate;
  set constraints all deferred;

  if pg_temp.pushes(v_e5, O, 'event_fill_50') <> 1 then
    raise exception 'FAIL: the owner lost the milestone on a system insert';
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_e5 and user_id <> O
    and (type like 'event_fill_%' or type = 'event_full');
  if v_count <> 0 then
    raise exception 'FAIL: a system insert announced to the group';
  end if;
  if pg_temp.pushes(v_e5, O, 'member_registered') <> 0 then
    raise exception 'FAIL: a system insert was announced as a registration';
  end if;

  perform pg_temp.set_auth(C);
  v_result := public.register_event_guests(
    p_event_id => v_e5,
    p_guest_names => array['ضيف ناصر']
  );
  set constraints all immediate;
  set constraints all deferred;

  if pg_temp.pushes(v_e5, O, 'member_added_guests') <> 1
     or pg_temp.pushes(v_e5, O, 'member_registered') <> 0 then
    raise exception 'FAIL: a carried seat was swept into a later tap';
  end if;

  raise notice 'PASS: registration_pushes';
end;
$$;

rollback;
