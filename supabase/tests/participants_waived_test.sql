-- A waived seat reaches clients as payment_status null, so app builds that
-- only know pending/confirmed/rejected still decode the roster.
-- Local stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/participants_waived_test.sql

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
  ('49000000-0000-0000-0000-000000000001', 'waived-o@test.local'),
  ('49000000-0000-0000-0000-000000000002', 'waived-a@test.local'),
  ('49000000-0000-0000-0000-000000000003', 'waived-b@test.local');

insert into public.users (user_id, name) values
  ('49000000-0000-0000-0000-000000000001', 'منظم'),
  ('49000000-0000-0000-0000-000000000002', 'فهد'),
  ('49000000-0000-0000-0000-000000000003', 'سالم');

do $$
declare
  O constant uuid := '49000000-0000-0000-0000-000000000001';
  A constant uuid := '49000000-0000-0000-0000-000000000002';
  B constant uuid := '49000000-0000-0000-0000-000000000003';
  v_workspace_id uuid;
  v_event_id uuid;
  v_roster json;
  v_statuses text[];
begin
  perform pg_temp.set_auth(O);
  v_workspace_id := (public.create_workspace('مجموعة قديمة')->>'id')::uuid;
  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, A), (v_workspace_id, B);
  v_event_id := (public.create_event(
    p_creator_id => O,
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين قديم',
    p_start_date => now() + interval '3 days',
    p_max_participants => 10
  )->>'id')::uuid;

  perform pg_temp.set_auth(A);
  perform public.register_event_seat(p_event_id => v_event_id);

  -- Three days ago, and A never paid: the waiver has run.
  update public.events
  set start_date = now() - interval '3 days',
      end_date = now() - interval '3 days' + interval '2 hours'
  where id = v_event_id;
  update public.event_participants
  set payment_status = 'waived', payment_declared_at = null
  where event_id = v_event_id and user_id = A;

  -- 1. Everyone is still on the list, for any member who opens it.
  perform pg_temp.set_auth(B);
  v_roster := public.get_event_participants(v_event_id);
  assert json_array_length(v_roster) = 2, 'both seats should be listed';

  -- 2. No client ever receives the word 'waived'.
  select array_agg(coalesce(p->>'payment_status', 'NULL') order by p->>'user_id')
  into v_statuses
  from json_array_elements(v_roster) p;
  assert not ('waived' = any(v_statuses)), 'waived must not reach clients';

  -- 3. The waived seat arrives as null, everything else untouched.
  assert (
    select p->>'payment_status'
    from json_array_elements(v_roster) p
    where (p->>'user_id')::uuid = A
  ) is null, 'the waived seat should arrive as null';
  assert exists (
    select 1
    from json_array_elements(v_roster) p
    where (p->>'user_id')::uuid = A and p::jsonb ? 'payment_status'
  ), 'payment_status stays present as a key';
  assert (
    select p->>'display_name'
    from json_array_elements(v_roster) p
    where (p->>'user_id')::uuid = A
  ) = 'فهد', 'other fields are unchanged';

  -- 4. The stored value is untouched: the server still knows it was waived.
  assert (
    select payment_status from public.event_participants
    where event_id = v_event_id and user_id = A
  ) = 'waived', 'the table keeps waived';

  -- 5. The order is kept: the organizer's own seat first, as before.
  assert ((v_roster->0)->>'user_id')::uuid = O, 'roster order is unchanged';

  raise notice 'participants_waived: PASSED';
end;
$$;

rollback;
