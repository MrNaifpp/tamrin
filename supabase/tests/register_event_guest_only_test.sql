-- Standalone guest registration tests. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/register_event_guest_only_test.sql

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
  ('45000000-0000-0000-0000-000000000001', 'guest-only-owner@test.local'),
  ('45000000-0000-0000-0000-000000000002', 'guest-only-member-a@test.local'),
  ('45000000-0000-0000-0000-000000000003', 'guest-only-member-b@test.local'),
  ('45000000-0000-0000-0000-000000000004', 'guest-only-leaver@test.local'),
  ('45000000-0000-0000-0000-000000000005', 'guest-only-outsider@test.local');

insert into public.users (user_id, name) values
  ('45000000-0000-0000-0000-000000000001', 'مشرف ضيوف فقط'),
  ('45000000-0000-0000-0000-000000000002', 'عضو أ'),
  ('45000000-0000-0000-0000-000000000003', 'عضو ب'),
  ('45000000-0000-0000-0000-000000000004', 'عضو مغادر'),
  ('45000000-0000-0000-0000-000000000005', 'غريب');

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
  v_reject_event_id uuid;
  v_capacity_event_id uuid;
  v_waitlist_event_id uuid;
  v_pending_self_event_id uuid;
  v_guard_event_id uuid;
  v_locked_event_id uuid;
  v_cancelled_event_id uuid;
  v_result json;
  v_self_participant_id uuid;
  v_guest_participant_id uuid;
  v_count int;
  v_before int;
  v_failed boolean;
begin
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_workspace := public.create_workspace('مجموعة ضيوف بدون العضو');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '45000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '45000000-0000-0000-0000-000000000003'),
    (v_workspace_id, '45000000-0000-0000-0000-000000000004');

  v_method_one := public.upsert_workspace_payment_method(
    v_workspace_id,
    'stc_bank',
    '0500000045'
  );
  v_method_one_id := (v_method_one->>'id')::uuid;
  v_method_two := public.upsert_workspace_payment_method(
    v_workspace_id,
    'barq',
    '0550000045'
  );
  v_method_two_id := (v_method_two->>'id')::uuid;

  -- Lifecycle and authorization checks happen before any seat is inserted.
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين حراسة الضيوف',
    p_start_date => now() + interval '1 day',
    p_max_participants => 6
  );
  v_guard_event_id := (v_event->>'id')::uuid;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v_failed := false;
  begin
    v_result := public.register_event_guest_only(
      p_event_id => v_guard_event_id,
      p_guest_names => array['ضيف مجهول']
    );
  exception when others then
    v_failed := sqlerrm = 'Not authenticated';
  end;
  if not v_failed then
    raise exception 'FAIL: anonymous guest-only request';
  end if;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000005');
  v_failed := false;
  begin
    v_result := public.register_event_guest_only(
      p_event_id => v_guard_event_id,
      p_guest_names => array['ضيف غريب']
    );
  exception when others then
    v_failed := sqlerrm = 'Not a workspace member';
  end;
  if not v_failed then
    raise exception 'FAIL: outsider guest-only request';
  end if;

  -- Free standalone guests are confirmed immediately, reserve only their own
  -- seats, and can be added in more than one resolved batch.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مجاني للضيوف',
    p_start_date => now() + interval '2 days',
    p_max_participants => 12
  );
  v_free_event_id := (v_event->>'id')::uuid;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array[' ', null]
  );
  if v_result->>'status' <> 'empty_guests' then
    raise exception 'FAIL: empty standalone batch %', v_result;
  end if;

  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array['نفس الاسم', '  نفس الاسم  ']
  );
  if v_result->>'status' <> 'duplicate_name' then
    raise exception 'FAIL: duplicate standalone request names %', v_result;
  end if;

  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array['  ضيف   مستقل 1 ', 'ضيف مستقل 2']
  );
  if v_result->>'status' <> 'submitted'
     or (v_result->>'group_size')::int <> 2
     or (v_result->>'guest_only')::boolean is not true
     or v_result->>'provider' is not null then
    raise exception 'FAIL: free standalone submission %', v_result;
  end if;

  select count(*) into v_count
  from public.event_participants
  where event_id = v_free_event_id
    and user_id is null
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_name in ('ضيف مستقل 1', 'ضيف مستقل 2')
    and guest_only
    and not added_manually
    and payment_status = 'confirmed';
  if v_count <> 2 then
    raise exception 'FAIL: free standalone rows';
  end if;
  perform 1
  from public.event_participants
  where event_id = v_free_event_id
    and user_id = '45000000-0000-0000-0000-000000000002';
  if found then
    raise exception 'FAIL: guest-only inserted the member';
  end if;

  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف مستقل 3']
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: repeated free standalone batch %', v_result;
  end if;
  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف مستقل 1']
  );
  if v_result->>'status' <> 'duplicate_name' then
    raise exception 'FAIL: existing standalone duplicate %', v_result;
  end if;

  -- T-44 still requires a confirmed self row after the shared refactor.
  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['لا يجب إدخاله']
  );
  if v_result->>'status' <> 'not_registered' then
    raise exception 'FAIL: T-44 wrapper lost self requirement %', v_result;
  end if;

  -- After self-registration, guest-only is refused and the existing T-44
  -- path creates attached guest_only=false rows.
  v_result := public.submit_payment_v2(p_event_id => v_free_event_id);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: self registration after standalone guests %', v_result;
  end if;
  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array['وضع خاطئ']
  );
  if v_result->>'status' <> 'self_already_registered' then
    raise exception 'FAIL: confirmed self used guest-only %', v_result;
  end if;
  v_result := public.register_event_guests(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف مرتبط بالعضو']
  );
  if v_result->>'status' <> 'submitted'
     or (v_result->>'guest_only')::boolean is not false then
    raise exception 'FAIL: T-44 wrapper after shared refactor %', v_result;
  end if;

  -- decline_event removes self + attached guests but preserves every
  -- standalone guest. A later self-registration remains valid and clears the
  -- lightweight declined response through the existing insert trigger.
  v_result := public.decline_event(v_free_event_id, 'busy', 'اختبار');
  if v_result->>'status' <> 'declined'
     or (v_result->>'removed_participant_rows')::int <> 2 then
    raise exception 'FAIL: decline result %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_free_event_id
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_only;
  if v_count <> 3 then
    raise exception 'FAIL: decline removed standalone guests';
  end if;
  perform 1 from public.event_member_responses
  where event_id = v_free_event_id
    and user_id = '45000000-0000-0000-0000-000000000002'
    and status = 'declined';
  if not found then
    raise exception 'FAIL: decline response missing';
  end if;

  v_result := public.submit_payment_v2(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف مرتبط legacy']
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: re-register self after decline %', v_result;
  end if;
  perform 1 from public.event_member_responses
  where event_id = v_free_event_id
    and user_id = '45000000-0000-0000-0000-000000000002';
  if found then
    raise exception 'FAIL: self re-registration did not clear decline';
  end if;

  v_result := public.leave_event(
    v_free_event_id,
    '45000000-0000-0000-0000-000000000002'
  );
  if v_result->>'status' <> 'left' then
    raise exception 'FAIL: legacy leave_event %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_free_event_id
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_only;
  if v_count <> 3 then
    raise exception 'FAIL: legacy leave removed standalone guests';
  end if;

  -- Organizer removal of a member follows the same boundary.
  v_result := public.submit_payment_v2(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف مرتبط بالحذف']
  );
  select id into v_self_participant_id
  from public.event_participants
  where event_id = v_free_event_id
    and user_id = '45000000-0000-0000-0000-000000000002';
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_result := public.remove_event_participant(v_self_participant_id);
  if v_result->>'status' <> 'removed'
     or (v_result->>'removed_count')::int <> 2 then
    raise exception 'FAIL: organizer member removal %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_free_event_id
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_only;
  if v_count <> 3 then
    raise exception 'FAIL: organizer member removal deleted standalone guests';
  end if;

  -- Waitlist and pending self rows are both active self-registration states.
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'قائمة انتظار وضيوف',
    p_start_date => now() + interval '3 days',
    p_max_participants => 5
  );
  v_waitlist_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000003');
  v_result := public.join_waitlist(
    v_waitlist_event_id,
    '45000000-0000-0000-0000-000000000003'
  );
  v_result := public.register_event_guest_only(
    p_event_id => v_waitlist_event_id,
    p_guest_names => array['ضيف منتظر']
  );
  if v_result->>'status' <> 'self_registration_pending'
     or v_result->>'payment_status' <> 'waitlisted' then
    raise exception 'FAIL: waitlisted member guest-only %', v_result;
  end if;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تسجيل ذاتي معلق',
    p_start_date => now() + interval '4 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => array[v_method_one_id]
  );
  v_pending_self_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000003');
  v_result := public.submit_payment_v2(
    p_event_id => v_pending_self_event_id,
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  v_result := public.register_event_guest_only(
    p_event_id => v_pending_self_event_id,
    p_guest_names => array['ضيف تسجيل معلق'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'self_registration_pending'
     or v_result->>'payment_status' <> 'pending' then
    raise exception 'FAIL: pending self guest-only %', v_result;
  end if;

  -- Paid standalone batch: current terms and capacity are enforced, snapshots
  -- live on guest rows, and payment administration addresses added_by.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مدفوع ضيوف فقط',
    p_start_date => now() + interval '5 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => array[v_method_one_id]
  );
  v_paid_event_id := (v_event->>'id')::uuid;

  -- A method this event does not offer is no longer a reason to refuse: a
  -- standalone guest seat picks no method either. The price still is, which
  -- the next case covers.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guest_only(
    p_event_id => v_paid_event_id,
    p_guest_names => array['وسيلة قديمة'],
    p_expected_payment_method_id => v_method_two_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_two_id
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: an unoffered method blocked a guest seat %', v_result;
  end if;
  delete from public.event_participants
  where event_id = v_paid_event_id and guest_name = 'وسيلة قديمة';
  v_result := public.register_event_guest_only(
    p_event_id => v_paid_event_id,
    p_guest_names => array['سعر قديم'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 101,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'event_terms_changed' then
    raise exception 'FAIL: stale paid price accepted %', v_result;
  end if;

  select count(*) into v_before
  from public.push_outbox
  where event_id = v_paid_event_id
    and user_id = '45000000-0000-0000-0000-000000000001'
    and type = 'payment_submitted';
  v_result := public.register_event_guest_only(
    p_event_id => v_paid_event_id,
    p_guest_names => array['ضيف مدفوع مستقل 1', 'ضيف مدفوع مستقل 2'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'submitted'
     or (v_result->>'group_size')::int <> 2
     or (v_result->>'guest_only')::boolean is not true
     or v_result->>'payment_method_id' is not null
     or v_result->>'provider' is not null then
    raise exception 'FAIL: paid standalone submission %', v_result;
  end if;
  select count(*) into v_count
  from public.push_outbox
  where event_id = v_paid_event_id
    and user_id = '45000000-0000-0000-0000-000000000001'
    and type = 'payment_submitted';
  if v_count <> v_before then
    raise exception 'FAIL: standalone guests announced an undeclared payment';
  end if;

  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id
    and user_id is null
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_only
    and payment_status = 'pending'
    and payment_declared_at is null
    and payment_method_id is null
    and payment_provider is null
    and paid_to_number is null
    and paid_price_per_person = 100;
  if v_count <> 2 then
    raise exception 'FAIL: paid standalone rows were snapshotted too early';
  end if;

  v_result := public.register_event_guest_only(
    p_event_id => v_paid_event_id,
    p_guest_names => array['دفعة مستقلة ثانية'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'pending_guest_request' then
    raise exception 'FAIL: second paid standalone batch %', v_result;
  end if;

  -- Neither a self seat nor a self waitlist row may start while this payment is
  -- pending. Modern payment returns a status; legacy participant/waitlist
  -- inserts are stopped by the shared trigger under the same event lock.
  v_failed := false;
  begin
    v_result := public.join_waitlist(
      v_paid_event_id,
      '45000000-0000-0000-0000-000000000002'
    );
  exception when others then
    v_failed := sqlerrm =
      'Pending guest request must be resolved before self registration';
  end;
  if not v_failed then
    raise exception 'FAIL: waitlist joined during standalone payment';
  end if;
  perform 1
  from public.event_waitlist
  where event_id = v_paid_event_id
    and user_id = '45000000-0000-0000-0000-000000000002';
  if found then
    raise exception 'FAIL: failed waitlist insert left a row';
  end if;

  v_result := public.submit_payment_v2(
    p_event_id => v_paid_event_id,
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'pending_guest_request' then
    raise exception 'FAIL: self registration merged with standalone batch %', v_result;
  end if;
  v_failed := false;
  begin
    perform public.join_event(
      v_paid_event_id,
      '45000000-0000-0000-0000-000000000002'
    );
  exception when others then
    v_failed := sqlerrm =
      'Pending guest request must be resolved before self registration';
  end;
  if not v_failed then
    raise exception 'FAIL: legacy join merged with standalone payment';
  end if;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_result := public.confirm_payment(
    v_paid_event_id,
    '45000000-0000-0000-0000-000000000002',
    '45000000-0000-0000-0000-000000000001'
  );
  if v_result->>'status' <> 'confirmed' then
    raise exception 'FAIL: confirm standalone payment %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_only
    and payment_status = 'confirmed';
  if v_count <> 2 then
    raise exception 'FAIL: confirm_payment missed standalone guests';
  end if;

  -- Once the standalone batch is resolved, the member may register themselves
  -- and an attached guest. A later decline preserves only standalone rows.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.submit_payment_v2(
    p_event_id => v_paid_event_id,
    p_guest_names => array['ضيف مدفوع مرتبط'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: self registration after standalone confirmation %', v_result;
  end if;
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_result := public.confirm_payment(
    v_paid_event_id,
    '45000000-0000-0000-0000-000000000002',
    '45000000-0000-0000-0000-000000000001'
  );
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guest_only(
    p_event_id => v_paid_event_id,
    p_guest_names => array['وضع مدفوع خاطئ'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  if v_result->>'status' <> 'self_already_registered' then
    raise exception 'FAIL: confirmed paid self used guest-only %', v_result;
  end if;
  v_result := public.decline_event(v_paid_event_id);
  if v_result->>'status' <> 'declined'
     or (v_result->>'removed_participant_rows')::int <> 2 then
    raise exception 'FAIL: paid self decline %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_paid_event_id
    and added_by = '45000000-0000-0000-0000-000000000002'
    and guest_only
    and payment_status = 'confirmed';
  if v_count <> 2 then
    raise exception 'FAIL: paid decline removed standalone guests';
  end if;

  -- Rejection and self-cancellation remain intentionally batch-oriented for a
  -- pending standalone payment and remove every seat in that payment request.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'رفض ضيوف مستقلين',
    p_start_date => now() + interval '6 days',
    p_max_participants => 8,
    p_total_price => 800,
    p_payment_method_ids => array[v_method_one_id]
  );
  v_reject_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000003');
  v_result := public.register_event_guest_only(
    p_event_id => v_reject_event_id,
    p_guest_names => array['ضيف مرفوض 1', 'ضيف مرفوض 2'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_result := public.reject_payment(
    v_reject_event_id,
    '45000000-0000-0000-0000-000000000003',
    '45000000-0000-0000-0000-000000000001'
  );
  if v_result->>'status' <> 'rejected' then
    raise exception 'FAIL: reject standalone payment %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_reject_event_id
    and added_by = '45000000-0000-0000-0000-000000000003';
  if v_count <> 0 then
    raise exception 'FAIL: reject_payment left standalone rows';
  end if;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000003');
  v_result := public.register_event_guest_only(
    p_event_id => v_reject_event_id,
    p_guest_names => array['ضيف ملغي'],
    p_expected_payment_method_id => v_method_one_id,
    p_expected_price_per_person => 100,
    p_payment_method_id => v_method_one_id
  );
  v_result := public.cancel_pending(
    v_reject_event_id,
    '45000000-0000-0000-0000-000000000003'
  );
  if v_result->>'status' <> 'cancelled' then
    raise exception 'FAIL: cancel standalone payment %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_reject_event_id
    and added_by = '45000000-0000-0000-0000-000000000003';
  if v_count <> 0 then
    raise exception 'FAIL: cancel_pending left standalone rows';
  end if;

  -- Seat cap, lock, and cancellation use the same refusal semantics as T-44.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'سعة ضيوف مستقلين',
    p_start_date => now() + interval '7 days',
    p_max_participants => 2
  );
  v_capacity_event_id := (v_event->>'id')::uuid;
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guest_only(
    p_event_id => v_capacity_event_id,
    p_guest_names => array['مقعد 1', 'مقعد 2']
  );
  if v_result->>'status' <> 'seats_full' then
    raise exception 'FAIL: standalone capacity %', v_result;
  end if;
  select count(*) into v_count
  from public.event_participants
  where event_id = v_capacity_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: failed standalone capacity batch was not atomic';
  end if;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'مقفل ضيوف مستقلين',
    p_start_date => now() + interval '8 days',
    p_max_participants => 5
  );
  v_locked_event_id := (v_event->>'id')::uuid;
  update public.events set registration_locked = true where id = v_locked_event_id;
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guest_only(
    p_event_id => v_locked_event_id,
    p_guest_names => array['ضيف مقفل']
  );
  if v_result->>'status' <> 'registration_closed' then
    raise exception 'FAIL: locked standalone event %', v_result;
  end if;

  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000001');
  v_event := public.create_event(
    p_creator_id => '45000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'ملغي ضيوف مستقلين',
    p_start_date => now() + interval '9 days',
    p_max_participants => 5
  );
  v_cancelled_event_id := (v_event->>'id')::uuid;
  v_result := public.cancel_event_occurrence(v_cancelled_event_id);
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000002');
  v_result := public.register_event_guest_only(
    p_event_id => v_cancelled_event_id,
    p_guest_names => array['ضيف ملغي']
  );
  if v_result->>'status' <> 'cancelled' then
    raise exception 'FAIL: cancelled standalone event %', v_result;
  end if;

  -- Leaving the workspace remains deliberately broader than leaving one event:
  -- every self/guest row owned by the member is removed, including guest_only.
  perform pg_temp.set_auth('45000000-0000-0000-0000-000000000004');
  v_result := public.register_event_guest_only(
    p_event_id => v_free_event_id,
    p_guest_names => array['ضيف سيغادر']
  );
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: leaver standalone submission %', v_result;
  end if;
  select id into v_guest_participant_id
  from public.event_participants
  where event_id = v_free_event_id
    and added_by = '45000000-0000-0000-0000-000000000004'
    and guest_only;
  v_result := public.leave_workspace(v_workspace_id);
  if v_result->>'status' <> 'left' then
    raise exception 'FAIL: leave_workspace result %', v_result;
  end if;
  perform 1 from public.event_participants where id = v_guest_participant_id;
  if found then
    raise exception 'FAIL: leave_workspace preserved standalone guest';
  end if;
  perform 1 from public.workspace_members
  where workspace_id = v_workspace_id
    and user_id = '45000000-0000-0000-0000-000000000004';
  if found then
    raise exception 'FAIL: leave_workspace preserved membership';
  end if;
end;
$$;

rollback;
