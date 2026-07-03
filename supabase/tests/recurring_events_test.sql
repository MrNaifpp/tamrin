-- Recurring workouts (F1) test suite. Run against the LOCAL stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/recurring_events_test.sql
-- Everything runs in one transaction and rolls back.

begin;

-- Impersonation helper: makes auth.uid() return the given uuid.
create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

-- Fixture users (local auth schema accepts direct inserts as postgres).
insert into auth.users (id, email) values
  ('10000000-0000-0000-0000-000000000001', 'creator@test.local'),
  ('10000000-0000-0000-0000-000000000002', 'member@test.local'),
  ('10000000-0000-0000-0000-000000000003', 'outsider@test.local');
insert into public.users (user_id, name) values
  ('10000000-0000-0000-0000-000000000001', 'المنظّم'),
  ('10000000-0000-0000-0000-000000000002', 'عضو'),
  ('10000000-0000-0000-0000-000000000003', 'غريب');

-- ============================================================
-- Section 1: event_templates table + RLS + template_id set-null
-- ============================================================
do $$
declare
  w_id uuid; t_id uuid; e_id uuid; visible int;
begin
  insert into public.workspaces (name, owner_id)
  values ('مساحة القوالب', '10000000-0000-0000-0000-000000000001')
  returning id into w_id;
  insert into public.workspace_members (workspace_id, user_id) values
    (w_id, '10000000-0000-0000-0000-000000000001'),
    (w_id, '10000000-0000-0000-0000-000000000002');

  insert into public.event_templates
    (workspace_id, creator_id, name, recurrence, next_occurrence_at)
  values
    (w_id, '10000000-0000-0000-0000-000000000001', 'تمرين الأربعاء', 'weekly', now() + interval '9 days')
  returning id into t_id;

  -- lead_days defaults to 3
  perform 1 from public.event_templates where id = t_id and lead_days = 3;
  if not found then raise exception 'FAIL: lead_days default is not 3'; end if;

  -- recurrence check constraint: weekly only in v1
  begin
    insert into public.event_templates (workspace_id, creator_id, name, recurrence, next_occurrence_at)
    values (w_id, '10000000-0000-0000-0000-000000000001', 'x', 'biweekly', now());
    raise exception 'FAIL: biweekly recurrence should be rejected';
  exception when check_violation then null;
  end;

  -- RLS: member sees the template, outsider does not
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  set local role authenticated;
  select count(*) into visible from public.event_templates where id = t_id;
  if visible <> 1 then raise exception 'FAIL: member cannot select template'; end if;
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000003');
  set local role authenticated;
  select count(*) into visible from public.event_templates where id = t_id;
  if visible <> 0 then raise exception 'FAIL: outsider can select template'; end if;
  reset role;

  -- deleting the template keeps events (template_id goes null)
  insert into public.events (creator_id, workspace_id, name, start_date, template_id)
  values ('10000000-0000-0000-0000-000000000001', w_id, 'من قالب', now() + interval '2 days', t_id)
  returning id into e_id;
  delete from public.event_templates where id = t_id;
  perform 1 from public.events where id = e_id and template_id is null;
  if not found then raise exception 'FAIL: deleting template should null template_id and keep the event'; end if;
end $$;

-- ============================================================
-- Section 2: create_event with p_recurrence
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; t_id uuid; tpl public.event_templates; cnt int;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة الإنشاء المتكرر');
  w_id := (w->>'id')::uuid;

  -- weekly: template inserted + first event stamped, atomically
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'تمرين متكرر',
    p_location => 'ملعب الحي',
    p_start_date => now() + interval '5 days',
    p_end_date => now() + interval '5 days' + interval '90 minutes',
    p_total_price => 200,
    p_price_per_person => 20,
    p_max_participants => 10,
    p_recurrence => 'weekly'
  );
  t_id := (ev->>'template_id')::uuid;
  if t_id is null then raise exception 'FAIL: weekly create_event did not stamp template_id'; end if;

  select * into tpl from public.event_templates where id = t_id;
  if tpl.id is null then raise exception 'FAIL: template row missing'; end if;
  if tpl.recurrence <> 'weekly' then raise exception 'FAIL: template recurrence %', tpl.recurrence; end if;
  if tpl.duration_minutes <> 90 then raise exception 'FAIL: duration_minutes expected 90, got %', tpl.duration_minutes; end if;
  if abs(extract(epoch from (tpl.next_occurrence_at - ((ev->>'start_date')::timestamptz + interval '7 days')))) > 1 then
    raise exception 'FAIL: next_occurrence_at is not start + 7 days';
  end if;

  -- 'none': no template
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'مرة واحدة',
    p_start_date => now() + interval '3 days',
    p_recurrence => 'none'
  );
  if (ev->>'template_id') is not null then raise exception 'FAIL: none recurrence stamped a template'; end if;
  select count(*) into cnt from public.event_templates where workspace_id = w_id;
  if cnt <> 1 then raise exception 'FAIL: expected exactly 1 template, got %', cnt; end if;

  -- invalid recurrence rejected
  begin
    ev := public.create_event(
      p_creator_id => '10000000-0000-0000-0000-000000000001',
      p_workspace_id => w_id,
      p_name => 'خطأ',
      p_start_date => now() + interval '3 days',
      p_recurrence => 'biweekly'
    );
    raise exception 'FAIL: invalid recurrence accepted';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;
end $$;

-- ============================================================
-- Section 3: series RPCs (get / skip / end)
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; e_id uuid; t_id uuid; r json; g_id uuid;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التحكم بالسلسلة');
  w_id := (w->>'id')::uuid;
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'سلسلة',
    p_start_date => now() + interval '2 days',
    p_end_date => now() + interval '2 days' + interval '1 hour',
    p_recurrence => 'weekly'
  );
  e_id := (ev->>'id')::uuid;
  t_id := (ev->>'template_id')::uuid;

  -- get_event_template: creator (member) reads it
  r := public.get_event_template(t_id);
  if (r->>'id')::uuid <> t_id then raise exception 'FAIL: get_event_template'; end if;

  -- outsider rejected
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000003');
  begin
    r := public.get_event_template(t_id);
    raise exception 'FAIL: outsider read template';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- plain member (not creator) cannot skip
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  r := public.join_workspace((select invite_code from public.workspaces where id = w_id));
  begin
    r := public.skip_next_occurrence(t_id, e_id);
    raise exception 'FAIL: non-creator skipped';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- creator skips from the upcoming first event: nothing generated yet -> skipped
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  r := public.skip_next_occurrence(t_id, e_id);
  if r->>'status' <> 'skipped' then raise exception 'FAIL: skip status %', r->>'status'; end if;
  perform 1 from public.event_templates where id = t_id and skip_next;
  if not found then raise exception 'FAIL: skip_next flag not set'; end if;

  -- a generated future occurrence exists -> already_open + its id
  update public.event_templates set skip_next = false where id = t_id;
  insert into public.events (creator_id, workspace_id, name, start_date, template_id)
  values ('10000000-0000-0000-0000-000000000001', w_id, 'مولّد', now() + interval '9 days', t_id)
  returning id into g_id;
  r := public.skip_next_occurrence(t_id, e_id);
  if r->>'status' <> 'already_open' then raise exception 'FAIL: expected already_open, got %', r->>'status'; end if;
  if (r->>'event_id')::uuid <> g_id then raise exception 'FAIL: already_open returned wrong event'; end if;

  -- end_recurrence: non-creator rejected
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  begin
    r := public.end_recurrence(t_id);
    raise exception 'FAIL: non-creator ended series';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- creator ends; existing events untouched
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  r := public.end_recurrence(t_id);
  if r->>'status' <> 'ended' then raise exception 'FAIL: end_recurrence status %', r->>'status'; end if;
  perform 1 from public.event_templates where id = t_id and ended_at is not null;
  if not found then raise exception 'FAIL: ended_at not set'; end if;
  perform 1 from public.events where id = g_id;
  if not found then raise exception 'FAIL: ending series deleted an event'; end if;
end $$;

-- ============================================================
-- Section 4: generator — creates one event, copies fields,
-- auto-joins creator, pushes members only, idempotent
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; t_id uuid; r json;
  cnt int; g public.events; v_next timestamptz;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التوليد');
  w_id := (w->>'id')::uuid;
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  r := public.join_workspace((select invite_code from public.workspaces where id = w_id));
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');

  -- first event already played: next occurrence = start + 7d = now() + 2 days,
  -- which is inside the 3-day lead window.
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'تمرين الأربعاء',
    p_location => 'ملعب الحي',
    p_start_date => now() - interval '5 days',
    p_end_date => now() - interval '5 days' + interval '90 minutes',
    p_total_price => 200,
    p_price_per_person => 20,
    p_max_participants => 10,
    p_recurrence => 'weekly'
  );
  t_id := (ev->>'template_id')::uuid;
  select next_occurrence_at into v_next from public.event_templates where id = t_id;

  -- run 1: exactly one new event
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 1 then raise exception 'FAIL: generator run 1 created % events', cnt; end if;

  select * into g from public.events
    where template_id = t_id and id <> (ev->>'id')::uuid;

  -- fields copied
  if g.name <> 'تمرين الأربعاء' or g.location <> 'ملعب الحي' or g.total_price <> 200
     or g.max_participants <> 10 or g.workspace_id <> w_id
     or g.creator_id <> '10000000-0000-0000-0000-000000000001' then
    raise exception 'FAIL: generated event fields not copied';
  end if;
  if abs(extract(epoch from (g.start_date - v_next))) > 1 then
    raise exception 'FAIL: generated start_date != next_occurrence_at';
  end if;
  if g.end_date is null or abs(extract(epoch from (g.end_date - (g.start_date + interval '90 minutes')))) > 1 then
    raise exception 'FAIL: generated end_date != start + duration';
  end if;

  -- creator auto-joined
  select count(*) into cnt from public.event_participants
    where event_id = g.id and user_id = '10000000-0000-0000-0000-000000000001';
  if cnt <> 1 then raise exception 'FAIL: creator not auto-joined'; end if;

  -- one event_opened push, member only, never the creator
  select count(*) into cnt from public.push_outbox where event_id = g.id and type = 'event_opened';
  if cnt <> 1 then raise exception 'FAIL: expected 1 event_opened outbox row, got %', cnt; end if;
  select count(*) into cnt from public.push_outbox
    where event_id = g.id and user_id = '10000000-0000-0000-0000-000000000001';
  if cnt <> 0 then raise exception 'FAIL: creator received event_opened push'; end if;

  -- next_occurrence_at advanced exactly one interval
  perform 1 from public.event_templates where id = t_id
    and abs(extract(epoch from (next_occurrence_at - (v_next + interval '7 days')))) < 1;
  if not found then raise exception 'FAIL: next_occurrence_at not advanced by 7 days'; end if;

  -- run 2: idempotent (next occurrence now outside the lead window)
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 1 then raise exception 'FAIL: generator not idempotent — % events after run 2', cnt; end if;
end $$;

-- ============================================================
-- Section 5: skip consumption, ended templates, catch-up
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; t_id uuid; cnt int; v_next timestamptz;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التخطي والإنهاء');
  w_id := (w->>'id')::uuid;

  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'سيُتخطى',
    p_start_date => now() - interval '5 days',
    p_recurrence => 'weekly'
  );
  t_id := (ev->>'template_id')::uuid;

  -- skip consumption: flag set + inside window -> no event, flag reset, date advanced
  update public.event_templates set skip_next = true where id = t_id;
  select next_occurrence_at into v_next from public.event_templates where id = t_id;
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 0 then raise exception 'FAIL: skip still generated an event'; end if;
  perform 1 from public.event_templates where id = t_id
    and not skip_next
    and abs(extract(epoch from (next_occurrence_at - (v_next + interval '7 days')))) < 1;
  if not found then raise exception 'FAIL: skip not consumed correctly'; end if;

  -- ended template: generator ignores it even inside the window
  update public.event_templates
    set ended_at = now(), next_occurrence_at = now() + interval '1 day'
    where id = t_id;
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt <> 0 then raise exception 'FAIL: ended template generated an event'; end if;

  -- catch-up: a far-behind template creates at most one event and lands in the future
  update public.event_templates
    set ended_at = null, skip_next = false, next_occurrence_at = now() - interval '20 days'
    where id = t_id;
  perform public.generate_recurring_events();
  select count(*) into cnt from public.events where template_id = t_id and id <> (ev->>'id')::uuid;
  if cnt > 1 then raise exception 'FAIL: catch-up burst-created % events', cnt; end if;
  perform 1 from public.event_templates where id = t_id and next_occurrence_at > now();
  if not found then raise exception 'FAIL: catch-up left next_occurrence_at in the past'; end if;
end $$;

-- ============================================================
-- Section 6: enable_recurrence — enable from settings, no-op when
-- already recurring, reactivation after end, creator-only
-- ============================================================
do $$
declare
  w json; w_id uuid; ev json; e_id uuid; t_id uuid; r json; cnt int;
  arr json; flag boolean;
begin
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  w := public.create_workspace('مساحة التفعيل اللاحق');
  w_id := (w->>'id')::uuid;
  ev := public.create_event(
    p_creator_id => '10000000-0000-0000-0000-000000000001',
    p_workspace_id => w_id,
    p_name => 'بدون تكرار',
    p_start_date => now() + interval '4 days',
    p_end_date => now() + interval '4 days' + interval '2 hours',
    p_recurrence => 'none'
  );
  e_id := (ev->>'id')::uuid;

  -- non-creator cannot enable
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000002');
  r := public.join_workspace((select invite_code from public.workspaces where id = w_id));
  begin
    r := public.enable_recurrence(e_id);
    raise exception 'FAIL: non-creator enabled recurrence';
  exception when others then
    if sqlerrm like 'FAIL:%' then raise; end if;
  end;

  -- creator enables: template created + event stamped, fields derived
  perform pg_temp.set_auth('10000000-0000-0000-0000-000000000001');
  r := public.enable_recurrence(e_id);
  t_id := (r->>'id')::uuid;
  if t_id is null then raise exception 'FAIL: enable_recurrence returned no template'; end if;
  perform 1 from public.events where id = e_id and template_id = t_id;
  if not found then raise exception 'FAIL: enable_recurrence did not stamp template_id'; end if;
  if (r->>'duration_minutes')::int <> 120 then
    raise exception 'FAIL: enable duration_minutes expected 120, got %', r->>'duration_minutes';
  end if;
  if abs(extract(epoch from ((r->>'next_occurrence_at')::timestamptz - ((ev->>'start_date')::timestamptz + interval '7 days')))) > 1 then
    raise exception 'FAIL: enable next_occurrence_at is not start + 7 days';
  end if;

  -- enabling again is a no-op returning the same template
  r := public.enable_recurrence(e_id);
  if (r->>'id')::uuid <> t_id then raise exception 'FAIL: re-enable created a second template'; end if;
  select count(*) into cnt from public.event_templates where workspace_id = w_id;
  if cnt <> 1 then raise exception 'FAIL: expected 1 template after re-enable, got %', cnt; end if;

  -- end then re-enable reactivates the same template
  r := public.end_recurrence(t_id);
  r := public.enable_recurrence(e_id);
  if (r->>'id')::uuid <> t_id then raise exception 'FAIL: reactivation created a new template'; end if;
  if (r->>'ended_at') is not null then raise exception 'FAIL: reactivated template still ended'; end if;

  -- feed flag: is_recurring true while the series is live...
  arr := public.get_workspace_events(w_id);
  select bool_or((x->>'is_recurring')::boolean) into flag
    from json_array_elements(arr) x
    where (x->>'id')::uuid = e_id;
  if flag is distinct from true then
    raise exception 'FAIL: is_recurring should be true for a live series';
  end if;

  -- ...and false once the series ends, even though template_id stays
  r := public.end_recurrence(t_id);
  arr := public.get_workspace_events(w_id);
  select bool_or((x->>'is_recurring')::boolean) into flag
    from json_array_elements(arr) x
    where (x->>'id')::uuid = e_id;
  if flag is distinct from false then
    raise exception 'FAIL: is_recurring should be false after ending the series';
  end if;
  perform 1 from public.events where id = e_id and template_id = t_id;
  if not found then raise exception 'FAIL: ending the series should keep template_id on the event'; end if;
end $$;

-- ============================================================
-- Section 7: cron job registered
-- ============================================================
do $$
declare cnt int;
begin
  select count(*) into cnt from cron.job where jobname = 'recurring-events';
  if cnt <> 1 then raise exception 'FAIL: recurring-events cron job not scheduled'; end if;
end $$;

select 'ALL RECURRING EVENT TESTS PASSED' as result;
rollback;
