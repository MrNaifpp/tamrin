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

select 'ALL RECURRING EVENT TESTS PASSED' as result;
rollback;
