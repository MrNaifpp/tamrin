-- Event-capacity notification tests. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/event_capacity_notifications_test.sql

begin;

create or replace function pg_temp.assert_true(
  p_condition boolean,
  p_message text
)
returns void
language plpgsql
as $$
begin
  if not coalesce(p_condition, false) then
    raise exception 'FAIL: %', p_message;
  end if;
end;
$$;

create or replace function pg_temp.assert_capacity_wave(
  p_event_id uuid,
  p_workspace_id uuid,
  p_registered_count int,
  p_remaining_count int,
  p_capacity int,
  p_type text,
  p_expected_event_pushes int,
  p_label text
)
returns void
language plpgsql
as $$
declare
  v_count int;
  v_member_count int;
begin
  select count(*)::int
  into v_member_count
  from public.workspace_members
  where workspace_id = p_workspace_id;

  select count(*)::int
  into v_count
  from public.push_outbox
  where event_id = p_event_id
    and type in ('event_capacity_progress', 'event_capacity_full');

  if v_count <> p_expected_event_pushes then
    raise exception 'FAIL: % has % total capacity pushes, expected %',
      p_label, v_count, p_expected_event_pushes;
  end if;

  select count(*)::int
  into v_count
  from public.push_outbox
  where event_id = p_event_id
    and type = p_type
    and metadata = jsonb_build_object(
      'registered_count', p_registered_count,
      'remaining_count', p_remaining_count,
      'capacity', p_capacity
    );

  if v_count <> v_member_count then
    raise exception 'FAIL: % wave has % rows, expected one for each of % members',
      p_label, v_count, v_member_count;
  end if;

  if exists (
    select wm.user_id
    from public.workspace_members wm
    where wm.workspace_id = p_workspace_id
    except
    select po.user_id
    from public.push_outbox po
    where po.event_id = p_event_id
      and po.type = p_type
      and po.metadata = jsonb_build_object(
        'registered_count', p_registered_count,
        'remaining_count', p_remaining_count,
        'capacity', p_capacity
      )
  ) then
    raise exception 'FAIL: % omitted a workspace member', p_label;
  end if;

  if exists (
    select po.user_id
    from public.push_outbox po
    where po.event_id = p_event_id
      and po.type = p_type
      and po.metadata = jsonb_build_object(
        'registered_count', p_registered_count,
        'remaining_count', p_remaining_count,
        'capacity', p_capacity
      )
    except
    select wm.user_id
    from public.workspace_members wm
    where wm.workspace_id = p_workspace_id
  ) then
    raise exception 'FAIL: % included a non-member recipient', p_label;
  end if;

  select count(distinct user_id)::int
  into v_count
  from public.push_outbox
  where event_id = p_event_id
    and type = p_type
    and metadata = jsonb_build_object(
      'registered_count', p_registered_count,
      'remaining_count', p_remaining_count,
      'capacity', p_capacity
    );

  if v_count <> v_member_count then
    raise exception 'FAIL: % duplicated a recipient', p_label;
  end if;
end;
$$;

-- The batching contract depends on the evaluator running only when the
-- inserting transaction is made consistent, not once per row mid-statement.
select pg_temp.assert_true(
  exists (
    select 1
    from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = 'event_participants'
      and t.tgname = 'trg_event_capacity_notifications'
      and not t.tgisinternal
      and t.tgconstraint <> 0
      and t.tgdeferrable
      and t.tginitdeferred
  ),
  'capacity trigger is not an initially-deferred constraint trigger'
);

insert into auth.users (id, email) values
  ('53000000-0000-0000-0000-000000000001', 'capacity-owner@test.local'),
  ('53000000-0000-0000-0000-000000000002', 'capacity-member-a@test.local'),
  ('53000000-0000-0000-0000-000000000003', 'capacity-member-b@test.local');

insert into public.users (user_id, name) values
  ('53000000-0000-0000-0000-000000000001', 'مشرف إشعارات السعة'),
  ('53000000-0000-0000-0000-000000000002', 'عضو السعة أ'),
  ('53000000-0000-0000-0000-000000000003', 'عضو السعة ب');

insert into public.workspaces (id, name, owner_id) values
  (
    '53000000-0000-0000-0000-000000000010',
    'مجموعة اختبار إشعارات السعة',
    '53000000-0000-0000-0000-000000000001'
  );

insert into public.workspace_members (workspace_id, user_id) values
  ('53000000-0000-0000-0000-000000000010', '53000000-0000-0000-0000-000000000001'),
  ('53000000-0000-0000-0000-000000000010', '53000000-0000-0000-0000-000000000002'),
  ('53000000-0000-0000-0000-000000000010', '53000000-0000-0000-0000-000000000003');

insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date,
   max_participants, published_at)
values
  (
    '53000000-0000-0000-0000-000000000100',
    '53000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000010',
    'عتبات السعة الأساسية',
    now() + interval '1 day',
    now() + interval '1 day 2 hours',
    16,
    now()
  ),
  (
    '53000000-0000-0000-0000-000000000200',
    '53000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000010',
    'قفزة دفعة السعة',
    now() + interval '2 days',
    now() + interval '2 days 2 hours',
    16,
    now()
  ),
  (
    '53000000-0000-0000-0000-000000000300',
    '53000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000010',
    'مسودة لا ترسل',
    now() + interval '3 days',
    now() + interval '3 days 2 hours',
    16,
    null
  ),
  (
    '53000000-0000-0000-0000-000000000400',
    '53000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000010',
    'موعد ملغي لا يرسل',
    now() + interval '4 days',
    now() + interval '4 days 2 hours',
    16,
    now()
  );

update public.events
set cancelled_at = now(),
    cancelled_by = '53000000-0000-0000-0000-000000000001',
    cancellation_reason_code = 'capacity_test',
    registration_locked = true
where id = '53000000-0000-0000-0000-000000000400';

-- 0 -> 3: below the first quarter, so neither the ledger nor outbox changes.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select '53000000-0000-0000-0000-000000000100',
       null,
       'main-' || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from generate_series(1, 3) n;
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_true(
  not exists (
    select 1 from public.event_capacity_notification_milestones
    where event_id = '53000000-0000-0000-0000-000000000100'
  ),
  'a milestone was claimed below 4/16'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from public.push_outbox
    where event_id = '53000000-0000-0000-0000-000000000100'
      and type in ('event_capacity_progress', 'event_capacity_full')
  ),
  'a capacity push was queued below 4/16'
);

-- 3 -> 4: quarter_1, delivered once to all three workspace members.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
values
  (
    '53000000-0000-0000-0000-000000000100', null, 'main-4',
    '53000000-0000-0000-0000-000000000001', 'confirmed'
  );
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_true(
  exists (
    select 1
    from public.event_capacity_notification_milestones
    where event_id = '53000000-0000-0000-0000-000000000100'
      and milestone_key = 'quarter_1'
      and milestone = 4
      and capacity = 16
      and milestone_kind = 'progress'
  ),
  'quarter_1=4 was not claimed'
);
select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  4, 12, 16, 'event_capacity_progress', 3, 'quarter_1'
);

-- Dropping below 4 and crossing it again must not emit quarter_1 twice.
delete from public.event_participants
where event_id = '53000000-0000-0000-0000-000000000100'
  and guest_name = 'main-4';

set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
values
  (
    '53000000-0000-0000-0000-000000000100', null, 'main-4-recross',
    '53000000-0000-0000-0000-000000000001', 'confirmed'
  );
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  4, 12, 16, 'event_capacity_progress', 3, 'quarter_1 recross'
);
select pg_temp.assert_true(
  (select count(*) = 1
   from public.event_capacity_notification_milestones
   where event_id = '53000000-0000-0000-0000-000000000100'
     and milestone_key = 'quarter_1'),
  'quarter_1 ledger claim was duplicated after recross'
);

-- 4 -> 8: quarter_2.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select '53000000-0000-0000-0000-000000000100',
       null,
       'main-' || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from generate_series(5, 8) n;
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  8, 8, 16, 'event_capacity_progress', 6, 'quarter_2'
);

-- 8 -> 12: quarter_3.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select '53000000-0000-0000-0000-000000000100',
       null,
       'main-' || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from generate_series(9, 12) n;
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  12, 4, 16, 'event_capacity_progress', 9, 'quarter_3'
);

-- 12 -> 15: near-full uses the progress push type.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select '53000000-0000-0000-0000-000000000100',
       null,
       'main-' || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from generate_series(13, 15) n;
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  15, 1, 16, 'event_capacity_progress', 12, 'near_full'
);

-- 15 -> 16: full has its own push type.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
values
  (
    '53000000-0000-0000-0000-000000000100', null, 'main-16',
    '53000000-0000-0000-0000-000000000001', 'confirmed'
  );
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  16, 0, 16, 'event_capacity_full', 15, 'full'
);

select pg_temp.assert_true(
  (select count(*) = 5
   from public.event_capacity_notification_milestones
   where event_id = '53000000-0000-0000-0000-000000000100'),
  'max=16 did not produce exactly five semantic ledger claims'
);
select pg_temp.assert_true(
  not exists (
    select expected.milestone_key, expected.milestone, expected.milestone_kind
    from (values
      ('quarter_1'::text, 4, 'progress'::text),
      ('quarter_2'::text, 8, 'progress'::text),
      ('quarter_3'::text, 12, 'progress'::text),
      ('near_full'::text, 15, 'near_full'::text),
      ('full'::text, 16, 'full'::text)
    ) expected(milestone_key, milestone, milestone_kind)
    except
    select actual.milestone_key, actual.milestone, actual.milestone_kind
    from public.event_capacity_notification_milestones actual
    where actual.event_id = '53000000-0000-0000-0000-000000000100'
  ),
  'max=16 semantic milestone values/kinds are incomplete'
);

-- Full is also once-only after decrement and re-increment.
delete from public.event_participants
where event_id = '53000000-0000-0000-0000-000000000100'
  and guest_name = 'main-16';

set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
values
  (
    '53000000-0000-0000-0000-000000000100', null, 'main-16-recross',
    '53000000-0000-0000-0000-000000000001', 'confirmed'
  );
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000100',
  '53000000-0000-0000-0000-000000000010',
  16, 0, 16, 'event_capacity_full', 15, 'full recross'
);

-- A single 0 -> 9 batch claims every crossed key but emits only the highest
-- newly crossed wave. Its copy reports the actual final count (9), not 8.
set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select '53000000-0000-0000-0000-000000000200',
       null,
       'batch-' || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from generate_series(1, 9) n;
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_true(
  (select count(*) = 2
   from public.event_capacity_notification_milestones
   where event_id = '53000000-0000-0000-0000-000000000200'),
  '0->9 batch did not claim exactly quarter_1 and quarter_2'
);
select pg_temp.assert_true(
  not exists (
    select expected.milestone_key, expected.milestone
    from (values
      ('quarter_1'::text, 4),
      ('quarter_2'::text, 8)
    ) expected(milestone_key, milestone)
    except
    select actual.milestone_key, actual.milestone
    from public.event_capacity_notification_milestones actual
    where actual.event_id = '53000000-0000-0000-0000-000000000200'
  ),
  '0->9 batch ledger keys/values are incomplete'
);
select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000200',
  '53000000-0000-0000-0000-000000000010',
  9, 7, 16, 'event_capacity_progress', 3, '0->9 batch'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from public.push_outbox
    where event_id = '53000000-0000-0000-0000-000000000200'
      and type in ('event_capacity_progress', 'event_capacity_full')
      and metadata->>'registered_count' = '4'
  ),
  '0->9 batch emitted the lower crossed quarter'
);

-- Re-crossing both already claimed batch thresholds emits nothing.
delete from public.event_participants
where event_id = '53000000-0000-0000-0000-000000000200'
  and guest_name in ('batch-8', 'batch-9');

set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
values
  (
    '53000000-0000-0000-0000-000000000200', null, 'batch-8-recross',
    '53000000-0000-0000-0000-000000000001', 'confirmed'
  ),
  (
    '53000000-0000-0000-0000-000000000200', null, 'batch-9-recross',
    '53000000-0000-0000-0000-000000000001', 'confirmed'
  );
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_capacity_wave(
  '53000000-0000-0000-0000-000000000200',
  '53000000-0000-0000-0000-000000000010',
  9, 7, 16, 'event_capacity_progress', 3, 'batch recross'
);
select pg_temp.assert_true(
  (select count(*) = 2
   from public.event_capacity_notification_milestones
   where event_id = '53000000-0000-0000-0000-000000000200'),
  'batch recross duplicated a ledger claim'
);

-- The normal registration guard quite correctly rejects draft/cancelled
-- inserts. Disable only that guard here so the capacity trigger's independent
-- defensive filtering is exercised directly.
alter table public.event_participants
  disable trigger trg_guard_event_participant_insert;

set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select event_id,
       null,
       prefix || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from (values
  ('53000000-0000-0000-0000-000000000300'::uuid, 'draft-'),
  ('53000000-0000-0000-0000-000000000400'::uuid, 'cancelled-')
) fixtures(event_id, prefix)
cross join generate_series(1, 4) n;
set constraints trg_event_capacity_notifications immediate;

alter table public.event_participants
  enable trigger trg_guard_event_participant_insert;

select pg_temp.assert_true(
  not exists (
    select 1
    from public.event_capacity_notification_milestones
    where event_id in (
      '53000000-0000-0000-0000-000000000300',
      '53000000-0000-0000-0000-000000000400'
    )
  ),
  'draft/cancelled events claimed a capacity milestone'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from public.push_outbox
    where event_id in (
      '53000000-0000-0000-0000-000000000300',
      '53000000-0000-0000-0000-000000000400'
    )
      and type in ('event_capacity_progress', 'event_capacity_full')
  ),
  'draft/cancelled events queued a capacity push'
);

-- Integration with the recurring-payment gate: capacity copy is actionable,
-- so a member whose earlier occurrence is still pending and undeclared must
-- not receive it for the hidden next occurrence. Other members still do.
insert into auth.users (id, email) values
  ('53000000-0000-0000-0000-000000000004', 'capacity-debtor@test.local');
insert into public.users (user_id, name) values
  ('53000000-0000-0000-0000-000000000004', 'عضو محجوب بدين سابق');
insert into public.workspace_members (workspace_id, user_id) values
  ('53000000-0000-0000-0000-000000000010', '53000000-0000-0000-0000-000000000004');

insert into public.event_templates
  (id, workspace_id, creator_id, name, recurrence, next_occurrence_at)
values
  (
    '53000000-0000-0000-0000-000000000500',
    '53000000-0000-0000-0000-000000000010',
    '53000000-0000-0000-0000-000000000001',
    'سلسلة بوابة الدفع والسعة',
    'weekly',
    now() + interval '19 days'
  );

insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date,
   max_participants, template_id, published_at)
values
  (
    '53000000-0000-0000-0000-000000000510',
    '53000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000010',
    'الموعد السابق غير المسدد',
    now() + interval '5 days',
    now() + interval '5 days 2 hours',
    null,
    '53000000-0000-0000-0000-000000000500',
    now()
  ),
  (
    '53000000-0000-0000-0000-000000000520',
    '53000000-0000-0000-0000-000000000001',
    '53000000-0000-0000-0000-000000000010',
    'الموعد التالي المحجوب',
    now() + interval '12 days',
    now() + interval '12 days 2 hours',
    16,
    '53000000-0000-0000-0000-000000000500',
    now()
  );

insert into public.event_participants
  (event_id, user_id, payment_status)
values
  (
    '53000000-0000-0000-0000-000000000510',
    '53000000-0000-0000-0000-000000000004',
    'pending'
  );

update public.events
set start_date = now() - interval '2 hours',
    end_date = now() - interval '1 hour'
where id = '53000000-0000-0000-0000-000000000510';

set constraints trg_event_capacity_notifications deferred;
insert into public.event_participants
  (event_id, user_id, guest_name, added_by, payment_status)
select '53000000-0000-0000-0000-000000000520',
       null,
       'gated-' || n::text,
       '53000000-0000-0000-0000-000000000001',
       'confirmed'
from generate_series(1, 4) n;
set constraints trg_event_capacity_notifications immediate;

select pg_temp.assert_true(
  (select count(*) = 3
   from public.push_outbox
   where event_id = '53000000-0000-0000-0000-000000000520'
     and type = 'event_capacity_progress'
     and metadata = jsonb_build_object(
       'registered_count', 4,
       'remaining_count', 12,
       'capacity', 16
     )),
  'debt-gated capacity wave did not reach exactly the three eligible members'
);
select pg_temp.assert_true(
  not exists (
    select 1
    from public.push_outbox
    where event_id = '53000000-0000-0000-0000-000000000520'
      and user_id = '53000000-0000-0000-0000-000000000004'
      and type in ('event_capacity_progress', 'event_capacity_full')
  ),
  'member with undeclared prior debt received actionable capacity copy'
);
select pg_temp.assert_true(
  not exists (
    select expected.user_id
    from (values
      ('53000000-0000-0000-0000-000000000001'::uuid),
      ('53000000-0000-0000-0000-000000000002'::uuid),
      ('53000000-0000-0000-0000-000000000003'::uuid)
    ) expected(user_id)
    except
    select po.user_id
    from public.push_outbox po
    where po.event_id = '53000000-0000-0000-0000-000000000520'
      and po.type = 'event_capacity_progress'
  ),
  'debt filter omitted an eligible workspace member'
);

select 'ALL EVENT CAPACITY NOTIFICATION TESTS PASSED' as result;

rollback;
