-- Recurring-payment gate tests. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/recurring_payment_gate_test.sql

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
  ('52000000-0000-0000-0000-000000000001', 'recurring-gate-owner@test.local'),
  ('52000000-0000-0000-0000-000000000002', 'recurring-gate-member@test.local'),
  ('52000000-0000-0000-0000-000000000003', 'recurring-gate-waiter@test.local');

insert into public.users (user_id, name) values
  ('52000000-0000-0000-0000-000000000001', 'مشرف بوابة الدفع'),
  ('52000000-0000-0000-0000-000000000002', 'عضو بوابة الدفع'),
  ('52000000-0000-0000-0000-000000000003', 'منتظر المقعد');

do $$
declare
  v_owner constant uuid := '52000000-0000-0000-0000-000000000001';
  v_member constant uuid := '52000000-0000-0000-0000-000000000002';
  v_waiter constant uuid := '52000000-0000-0000-0000-000000000003';
  v_workspace json;
  v_workspace_id uuid;
  v_method json;
  v_method_id uuid;
  v_old_event json;
  v_old_event_id uuid;
  v_template_id uuid;
  v_next_event_id uuid;
  v_next_template_id uuid;
  v_other_event json;
  v_other_event_id uuid;
  v_other_template_id uuid;
  v_result json;
  v_live json;
  v_past json;
  v_count integer;
  v_failed boolean;
begin
  perform pg_temp.set_auth(v_owner);
  v_workspace := public.create_workspace('مجموعة بوابة دفع التكرار');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id)
  values (v_workspace_id, v_member), (v_workspace_id, v_waiter);

  select count(*) into v_count
  from pg_policies
  where schemaname = 'public'
    and tablename = 'event_participants'
    and policyname = 'Users can leave events';
  if v_count <> 0
     or has_table_privilege(
       'authenticated',
       'public.event_participants',
       'DELETE'
     ) then
    raise exception 'FAIL: direct participant DELETE still bypasses guarded RPCs';
  end if;

  v_method := public.upsert_workspace_payment_method(
    v_workspace_id,
    'stc_bank',
    '0500000052'
  );
  v_method_id := (v_method->>'id')::uuid;

  -- Start with a normal paid recurring occurrence so registration creates the
  -- exact pending-and-undeclared row produced by the application RPC.
  v_old_event := public.create_event(
    p_creator_id => v_owner,
    p_workspace_id => v_workspace_id,
    p_name => 'الموعد المنتهي غير المسدد',
    p_start_date => now() + interval '1 day',
    p_end_date => now() + interval '1 day 90 minutes',
    p_max_participants => 12,
    p_total_price => 120,
    p_recurrence => 'weekly',
    p_payment_method_id => v_method_id,
    p_payment_method_ids => array[v_method_id]
  );
  v_old_event_id := (v_old_event->>'id')::uuid;
  v_template_id := (v_old_event->>'template_id')::uuid;
  v_result := public.publish_event(v_old_event_id);

  perform pg_temp.set_auth(v_member);
  v_result := public.register_event_seat(p_event_id => v_old_event_id);
  if v_result->>'status' <> 'submitted'
     or (v_result->>'requires_payment')::boolean is not true then
    raise exception 'FAIL: paid seat fixture was not held undeclared: %', v_result;
  end if;

  perform 1
  from public.event_participants
  where event_id = v_old_event_id
    and user_id = v_member
    and payment_status = 'pending'
    and payment_declared_at is null;
  if not found then
    raise exception 'FAIL: fixture lacks member pending undeclared seat';
  end if;

  -- Move the registered occurrence into history only after taking the seat;
  -- ended-event insertion guards remain exercised rather than bypassed.
  perform pg_temp.set_auth(v_owner);
  update public.events
  set start_date = now() - interval '2 hours',
      end_date = now() - interval '1 hour'
  where id = v_old_event_id;

  -- The following published occurrence belongs to the same template and must
  -- be hidden from this member until the old transfer is declared.
  insert into public.events
    (creator_id, workspace_id, name, location, description, start_date,
     end_date, max_participants, total_price, price_per_person, template_id,
     payment_method_id, payment_method_ids, published_at)
  values
    (v_owner, v_workspace_id, 'الموعد التالي المحجوب', '', '',
     now() + interval '6 days', now() + interval '6 days 90 minutes',
     12, 120, 10, v_template_id, v_method_id, array[v_method_id], now())
  returning id into v_next_event_id;

  perform public.publish_recurring_event_internal(v_next_event_id, v_owner);
  select count(*) into v_count
  from public.event_member_responses
  where event_id = v_next_event_id and user_id = v_member;
  if v_count <> 0 then
    raise exception 'FAIL: generator invited a member before the old declaration';
  end if;
  select count(*) into v_count
  from public.push_outbox
  where event_id = v_next_event_id and user_id = v_member;
  if v_count <> 0 then
    raise exception 'FAIL: generator notified a member before the old declaration';
  end if;

  perform 1
  from public.events
  where id = v_next_event_id
    and template_id = v_template_id
    and published_at is not null;
  if not found then
    raise exception 'FAIL: next occurrence fixture is not published on the gated template';
  end if;

  insert into public.event_waitlist (event_id, user_id)
  values (v_next_event_id, v_waiter);

  -- A series edit replaces the template row. The stable series identity must
  -- preserve the old debt gate across that replacement.
  v_result := public.update_event_with_scope(
    p_event_id => v_next_event_id,
    p_scope => 'series_template',
    p_name => 'الموعد التالي بعد تعديل السلسلة',
    p_location => '',
    p_start_date => now() + interval '6 days',
    p_end_date => now() + interval '6 days 90 minutes',
    p_max_participants => 12,
    p_total_price => 120,
    p_latitude => null,
    p_longitude => null,
    p_payment_method_ids => array[v_method_id]
  );
  v_next_template_id := (v_result->'template'->>'id')::uuid;

  perform 1
  from public.event_templates old_template
  join public.event_templates next_template
    on next_template.series_key = old_template.series_key
  join public.events next_event
    on next_event.template_id = next_template.id
  where old_template.id = v_template_id
    and next_template.id = v_next_template_id
    and next_event.id = v_next_event_id;
  if not found then
    raise exception 'FAIL: series edit broke the stable recurring identity';
  end if;

  v_result := public.enable_recurrence(v_old_event_id);
  if (v_result->>'id')::uuid <> v_next_template_id then
    raise exception 'FAIL: historical recurrence resurrected an old template: %', v_result;
  end if;
  select count(*) into v_count
  from public.event_templates active_template
  where active_template.series_key = (
      select series_key
      from public.event_templates
      where id = v_template_id
    )
    and active_template.ended_at is null;
  if v_count <> 1 then
    raise exception 'FAIL: one series has multiple active templates: %', v_count;
  end if;

  -- A different recurring template in the same workspace must remain visible;
  -- the debt gate is per template, not per workspace.
  v_other_event := public.create_event(
    p_creator_id => v_owner,
    p_workspace_id => v_workspace_id,
    p_name => 'موعد قالب آخر',
    p_start_date => now() + interval '2 days',
    p_end_date => now() + interval '2 days 60 minutes',
    p_max_participants => 12,
    p_recurrence => 'weekly'
  );
  v_other_event_id := (v_other_event->>'id')::uuid;
  v_other_template_id := (v_other_event->>'template_id')::uuid;
  v_result := public.publish_event(v_other_event_id);

  if v_other_template_id = v_template_id then
    raise exception 'FAIL: other-template fixture reused the gated template';
  end if;

  perform pg_temp.set_auth(v_member);
  v_live := public.get_workspace_events(v_workspace_id);

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_old_event_id
    and (item->>'requires_payment_action')::boolean is true;
  if v_count <> 1 then
    raise exception 'FAIL: live feed did not retain old debt card: %', v_live;
  end if;

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_next_event_id;
  if v_count <> 0 then
    raise exception 'FAIL: live feed exposed next occurrence before declaration: %', v_live;
  end if;

  v_failed := false;
  begin
    v_result := public.register_event_seat(p_event_id => v_next_event_id);
  exception when others then
    v_failed := sqlerrm = 'Previous event payment is required';
  end;
  if not v_failed then
    raise exception 'FAIL: direct registration bypassed the recurring debt gate';
  end if;

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_other_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: debt blocked an unrelated recurring template: %', v_live;
  end if;

  -- Ending the occurrence freezes attendance responses, but must not freeze the
  -- one action retained by the debt card: declaring the transfer.
  v_failed := false;
  begin
    v_result := public.decline_event(v_old_event_id, 'other', 'انتهى الموعد');
  exception when others then
    v_failed := sqlerrm = 'Event has ended';
  end;
  if not v_failed then
    raise exception 'FAIL: member declined an ended occurrence';
  end if;

  v_failed := false;
  begin
    v_result := public.leave_event(v_old_event_id, v_member);
  exception when others then
    v_failed := sqlerrm = 'Event has ended';
  end;
  if not v_failed then
    raise exception 'FAIL: member left an ended occurrence';
  end if;

  perform 1
  from public.event_participants
  where event_id = v_old_event_id
    and user_id = v_member
    and payment_status = 'pending'
    and payment_declared_at is null;
  if not found then
    raise exception 'FAIL: rejected ended action mutated the debt row';
  end if;

  v_result := public.declare_event_payment(v_old_event_id, v_method_id);
  if v_result->>'status' <> 'declared'
     or (v_result->>'seats')::integer <> 1 then
    raise exception 'FAIL: ended occurrence refused payment declaration: %', v_result;
  end if;

  perform 1
  from public.event_participants
  where event_id = v_old_event_id
    and user_id = v_member
    and payment_status = 'pending'
    and payment_declared_at is not null;
  if not found then
    raise exception 'FAIL: declaration did not stamp the ended debt row';
  end if;

  select count(*) into v_count
  from public.event_member_responses
  where event_id = v_next_event_id
    and user_id = v_member
    and status = 'invited';
  if v_count <> 1 then
    raise exception 'FAIL: declaration did not create the delayed next invite';
  end if;

  select count(*) into v_count
  from public.push_outbox
  where event_id = v_next_event_id
    and user_id = v_member
    and type = 'event_invited';
  if v_count <> 1 then
    raise exception 'FAIL: declaration did not enqueue the delayed next invite';
  end if;

  v_result := public.register_event_seat(p_event_id => v_next_event_id);
  if v_result->>'status' <> 'submitted' then
    raise exception 'FAIL: declared member could not reserve next occurrence: %', v_result;
  end if;
  perform 1
  from public.event_participants
  where event_id = v_next_event_id
    and user_id = v_member;
  if not found then
    raise exception 'FAIL: next-occurrence seat fixture was not created';
  end if;

  -- A rejected transfer after the event ended must reopen the debt, not erase
  -- the historical participant row or leave the next occurrence unlocked. A
  -- seat obtained during the declaration window is revoked with it.
  perform pg_temp.set_auth(v_owner);
  v_result := public.reject_payment(v_old_event_id, v_member, v_owner);
  if v_result->>'status' <> 'rejected'
     or (v_result->>'revoked_future_seats')::integer <> 1 then
    raise exception 'FAIL: organizer could not reject ended declaration: %', v_result;
  end if;

  perform pg_temp.set_auth(v_member);
  perform 1
  from public.event_participants
  where event_id = v_old_event_id
    and user_id = v_member
    and payment_status = 'pending'
    and payment_declared_at is null;
  if not found then
    raise exception 'FAIL: ended rejection deleted or settled the debt row';
  end if;
  perform 1
  from public.event_participants
  where event_id = v_next_event_id
    and (user_id = v_member or added_by = v_member);
  if found then
    raise exception 'FAIL: rejected old transfer retained a future seat';
  end if;
  select count(*) into v_count
  from public.push_outbox
  where event_id = v_next_event_id
    and user_id = v_waiter
    and type = 'seat_available';
  if v_count <> 1 then
    raise exception 'FAIL: future waitlist was not notified of the reopened seat';
  end if;

  v_live := public.get_workspace_events(v_workspace_id);
  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_old_event_id
    and (item->>'requires_payment_action')::boolean is true;
  if v_count <> 1 then
    raise exception 'FAIL: rejected declaration did not restore the debt card: %', v_live;
  end if;
  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_next_event_id;
  if v_count <> 0 then
    raise exception 'FAIL: rejected declaration left the next occurrence open: %', v_live;
  end if;

  v_result := public.declare_event_payment(v_old_event_id, v_method_id);
  if v_result->>'status' <> 'declared' then
    raise exception 'FAIL: rejected debt could not be declared again: %', v_result;
  end if;

  select count(*) into v_count
  from public.event_member_responses
  where event_id = v_next_event_id
    and user_id = v_member
    and status = 'invited';
  if v_count <> 1 then
    raise exception 'FAIL: repeated declaration duplicated/lost delayed invite';
  end if;
  select count(*) into v_count
  from public.push_outbox
  where event_id = v_next_event_id
    and user_id = v_member
    and type = 'event_invited';
  if v_count <> 1 then
    raise exception 'FAIL: repeated declaration duplicated/lost delayed push';
  end if;

  v_live := public.get_workspace_events(v_workspace_id);

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_old_event_id;
  if v_count <> 0 then
    raise exception 'FAIL: declared old occurrence remained in live feed: %', v_live;
  end if;

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_next_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: declaration did not release the next occurrence: %', v_live;
  end if;

  select count(*) into v_count
  from json_array_elements(v_live) item
  where (item->>'id')::uuid = v_other_event_id;
  if v_count <> 1 then
    raise exception 'FAIL: other template disappeared after declaration: %', v_live;
  end if;

  v_past := public.get_workspace_past_events(
    v_workspace_id,
    now(),
    60,
    0
  );

  select count(*) into v_count
  from json_array_elements(v_past) item
  where (item->>'id')::uuid = v_old_event_id
    and (item->>'requires_payment_action')::boolean is false;
  if v_count <> 1 then
    raise exception 'FAIL: history lacks settled old occurrence: %', v_past;
  end if;
end;
$$;

select 'ALL RECURRING PAYMENT GATE TESTS PASSED' as result;

rollback;
