-- Waiver tests. Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/waive_expired_event_debts_test.sql
--
-- The deadline is measured from start_date, so a long session and a short one
-- give the member the same day to settle.

begin;

insert into auth.users (id, email) values
  ('61000000-0000-0000-0000-000000000001', 'waive-owner@test.local'),
  ('61000000-0000-0000-0000-000000000002', 'waive-late@test.local'),
  ('61000000-0000-0000-0000-000000000003', 'waive-declared@test.local'),
  ('61000000-0000-0000-0000-000000000004', 'waive-guest-host@test.local');

insert into public.workspaces (id, name, owner_id)
values ('61000000-0000-0000-0000-0000000000a1', 'Waiver WS',
        '61000000-0000-0000-0000-000000000001');

insert into public.workspace_members (workspace_id, user_id)
values ('61000000-0000-0000-0000-0000000000a1', '61000000-0000-0000-0000-000000000002'),
       ('61000000-0000-0000-0000-0000000000a1', '61000000-0000-0000-0000-000000000003'),
       ('61000000-0000-0000-0000-0000000000a1', '61000000-0000-0000-0000-000000000004');

-- guard_event_registration_insert() refuses a seat on an exercise that has
-- ended, so every event below is created in the future, filled, and only then
-- moved into the past — the same order recurring_payment_gate_test.sql uses.
insert into public.events
  (id, creator_id, workspace_id, name, start_date, end_date, published_at)
values ('61000000-0000-0000-0000-0000000000b1',
        '61000000-0000-0000-0000-000000000001',
        '61000000-0000-0000-0000-0000000000a1',
        'Expired', now() + interval '1 day', now() + interval '1 day 2 hours', now()),
       ('61000000-0000-0000-0000-0000000000b2',
        '61000000-0000-0000-0000-000000000001',
        '61000000-0000-0000-0000-0000000000a1',
        'Fresh', now() + interval '1 day', now() + interval '1 day 2 hours', now()),
       ('61000000-0000-0000-0000-0000000000b3',
        '61000000-0000-0000-0000-000000000001',
        '61000000-0000-0000-0000-0000000000a1',
        'Cancelled', now() + interval '1 day', now() + interval '1 day 2 hours', now());

insert into public.event_participants (event_id, user_id, payment_status, payment_declared_at)
values
  -- expired + never declared: waived
  ('61000000-0000-0000-0000-0000000000b1', '61000000-0000-0000-0000-000000000002', 'pending', null),
  -- expired but declared: untouched
  ('61000000-0000-0000-0000-0000000000b1', '61000000-0000-0000-0000-000000000003', 'pending', now()),
  -- inside the window: untouched
  ('61000000-0000-0000-0000-0000000000b2', '61000000-0000-0000-0000-000000000002', 'pending', null),
  -- cancelled exercise: untouched
  ('61000000-0000-0000-0000-0000000000b3', '61000000-0000-0000-0000-000000000002', 'pending', null);

-- A guest carries no user_id; the member who brought them owes for the seat,
-- so the guest row has to waive on the same deadline.
insert into public.event_participants
  (event_id, user_id, added_by, guest_name, payment_status, payment_declared_at)
values ('61000000-0000-0000-0000-0000000000b1', null,
        '61000000-0000-0000-0000-000000000004', 'Guest', 'pending', null);

-- Now move them into the past, which is the state under test.
update public.events
set start_date = now() - interval '25 hours',
    end_date = now() - interval '23 hours'
where id = '61000000-0000-0000-0000-0000000000b1';

update public.events
set start_date = now() - interval '2 hours',
    end_date = now() - interval '1 hour'
where id = '61000000-0000-0000-0000-0000000000b2';

update public.events
set start_date = now() - interval '30 hours',
    end_date = now() - interval '28 hours',
    cancelled_at = now() - interval '31 hours'
where id = '61000000-0000-0000-0000-0000000000b3';

do $$
declare
  v_waived integer;
begin
  v_waived := public.waive_expired_event_debts();

  -- The member's own seat and the guest seat they brought.
  if v_waived <> 2 then
    raise exception 'expected 2 waived rows, got %', v_waived;
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b1'
        and user_id = '61000000-0000-0000-0000-000000000002') <> 'waived' then
    raise exception 'an undeclared debt past the deadline must be waived';
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b1'
        and added_by = '61000000-0000-0000-0000-000000000004'
        and user_id is null) <> 'waived' then
    raise exception 'a guest seat past the deadline must be waived too';
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b1'
        and user_id = '61000000-0000-0000-0000-000000000003') <> 'pending' then
    raise exception 'a declared payment must never be waived';
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b2'
        and user_id = '61000000-0000-0000-0000-000000000002') <> 'pending' then
    raise exception 'a debt inside the 24h window must not be waived yet';
  end if;

  if (select payment_status from public.event_participants
      where event_id = '61000000-0000-0000-0000-0000000000b3'
        and user_id = '61000000-0000-0000-0000-000000000002') <> 'pending' then
    raise exception 'a cancelled exercise must not be waived';
  end if;

  -- Idempotence: a second run has nothing left to move.
  v_waived := public.waive_expired_event_debts();
  if v_waived <> 0 then
    raise exception 'second run must waive nothing, waived %', v_waived;
  end if;
end;
$$;

rollback;
