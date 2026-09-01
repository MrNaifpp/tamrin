-- Atomic exercise-template editor tests. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/update_exercise_template_test.sql

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
  ('51000000-0000-4000-8000-000000000001', 'exercise-template-owner@test.local'),
  ('51000000-0000-4000-8000-000000000002', 'exercise-template-member@test.local'),
  ('51000000-0000-4000-8000-000000000003', 'exercise-template-other-owner@test.local');

insert into public.users (user_id, name) values
  ('51000000-0000-4000-8000-000000000001', 'مشرف التمرين'),
  ('51000000-0000-4000-8000-000000000002', 'عضو التمرين'),
  ('51000000-0000-4000-8000-000000000003', 'مشرف تمرين آخر');

do $$
declare
  v_owner constant uuid := '51000000-0000-4000-8000-000000000001';
  v_member constant uuid := '51000000-0000-4000-8000-000000000002';
  v_other_owner constant uuid := '51000000-0000-4000-8000-000000000003';
  v_workspace json;
  v_workspace_id uuid;
  v_other_workspace json;
  v_other_workspace_id uuid;
  v_event json;
  v_event_id uuid;
  v_old_template_id uuid;
  v_new_template_id uuid;
  v_other_event json;
  v_other_event_id uuid;
  v_result json;
  v_method_id uuid;
  v_new_start timestamptz := now() + interval '5 days';
  v_new_end timestamptz := now() + interval '5 days 90 minutes';
  v_stable_workspace_name text;
  v_stable_symbol text;
  v_stable_event_name text;
  v_stable_template_name text;
  v_failed boolean;
begin
  -- Main recurring exercise and a real non-owner member.
  perform pg_temp.set_auth(v_owner);
  v_workspace := public.create_workspace('تمرين كرة القدم', 'figure.soccer');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id)
  values (v_workspace_id, v_member);

  v_event := public.create_event(
    p_creator_id => v_owner,
    p_workspace_id => v_workspace_id,
    p_name => 'الموعد القديم',
    p_location => 'الملعب القديم',
    p_start_date => now() + interval '4 days',
    p_end_date => now() + interval '4 days 1 hour',
    p_max_participants => 12,
    p_total_price => 180,
    p_recurrence => 'weekly'
  );
  v_event_id := (v_event->>'id')::uuid;
  v_old_template_id := (v_event->>'template_id')::uuid;

  -- The owner changes the workspace identity and all occurrence/template
  -- fields through one call. Workspace and event names are deliberately
  -- different to prove the RPC does not conflate the two parameters.
  v_result := public.update_exercise_template(
    p_workspace_id => v_workspace_id,
    p_event_id => v_event_id,
    p_scope => 'series_template',
    p_workspace_name => 'تمارين الكرة الطائرة',
    p_symbol => 'figure.volleyball',
    p_name => 'موعد الطائرة الأسبوعي',
    p_location => 'صالة الطائرة',
    p_start_date => v_new_start,
    p_end_date => v_new_end,
    p_max_participants => 18,
    p_total_price => 0,
    p_latitude => 24.7136,
    p_longitude => 46.6753,
    p_payment_methods => '[{"provider":"cash"}]'::jsonb,
    p_existing_payment_method_ids => '{}'::uuid[]
  );

  if (v_result->'workspace'->>'id')::uuid <> v_workspace_id
     or v_result->'workspace'->>'name' <> 'تمارين الكرة الطائرة'
     or v_result->'workspace'->>'symbol' <> 'figure.volleyball'
     or (v_result->'workspace'->>'member_count')::int <> 2 then
    raise exception 'FAIL: RPC returned stale workspace identity: %', v_result;
  end if;
  v_method_id := (v_result->'payment_methods'->0->>'id')::uuid;
  if v_method_id is null
     or (v_result->'event'->>'id')::uuid <> v_event_id then
    raise exception 'FAIL: RPC omitted authoritative event/payment rows: %', v_result;
  end if;

  select template_id into v_new_template_id
  from public.events
  where id = v_event_id;

  if v_new_template_id is null or v_new_template_id = v_old_template_id then
    raise exception 'FAIL: series edit did not replace the active template';
  end if;

  perform 1
  from public.workspaces w
  join public.events e on e.workspace_id = w.id
  join public.event_templates t on t.id = e.template_id
  where w.id = v_workspace_id
    and w.name = 'تمارين الكرة الطائرة'
    and w.symbol = 'figure.volleyball'
    and e.id = v_event_id
    and e.name = 'موعد الطائرة الأسبوعي'
    and e.location = 'صالة الطائرة'
    and e.start_date = v_new_start
    and e.end_date = v_new_end
    and e.max_participants = 18
    and e.total_price = 180
    and e.payment_method_ids = array[v_method_id]
    and e.latitude = 24.7136
    and e.longitude = 46.6753
    and t.name = 'موعد الطائرة الأسبوعي'
    and t.location = 'صالة الطائرة'
    and t.max_participants = 18
    and t.total_price = 180
    and t.payment_method_ids = array[v_method_id]
    and t.latitude = 24.7136
    and t.longitude = 46.6753
    and t.duration_minutes = 90
    and t.ended_at is null;
  if not found then
    raise exception 'FAIL: owner edit did not atomically update workspace/event/template';
  end if;

  perform 1
  from public.event_templates
  where id = v_old_template_id and ended_at is not null;
  if not found then
    raise exception 'FAIL: replaced template was not ended';
  end if;

  -- A workspace member is not an organizer. Neither half may change.
  perform pg_temp.set_auth(v_member);
  v_failed := false;
  begin
    perform public.update_exercise_template(
      v_workspace_id,
      v_event_id,
      'series_template',
      'اختراق العضو',
      'figure.run',
      'موعد اخترقه العضو',
      'موقع خاطئ',
      v_new_start + interval '1 day',
      v_new_end + interval '1 day',
      10,
      0,
      null,
      null,
      '[]'::jsonb,
      '{}'::uuid[]
    );
    raise exception 'FAIL: non-owner edited the exercise template';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_failed := sqlerrm = 'Only the workspace owner can edit the exercise template';
  end;
  if not v_failed then
    raise exception 'FAIL: non-owner rejection contract changed';
  end if;

  perform 1
  from public.workspaces w
  join public.events e on e.id = v_event_id
  where w.id = v_workspace_id
    and w.name = 'تمارين الكرة الطائرة'
    and w.symbol = 'figure.volleyball'
    and e.name = 'موعد الطائرة الأسبوعي';
  if not found then
    raise exception 'FAIL: rejected member call changed workspace or event';
  end if;

  -- The caller owns the requested workspace, but the supplied event belongs to
  -- another one. This must fail before either workspace or event is mutated.
  perform pg_temp.set_auth(v_other_owner);
  v_other_workspace := public.create_workspace('تمرين مستقل', 'figure.basketball');
  v_other_workspace_id := (v_other_workspace->>'id')::uuid;
  v_other_event := public.create_event(
    p_creator_id => v_other_owner,
    p_workspace_id => v_other_workspace_id,
    p_name => 'موعد المجموعة الأخرى',
    p_location => 'الصالة الأخرى',
    p_start_date => now() + interval '3 days',
    p_end_date => now() + interval '3 days 1 hour',
    p_max_participants => 10,
    p_total_price => 0,
    p_recurrence => 'none'
  );
  v_other_event_id := (v_other_event->>'id')::uuid;

  perform pg_temp.set_auth(v_owner);
  v_failed := false;
  begin
    perform public.update_exercise_template(
      v_workspace_id,
      v_other_event_id,
      'occurrence_only',
      'اسم لا يجب حفظه',
      'figure.run',
      'حدث لا ينتمي للمجموعة',
      '',
      now() + interval '6 days',
      now() + interval '6 days 1 hour',
      8,
      0,
      null,
      null,
      '[]'::jsonb,
      '{}'::uuid[]
    );
    raise exception 'FAIL: cross-workspace event was accepted';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_failed := sqlerrm = 'Event does not belong to workspace';
  end;
  if not v_failed then
    raise exception 'FAIL: cross-workspace rejection contract changed';
  end if;

  perform 1
  from public.workspaces main_workspace
  join public.events other_event on other_event.id = v_other_event_id
  where main_workspace.id = v_workspace_id
    and main_workspace.name = 'تمارين الكرة الطائرة'
    and main_workspace.symbol = 'figure.volleyball'
    and other_event.workspace_id = v_other_workspace_id
    and other_event.name = 'موعد المجموعة الأخرى';
  if not found then
    raise exception 'FAIL: cross-workspace rejection mutated data';
  end if;

  -- An inner event/template validation failure must roll back the freshly
  -- inserted payment destination as well as the workspace/event/template.
  select name, symbol
  into v_stable_workspace_name, v_stable_symbol
  from public.workspaces
  where id = v_workspace_id;
  select name, template_id
  into v_stable_event_name, v_new_template_id
  from public.events
  where id = v_event_id;
  select name into v_stable_template_name
  from public.event_templates
  where id = v_new_template_id;

  v_failed := false;
  begin
    perform public.update_exercise_template(
      p_workspace_id => v_workspace_id,
      p_event_id => v_event_id,
      p_scope => 'series_template',
      p_workspace_name => 'اسم يجب التراجع عنه',
      p_symbol => 'figure.run',
      p_name => 'موعد يجب التراجع عنه',
      p_location => 'موقع يجب التراجع عنه',
      p_start_date => v_new_start + interval '2 days',
      p_end_date => v_new_start + interval '1 day 30 minutes',
      p_max_participants => 18,
      p_total_price => 180,
      p_latitude => null,
      p_longitude => null,
      p_payment_methods => '[{"provider":"stc_bank","mobile_number":"0501234567"}]'::jsonb,
      p_existing_payment_method_ids => '{}'::uuid[]
    );
    raise exception 'FAIL: invalid paid edit unexpectedly succeeded';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
    v_failed := sqlerrm = 'Event end must be after its start';
  end;
  if not v_failed then
    raise exception 'FAIL: inner update failure contract changed';
  end if;

  perform 1
  from public.workspaces w
  join public.events e on e.id = v_event_id
  join public.event_templates t on t.id = e.template_id
  where w.id = v_workspace_id
    and w.name = v_stable_workspace_name
    and w.symbol = v_stable_symbol
    and e.name = v_stable_event_name
    and e.template_id = v_new_template_id
    and t.name = v_stable_template_name
    and t.ended_at is null;
  if not found then
    raise exception 'FAIL: inner update failure was not atomic';
  end if;

  perform 1
  from public.workspace_payment_methods
  where workspace_id = v_workspace_id
    and provider = 'stc_bank'
    and mobile_number = '+966501234567';
  if found then
    raise exception 'FAIL: payment method insert survived the failed template edit';
  end if;

  raise notice 'PASS: update_exercise_template owner/auth/scope/rollback';
end;
$$;

rollback;
