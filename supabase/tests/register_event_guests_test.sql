-- Registered-member guest additions. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/register_event_guests_test.sql

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
  ('44000000-0000-0000-0000-000000000001', 'guest-owner@test.local'),
  ('44000000-0000-0000-0000-000000000002', 'guest-member@test.local'),
  ('44000000-0000-0000-0000-000000000003', 'guest-member-b@test.local'),
  ('44000000-0000-0000-0000-000000000004', 'guest-outsider@test.local');

insert into public.users (user_id, name) values
  ('44000000-0000-0000-0000-000000000001', 'مشرف الضيوف'),
  ('44000000-0000-0000-0000-000000000002', 'عضو الضيوف'),
  ('44000000-0000-0000-0000-000000000003', 'عضو غير مسجل'),
  ('44000000-0000-0000-0000-000000000004', 'غريب');

do $$
declare
  v_workspace json;
  v_workspace_id uuid;
  v_method_one json;
  v_method_one_id uuid;
  v_method_two json;
  v_method_two_id uuid;
  v_event json;
  v_free_event_id uuid;
  v_paid_event_id uuid;
  v_capacity_event_id uuid;
  v_locked_event_id uuid;
  v_cancelled_event_id uuid;
  v_result json;
  v_destination json;
  v_count int;
  v_before int;
  v_push_count_before int;
  v_failed boolean;
begin
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_workspace := public.create_workspace('مجموعة إضافة الضيوف');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '44000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '44000000-0000-0000-0000-000000000003');

  v_method_one := public.upsert_workspace_payment_method(
    v_workspace_id,
    'stc_bank',
    '0500000001'
  );
  v_method_one_id := (v_method_one->>'id')::uuid;
  v_method_two := public.upsert_workspace_payment_method(
    v_workspace_id,
    'barq',
    '0550000002'
  );
  v_method_two_id := (v_method_two->>'id')::uuid;

  -- Free event: only the new guests count toward the batch, and their seats
  -- are immediately confirmed without mutating the member's original row.
  v_event := public.create_event(
    p_creator_id => '44000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مجاني',
    p_start_date => now() + interval '2 days',
    p_max_participants => 8
  );
  v_free_event_id := (v_event->>'id')::uuid;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v_failed := false;
  begin
    v_result := public.register_event_guests(
      p_event_id => v_free_event_id,
      p_guest_names => array['ضيف مجهول']
    );
  exception when others then
    v_failed := sqlerrm = 'Not authenticated';
  end;
  if not v_failed then
    raise exception 'FAIL: anonymous caller registered a guest';
  end if;

  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.submit_payment_v2(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف أولي']
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: member free registration returned %', v_result;
  end if;
  perform 1
  from public.event_participants
  where event_id = v_free_event_id
    and guest_name = 'ضيف أولي'
    and added_by = '44000000-0000-0000-0000-000000000002'
    and not guest_only;
  if not found then
    raise exception 'FAIL: submit_payment_v2 guest compatibility';
  end if;

  v_destination := public.get_event_guest_payment_destination(v_free_event_id);
  if v_destination->>'status' <> 'free'
     or (v_destination->>'event_id')::uuid <> v_free_event_id
     or (v_destination->>'price_per_person')::numeric <> 0 then
    raise exception 'FAIL: free guest destination %', v_destination;
  end if;

  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array[' ', null, E'\t']
  );
  if v_result->>'status' <> 'empty_guests' then
    raise exception 'FAIL: empty guest batch returned %', v_result;
  end if;

  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['خالد', '  خالد  ']
  );
  if v_result->>'status' <> 'duplicate_name' then
    raise exception 'FAIL: duplicate request names returned %', v_result;
  end if;

  select count(*) into v_before
  from public.event_participants
  where event_id = v_free_event_id;

  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['  خالد   م  ', 'سعد']
  );
  if v_result->>'status' <> 'submitted'
     or (v_result->>'group_size')::int <> 2
     or v_result->>'provider' is not null then
    raise exception 'FAIL: free guest submission %', v_result;
  end if;

  select count(*) into v_count
  from public.event_participants
  where event_id = v_free_event_id
    and user_id is null
    and added_by = '44000000-0000-0000-0000-000000000002'
    and guest_name in ('خالد م', 'سعد')
    and payment_status = 'confirmed'
    and not added_manually
    and not guest_only;
  if v_count <> 2 then
    raise exception 'FAIL: free guest rows were not normalized/confirmed';
  end if;

  perform 1
  from public.event_participants
  where event_id = v_free_event_id
    and user_id = '44000000-0000-0000-0000-000000000002'
    and payment_status = 'confirmed'
    and payment_group_size = 2;
  if not found then
    raise exception 'FAIL: adding guests mutated the original member group';
  end if;

  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['خالد م']
  );
  if v_result->>'status' <> 'duplicate_name' then
    raise exception 'FAIL: retried existing guest returned %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_free_event_id;
  if v_count <> v_before + 2 then
    raise exception 'FAIL: duplicate retry inserted another seat';
  end if;

  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['نواف']
  );
  if v_result->>'status' <> 'submitted'
     or (v_result->>'group_size')::int <> 1 then
    raise exception 'FAIL: second confirmed free batch returned %', v_result;
  end if;
  perform 1
  from public.event_participants
  where event_id = v_free_event_id
    and guest_name = 'نواف'
    and added_by = '44000000-0000-0000-0000-000000000002'
    and payment_status = 'confirmed';
  if not found then
    raise exception 'FAIL: second free batch was not inserted';
  end if;

  -- Another workspace member cannot add guests until their own participant row
  -- exists. A non-member cannot inspect or mutate this workspace at all.
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000003');
  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف بلا مسجل']
  );
  if v_result->>'status' <> 'not_registered' then
    raise exception 'FAIL: unregistered member returned %', v_result;
  end if;

  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000004');
  v_failed := false;
  begin
    v_result := public.register_event_guests(
      p_event_id => v_free_event_id,
      p_guest_names => array['ضيف غريب']
    );
  exception when others then
    v_failed := sqlerrm = 'Not a workspace member';
  end;
  if not v_failed then
    raise exception 'FAIL: outsider added a guest';
  end if;

  v_failed := false;
  begin
    v_destination := public.get_event_guest_payment_destination(v_free_event_id);
  exception when others then
    v_failed := sqlerrm = 'Not a workspace member';
  end;
  if not v_failed then
    raise exception 'FAIL: outsider read guest payment details';
  end if;

  -- Capacity includes every pending and confirmed row. The event lock makes
  -- this check and the following batch insert one serialized decision.
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '44000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين ممتلئ',
    p_start_date => now() + interval '3 days',
    p_max_participants => 3
  );
  v_capacity_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.submit_payment_v2(p_event_id => v_capacity_event_id);
  v_result := public.register_event_guests(
    p_event_id => v_capacity_event_id,
    p_guest_names => array['ضيف 1', 'ضيف 2']
  );
  if v_result->>'status' <> 'seats_full' then
    raise exception 'FAIL: capacity check returned %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_capacity_event_id;
  if v_count <> 2 then
    raise exception 'FAIL: failed capacity batch was not atomic';
  end if;

  -- Registration lock and occurrence cancellation produce explicit outcomes
  -- and never rely on a trigger exception after a partial insert.
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '44000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مقفل',
    p_start_date => now() + interval '4 days',
    p_max_participants => 5
  );
  v_locked_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.submit_payment_v2(p_event_id => v_locked_event_id);
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  update public.events set registration_locked = true where id = v_locked_event_id;
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guests(
    p_event_id => v_locked_event_id,
    p_guest_names => array['ضيف المقفل']
  );
  if v_result->>'status' <> 'registration_closed' then
    raise exception 'FAIL: locked event returned %', v_result;
  end if;

  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '44000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين ملغي',
    p_start_date => now() + interval '5 days',
    p_max_participants => 5
  );
  v_cancelled_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.submit_payment_v2(p_event_id => v_cancelled_event_id);
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_result := public.cancel_event_occurrence(v_cancelled_event_id);
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guests(
    p_event_id => v_cancelled_event_id,
    p_guest_names => array['ضيف الملغي']
  );
  if v_result->>'status' <> 'cancelled' then
    raise exception 'FAIL: cancelled event returned %', v_result;
  end if;

  -- Paid event: the guest destination ignores the member's old snapshot and
  -- follows the event's current method. New guest rows carry only that current
  -- snapshot and remain pending for organizer confirmation.
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '44000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مدفوع',
    p_start_date => now() + interval '6 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => array[v_method_one_id]
  );
  v_paid_event_id := (v_event->>'id')::uuid;

  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_result := public.submit_payment_v2(
    p_event_id => v_paid_event_id,
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: paid self registration returned %', v_result;
  end if;

  -- Holding a seat is enough. Since pay-after-registering, a paid
  -- registration sits at 'pending' until the organizer confirms the transfer,
  -- and that is the state the app offers «سجّل معك أحد» in. Requiring
  -- 'confirmed' here made the feature unreachable for every paid event.
  select count(*) into v_before
  from public.event_participants
  where event_id = v_paid_event_id;
  v_result := public.register_event_guests(
    p_event_id => v_paid_event_id,
    p_guest_names => array['ضيف قبل التأكيد'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: pending member could not add guests %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id;
  if v_count <> v_before + 1 then
    raise exception 'FAIL: pending-member guest request seated no one';
  end if;

  -- Undo that batch so the assertions below keep the same preconditions they
  -- were written against: one confirmed self seat and no open guest batch.
  delete from public.event_participants
  where event_id = v_paid_event_id
    and guest_name = 'ضيف قبل التأكيد';

  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_result := public.confirm_payment(
    v_paid_event_id,
    '44000000-0000-0000-0000-000000000002',
    '44000000-0000-0000-0000-000000000001'
  );
  update public.events
  set payment_method_id = v_method_two_id,
      payment_method_ids = array[v_method_two_id]
  where id = v_paid_event_id;

  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_destination := public.get_event_guest_payment_destination(v_paid_event_id);
  if v_destination->>'status' <> 'available'
     or v_destination->>'payment_method_id' is not null
     or json_array_length(v_destination->'payment_methods') <> 1
     or (v_destination->'payment_methods'->0->>'payment_method_id')::uuid
       <> v_method_two_id then
    raise exception 'FAIL: current guest payment destination %', v_destination;
  end if;

  v_destination := public.get_event_payment_destination(v_paid_event_id);
  if (v_destination->>'payment_method_id')::uuid <> v_method_one_id then
    raise exception 'FAIL: test precondition lost original self snapshot %', v_destination;
  end if;

  select count(*) into v_before
  from public.event_participants
  where event_id = v_paid_event_id;

  -- A method that the organizer has since withdrawn is no longer a reason to
  -- refuse: registering a guest picks no method at all. The price is still
  -- guarded, which the next case covers.
  v_result := public.register_event_guests(
    p_event_id => v_paid_event_id,
    p_guest_names => array['قديم'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: withdrawn method blocked a seat %', v_result;
  end if;
  delete from public.event_participants
  where event_id = v_paid_event_id and guest_name = 'قديم';

  v_result := public.register_event_guests(
    p_event_id => v_paid_event_id,
    p_guest_names => array['سعر قديم'],
    p_expected_payment_method_id => v_method_two_id,
    p_expected_price_per_person => 101,
    p_payment_method_id => v_method_two_id
  );
  if v_result->>'status' <> 'event_terms_changed' then
    raise exception 'FAIL: stale price was accepted %', v_result;
  end if;

  select count(*) into v_count
  from public.push_outbox
  where event_id = v_paid_event_id
    and user_id = '44000000-0000-0000-0000-000000000001'
    and type = 'payment_submitted';
  v_push_count_before := v_count;

  v_result := public.register_event_guests(
    p_event_id => v_paid_event_id,
    p_guest_names => array['ضيف مدفوع 1', 'ضيف مدفوع 2'],
    p_expected_payment_method_id => v_method_two_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_two_id
  );
  if v_result->>'status' <> 'submitted'
     or (v_result->>'group_size')::int <> 2
     or (v_result->>'payment_method_id')::uuid <> v_method_two_id
     or v_result->>'provider' <> 'barq' then
    raise exception 'FAIL: paid guest submission %', v_result;
  end if;

  -- Owing, but to nobody in particular yet. declare_event_payment is what
  -- writes the destination onto these rows, together with the member's seat.
  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id
    and user_id is null
    and added_by = '44000000-0000-0000-0000-000000000002'
    and payment_status = 'pending'
    and payment_declared_at is null
    and payment_method_id is null
    and payment_provider is null
    and paid_to_number is null
    and paid_price_per_person = 100
    and not added_manually
    and not guest_only;
  if v_count <> 2 then
    raise exception 'FAIL: paid guest rows were snapshotted too early';
  end if;

  select count(*) into v_before
  from public.event_participants
  where event_id = v_paid_event_id;
  v_result := public.register_event_guests(
    p_event_id => v_paid_event_id,
    p_guest_names => array['دفعة مدفوعة ثانية'],
    p_expected_payment_method_id => v_method_two_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_two_id
  );
  if v_result->>'status' <> 'pending_guest_request' then
    raise exception 'FAIL: a second pending guest batch returned %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id;
  if v_count <> v_before then
    raise exception 'FAIL: second pending guest batch inserted rows';
  end if;

  perform 1
  from public.event_participants
  where event_id = v_paid_event_id
    and user_id = '44000000-0000-0000-0000-000000000002'
    and payment_status = 'confirmed'
    and payment_method_id = v_method_one_id
    and payment_group_size = 1;
  if not found then
    raise exception 'FAIL: paid self snapshot was overwritten';
  end if;

  select count(*) into v_count
  from public.push_outbox
  where event_id = v_paid_event_id
    and user_id = '44000000-0000-0000-0000-000000000001'
    and type = 'payment_submitted';
  if v_count <> v_push_count_before then
    raise exception 'FAIL: adding guests announced a payment nobody declared';
  end if;

  -- Existing payment administration stays compatible: confirming by the
  -- adding member id confirms only their pending guest rows.
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000001');
  v_result := public.confirm_payment(
    v_paid_event_id,
    '44000000-0000-0000-0000-000000000002',
    '44000000-0000-0000-0000-000000000001'
  );
  if v_result->>'status' <> 'confirmed' then
    raise exception 'FAIL: existing confirm_payment rejected guest batch %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id
    and added_by = '44000000-0000-0000-0000-000000000002'
    and payment_status = 'confirmed';
  if v_count <> 2 then
    raise exception 'FAIL: existing confirm_payment missed guests';
  end if;

  -- The read and write surfaces deliberately differ now. Asking where to pay
  -- still reports that the organizer has added nowhere to pay; taking a seat
  -- no longer needs an answer to that question, so it succeeds anyway — the
  -- same way register_event_seat seats the member on such an event.
  update public.events
  set payment_method_id = null,
      payment_method_ids = '{}'::uuid[]
  where id = v_paid_event_id;
  perform pg_temp.set_auth('44000000-0000-0000-0000-000000000002');
  v_destination := public.get_event_guest_payment_destination(v_paid_event_id);
  if v_destination->>'status' <> 'payment_method_required' then
    raise exception 'FAIL: missing guest destination %', v_destination;
  end if;
  v_result := public.register_event_guests(
    p_event_id => v_paid_event_id,
    p_guest_names => array['ضيف بلا وسيلة'],
    p_expected_price_per_person => 100
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: a missing destination blocked a guest seat %', v_result;
  end if;

  -- guest_only is reserved for real guest rows; the schema refuses to mark a
  -- member's self row with it even through a direct privileged write.
  v_failed := false;
  begin
    update public.event_participants
    set guest_only = true
    where event_id = v_free_event_id
      and user_id = '44000000-0000-0000-0000-000000000002';
  exception when check_violation then
    v_failed := true;
  end;
  if not v_failed then
    raise exception 'FAIL: guest_only accepted a member row';
  end if;
end;
$$;

rollback;
