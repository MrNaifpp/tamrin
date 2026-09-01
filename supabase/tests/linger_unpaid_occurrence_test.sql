-- The day an unpaid exercise gets to itself. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/linger_unpaid_occurrence_test.sql
--
-- While an exercise is still owed for, it is the only one that member sees:
-- the finished card stays and the next occurrence is held back, so the debt is
-- asked about rather than buried under next week. Both end together, because
-- both are the same condition seen from two sides — the debt clears by being
-- declared, or by the waiver 24 hours after the old exercise started.
--
-- Nobody else is affected. A member who settled sees next week immediately.

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

insert into public.users (user_id, name) values
  ('63000000-0000-0000-0000-000000000001', 'مشرف'),
  ('63000000-0000-0000-0000-000000000002', 'عضو مدين'),
  ('63000000-0000-0000-0000-000000000003', 'عضو مسدد');

do $$
declare
  v_owner   constant uuid := '63000000-0000-0000-0000-000000000001';
  v_owes    constant uuid := '63000000-0000-0000-0000-000000000002';
  v_settled constant uuid := '63000000-0000-0000-0000-000000000003';
  v_ws uuid;
  v_method uuid;
  v_old uuid;
  v_template uuid;
  v_next uuid;
  v_result json;
  v_shows boolean;
begin
  perform pg_temp.set_auth(v_owner);
  v_ws := (public.create_workspace('مجموعة التمديد')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id)
  values (v_ws, v_owes), (v_ws, v_settled);
  v_method := (public.upsert_workspace_payment_method(v_ws, 'stc_bank', '0500000063')->>'id')::uuid;

  -- A paid weekly exercise, built in the future so seats can be taken: an
  -- ended exercise refuses every registration.
  v_result := public.create_event(
    p_creator_id => v_owner, p_workspace_id => v_ws,
    p_name => 'الأحد الماضي',
    p_start_date => now() + interval '1 day',
    p_end_date => now() + interval '1 day 2 hours',
    p_max_participants => 12, p_total_price => 120,
    p_recurrence => 'weekly',
    p_payment_method_id => v_method, p_payment_method_ids => array[v_method]
  );
  v_old := (v_result->>'id')::uuid;
  v_template := (v_result->>'template_id')::uuid;

  perform pg_temp.set_auth(v_owes);
  v_result := public.register_event_seat(p_event_id => v_old);

  perform pg_temp.set_auth(v_settled);
  v_result := public.register_event_seat(p_event_id => v_old);
  v_result := public.declare_event_payment(v_old, v_method);

  -- It finished two hours ago, and next week has opened.
  perform pg_temp.set_auth(v_owner);
  update public.events
  set start_date = now() - interval '4 hours', end_date = now() - interval '2 hours'
  where id = v_old;

  insert into public.events
    (creator_id, workspace_id, name, start_date, end_date, max_participants,
     total_price, price_per_person, template_id, payment_method_id,
     payment_method_ids, published_at)
  values
    (v_owner, v_ws, 'الأحد القادم', now() + interval '3 days',
     now() + interval '3 days 2 hours', 12, 120, 10, v_template, v_method,
     array[v_method], now())
  returning id into v_next;
  perform public.publish_recurring_event_internal(v_next, v_owner);

  -- ---------------------------------------------------------------------
  -- Inside the day: one card, and it is the one that is owed.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth(v_owes);

  select exists (
    select 1 from json_array_elements(public.get_workspace_events(v_ws)) i
    where (i->>'id')::uuid = v_old and (i->>'requires_payment_action')::boolean
  ) into v_shows;
  if not v_shows then
    raise exception 'FAIL: the owed card left the shelf inside the day';
  end if;

  select exists (
    select 1 from json_array_elements(public.get_workspace_events(v_ws)) i
    where (i->>'id')::uuid = v_next
  ) into v_shows;
  if v_shows then
    raise exception 'FAIL: next week showed while the old exercise was still owed';
  end if;

  -- A member who settled is not held at all.
  perform pg_temp.set_auth(v_settled);
  select exists (
    select 1 from json_array_elements(public.get_workspace_events(v_ws)) i
    where (i->>'id')::uuid = v_next
  ) into v_shows;
  if not v_shows then
    raise exception 'FAIL: a settled member was held back too';
  end if;
  select exists (
    select 1 from json_array_elements(public.get_workspace_events(v_ws)) i
    where (i->>'id')::uuid = v_old
  ) into v_shows;
  if v_shows then
    raise exception 'FAIL: a settled member still sees the finished card';
  end if;

  -- ---------------------------------------------------------------------
  -- The deadline passes and the cron waives. Both sides release together.
  -- ---------------------------------------------------------------------
  perform pg_temp.set_auth(v_owner);
  update public.events
  set start_date = now() - interval '25 hours', end_date = now() - interval '23 hours'
  where id = v_old;
  perform public.waive_expired_event_debts();

  if (select payment_status from public.event_participants
      where event_id = v_old and user_id = v_owes) <> 'waived' then
    raise exception 'FAIL: the debt did not expire at the deadline';
  end if;

  perform pg_temp.set_auth(v_owes);
  select exists (
    select 1 from json_array_elements(public.get_workspace_events(v_ws)) i
    where (i->>'id')::uuid = v_next
  ) into v_shows;
  if not v_shows then
    raise exception 'FAIL: next week stayed hidden after the debt expired';
  end if;

  select exists (
    select 1 from json_array_elements(public.get_workspace_events(v_ws)) i
    where (i->>'id')::uuid = v_old
  ) into v_shows;
  if v_shows then
    raise exception 'FAIL: the card outlived the debt that held it';
  end if;
end;
$$;

rollback;
