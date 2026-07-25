-- Event publication/invitation/decline/cancellation tests. Local stack only:
--   supabase db reset
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
--     -v ON_ERROR_STOP=1 -f supabase/tests/event_lifecycle_test.sql

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
  ('20000000-0000-0000-0000-000000000001', 'lifecycle-owner@test.local'),
  ('20000000-0000-0000-0000-000000000002', 'lifecycle-member-a@test.local'),
  ('20000000-0000-0000-0000-000000000003', 'lifecycle-member-b@test.local'),
  ('20000000-0000-0000-0000-000000000004', 'lifecycle-outsider@test.local');

insert into public.users (user_id, name) values
  ('20000000-0000-0000-0000-000000000001', 'المنظّم'),
  ('20000000-0000-0000-0000-000000000002', 'عضو أ'),
  ('20000000-0000-0000-0000-000000000003', 'عضو ب'),
  ('20000000-0000-0000-0000-000000000004', 'غريب');

do $$
declare
  v_workspace json;
  v_workspace_id uuid;
  v_other_workspace json;
  v_other_workspace_id uuid;
  v_event json;
  v_event_id uuid;
  v_opened_event json;
  v_opened_event_id uuid;
  v_recurring_event json;
  v_recurring_event_id uuid;
  v_recurring_template_id uuid;
  v_atomic_event json;
  v_atomic_event_id uuid;
  v_old_template_id uuid;
  v_new_template_id uuid;
  v_legacy_event_id uuid;
  v_result json;
  v_feed json;
  v_count int;
  v_value text;
  v_failed boolean;
begin
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');
  v_workspace := public.create_workspace('مجموعة دورة حياة التمرين');
  v_workspace_id := (v_workspace->>'id')::uuid;

  insert into public.workspace_members (workspace_id, user_id) values
    (v_workspace_id, '20000000-0000-0000-0000-000000000002'),
    (v_workspace_id, '20000000-0000-0000-0000-000000000003');

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000004');
  v_other_workspace := public.create_workspace('مساحة الغريب');
  v_other_workspace_id := (v_other_workspace->>'id')::uuid;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');

  if to_regprocedure(
    'public.create_event(uuid,text,text,text,timestamptz,timestamptz,text,integer)'
  ) is not null then
    raise exception 'FAIL: legacy 8-argument create_event still exists';
  end if;

  -- Membership alone never grants organizer capabilities.
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  v_failed := false;
  begin
    v_result := public.create_event(
      p_creator_id => '20000000-0000-0000-0000-000000000002',
      p_workspace_id => v_workspace_id,
      p_name => 'إنشاء عضو مرفوض',
      p_start_date => now() + interval '1 day'
    );
  exception when others then
    v_failed := sqlerrm = 'Only the workspace owner can create events';
  end;
  if not v_failed then raise exception 'FAIL: member created an event'; end if;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');

  v_event := public.create_event(
    p_creator_id => '20000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين دورة الحياة',
    p_start_date => now() + interval '2 hours',
    p_end_date => now() + interval '3 hours',
    p_max_participants => 12,
    p_recurrence => 'none'
  );
  v_event_id := (v_event->>'id')::uuid;

  -- An occurrence never changes workspace, even when its creator owns the row.
  v_failed := false;
  begin
    update public.events
    set workspace_id = v_other_workspace_id
    where id = v_event_id;
  exception when others then
    v_failed := sqlerrm = 'An event cannot be moved to another workspace';
  end;
  if not v_failed then raise exception 'FAIL: event workspace was mutable'; end if;
  perform 1 from public.events
  where id = v_event_id and workspace_id = v_workspace_id;
  if not found then raise exception 'FAIL: failed workspace move changed the event'; end if;

  -- Newly composed events are creator-visible drafts until explicit publish.
  perform 1 from public.events
  where id = v_event_id and published_at is null;
  if not found then raise exception 'FAIL: create_event did not create a draft'; end if;

  select json_array_length(public.get_workspace_events(v_workspace_id)) into v_count;
  if v_count <> 1 then raise exception 'FAIL: creator cannot see own draft'; end if;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  select json_array_length(public.get_workspace_events(v_workspace_id)) into v_count;
  if v_count <> 0 then raise exception 'FAIL: member saw an unpublished draft'; end if;

  v_failed := false;
  begin
    v_result := public.get_event_participants(v_event_id);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: member read draft participants'; end if;

  v_failed := false;
  begin
    v_result := public.get_event_payment_destination(v_event_id);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: member read draft payment destination'; end if;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v_failed := false;
  begin
    v_result := public.get_event_by_id(v_event_id);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: anonymous user read a draft'; end if;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');

  v_result := public.publish_event(v_event_id);
  if v_result->>'status' <> 'published'
     or (v_result->>'new_invite_count')::int <> 2
     or (v_result->>'notification_count')::int <> 2 then
    raise exception 'FAIL: first publish result %', v_result;
  end if;

  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  v_result := public.get_event_by_id(v_event_id);
  if (v_result->>'id')::uuid <> v_event_id
     or v_result->>'my_response_status' is not null then
    raise exception 'FAIL: anonymous published-link response %', v_result;
  end if;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');

  -- Direct table paths cannot bypass workspace membership on a public event.
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000004');
  v_failed := false;
  begin
    insert into public.event_participants (event_id, user_id)
    values (v_event_id, '20000000-0000-0000-0000-000000000004');
  exception when others then
    v_failed := sqlerrm = 'Not a workspace member';
  end;
  if not v_failed then raise exception 'FAIL: outsider directly joined participants'; end if;

  v_failed := false;
  begin
    insert into public.event_waitlist (event_id, user_id)
    values (v_event_id, '20000000-0000-0000-0000-000000000004');
  exception when others then
    v_failed := sqlerrm = 'Not a workspace member';
  end;
  if not v_failed then raise exception 'FAIL: outsider directly joined waitlist'; end if;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');

  select count(*) into v_count
  from public.event_member_responses
  where event_id = v_event_id and status = 'invited';
  if v_count <> 2 then raise exception 'FAIL: expected 2 invitations, got %', v_count; end if;

  -- Invitations never reserve seats: only the auto-joined creator exists.
  select count(*) into v_count from public.event_participants where event_id = v_event_id;
  if v_count <> 1 then raise exception 'FAIL: invitation reserved a seat'; end if;

  select count(*) into v_count from public.push_outbox
  where event_id = v_event_id and type = 'event_invited';
  if v_count <> 2 then raise exception 'FAIL: expected 2 invite pushes, got %', v_count; end if;

  v_result := public.publish_event(v_event_id);
  if (v_result->>'new_invite_count')::int <> 0
     or (v_result->>'notification_count')::int <> 0 then
    raise exception 'FAIL: repeated publish was not idempotent: %', v_result;
  end if;

  -- Atomic edit: a series edit rebuilds the active template in the same
  -- transaction and preserves draft/published state; occurrence-only leaves
  -- the current template untouched.
  v_atomic_event := public.create_event(
    p_creator_id => '20000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين ذري',
    p_location => 'الموقع القديم',
    p_start_date => now() + interval '4 days',
    p_end_date => now() + interval '4 days 1 hour',
    p_max_participants => 10,
    p_recurrence => 'weekly'
  );
  v_atomic_event_id := (v_atomic_event->>'id')::uuid;
  v_old_template_id := (v_atomic_event->>'template_id')::uuid;

  v_result := public.update_event_with_scope(
    p_event_id => v_atomic_event_id,
    p_scope => 'series_template',
    p_name => 'تمرين ذري معدل',
    p_location => 'الموقع الجديد',
    p_start_date => now() + interval '5 days',
    p_end_date => now() + interval '5 days 90 minutes',
    p_max_participants => 12,
    p_total_price => 0,
    p_latitude => null,
    p_longitude => null,
    p_payment_method_ids => '{}'::uuid[]
  );
  v_new_template_id := (v_result->'template'->>'id')::uuid;
  perform 1
  from public.events e
  join public.event_templates new_t on new_t.id = e.template_id
  join public.event_templates old_t on old_t.id = v_old_template_id
  where e.id = v_atomic_event_id
    and e.name = 'تمرين ذري معدل'
    and e.published_at is null
    and new_t.id = v_new_template_id
    and new_t.published_at is null
    and new_t.creator_id = '20000000-0000-0000-0000-000000000001'
    and old_t.ended_at is not null;
  if not found then raise exception 'FAIL: atomic draft series rebuild'; end if;

  v_result := public.publish_event(v_atomic_event_id);
  v_old_template_id := v_new_template_id;
  v_result := public.update_event_with_scope(
    p_event_id => v_atomic_event_id,
    p_scope => 'series_template',
    p_name => 'تمرين ذري منشور',
    p_location => 'الموقع المنشور',
    p_start_date => now() + interval '6 days',
    p_end_date => now() + interval '6 days 2 hours',
    p_max_participants => 14,
    p_total_price => 0,
    p_latitude => 24.7,
    p_longitude => 46.7,
    p_payment_method_ids => '{}'::uuid[]
  );
  v_new_template_id := (v_result->'template'->>'id')::uuid;
  perform 1
  from public.events e
  join public.event_templates new_t on new_t.id = e.template_id
  join public.event_templates old_t on old_t.id = v_old_template_id
  where e.id = v_atomic_event_id
    and e.published_at is not null
    and new_t.id = v_new_template_id
    and new_t.published_at is not null
    and old_t.ended_at is not null;
  if not found then raise exception 'FAIL: atomic published state was not preserved'; end if;

  v_old_template_id := v_new_template_id;
  v_result := public.update_event_with_scope(
    p_event_id => v_atomic_event_id,
    p_scope => 'occurrence_only',
    p_name => 'تعديل occurrence فقط',
    p_location => 'نفس السلسلة',
    p_start_date => now() + interval '6 days',
    p_end_date => now() + interval '6 days 2 hours',
    p_max_participants => 14,
    p_total_price => 0,
    p_latitude => null,
    p_longitude => null,
    p_payment_method_ids => '{}'::uuid[]
  );
  perform 1 from public.events
  where id = v_atomic_event_id and template_id = v_old_template_id;
  if not found then raise exception 'FAIL: occurrence edit replaced the template'; end if;

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  v_failed := false;
  begin
    v_result := public.update_event_with_scope(
      v_atomic_event_id, 'occurrence_only', 'تعديل عضو', '',
      now() + interval '6 days', now() + interval '6 days 2 hours',
      14, 0, null, null, '{}'::uuid[]
    );
  exception when others then
    v_failed := sqlerrm = 'Only the workspace owner can edit events';
  end;
  if not v_failed then raise exception 'FAIL: member edited an event'; end if;

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');
  v_result := public.end_recurrence(v_old_template_id);
  select name into v_value from public.events where id = v_atomic_event_id;
  v_failed := false;
  begin
    v_result := public.update_event_with_scope(
      v_atomic_event_id, 'series_template', 'يجب التراجع', '',
      now() + interval '7 days', now() + interval '7 days 1 hour',
      14, 0, null, null, '{}'::uuid[]
    );
  exception when others then
    v_failed := sqlerrm = 'Active recurrence template is required for series_template';
  end;
  if not v_failed then raise exception 'FAIL: rebuilt a missing/ended series'; end if;
  perform 1 from public.events
  where id = v_atomic_event_id and name = v_value and template_id = v_old_template_id;
  if not found then raise exception 'FAIL: failed series edit was not atomic'; end if;

  select name into v_value from public.events where id = v_event_id;
  v_failed := false;
  begin
    v_result := public.update_event_with_scope(
      v_event_id, 'series_template', 'لا قالب لهذا الحدث', '',
      now() + interval '2 hours', now() + interval '3 hours',
      12, 0, null, null, '{}'::uuid[]
    );
  exception when others then
    v_failed := sqlerrm = 'Active recurrence template is required for series_template';
  end;
  if not v_failed then raise exception 'FAIL: rebuilt a missing series'; end if;
  perform 1 from public.events where id = v_event_id and name = v_value;
  if not found then raise exception 'FAIL: missing-template edit was not atomic'; end if;

  -- An existing automatic event_opened notification becomes an invitation
  -- response and suppresses event_invited for that same user/event.
  v_opened_event := public.create_event(
    p_creator_id => '20000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين مولّد',
    p_start_date => now() + interval '2 days',
    p_recurrence => 'none'
  );
  v_opened_event_id := (v_opened_event->>'id')::uuid;

  update public.events set published_at = now() where id = v_opened_event_id;

  insert into public.push_outbox (user_id, type, event_id)
  values ('20000000-0000-0000-0000-000000000002', 'event_opened', v_opened_event_id);

  v_result := public.publish_event(v_opened_event_id);
  if (v_result->>'new_invite_count')::int <> 1
     or (v_result->>'invited_count')::int <> 2
     or (v_result->>'notification_count')::int <> 1 then
    raise exception 'FAIL: event_opened dedupe result %', v_result;
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_opened_event_id
    and user_id = '20000000-0000-0000-0000-000000000002'
    and type = 'event_invited';
  if v_count <> 0 then raise exception 'FAIL: duplicate availability push was inserted'; end if;

  -- Legacy rows may name a regular member as creator, but organizer authority
  -- belongs only to the current workspace owner.
  insert into public.events
    (creator_id, workspace_id, name, start_date, end_date, published_at)
  values
    ('20000000-0000-0000-0000-000000000002', v_workspace_id,
     'تمرين منشئه عضو قديم', now() + interval '2 days',
     now() + interval '2 days 1 hour', null)
  returning id into v_legacy_event_id;
  insert into public.event_participants (event_id, user_id)
  values (v_legacy_event_id, '20000000-0000-0000-0000-000000000002');

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  v_failed := false;
  begin
    perform public.publish_event(v_legacy_event_id);
  exception when others then
    v_failed := sqlerrm = 'Only the workspace owner can publish events';
  end;
  if not v_failed then raise exception 'FAIL: legacy member creator published event'; end if;

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');
  v_result := public.publish_event(v_legacy_event_id);
  if (v_result->>'new_invite_count')::int <> 1 then
    raise exception 'FAIL: owner did not publish legacy event %', v_result;
  end if;

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  v_failed := false;
  begin
    perform public.cancel_event_occurrence(v_legacy_event_id, null, null);
  exception when others then
    v_failed := sqlerrm = 'Only the workspace owner can cancel events';
  end;
  if not v_failed then raise exception 'FAIL: legacy member creator cancelled event'; end if;

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');
  v_result := public.cancel_event_occurrence(v_legacy_event_id, 'legacy', null);
  if v_result->>'status' <> 'cancelled' then
    raise exception 'FAIL: owner could not cancel legacy event';
  end if;

  -- A real registration clears invited state. Declining removes the caller and
  -- every guest they added, removes waitlist state, then stores the reason.
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  perform public.join_event(v_event_id, '20000000-0000-0000-0000-000000000002');
  perform 1 from public.event_member_responses
  where event_id = v_event_id and user_id = '20000000-0000-0000-0000-000000000002';
  if found then raise exception 'FAIL: joining did not clear the invitation'; end if;

  insert into public.event_participants
    (event_id, user_id, guest_name, added_by, payment_status)
  values
    (v_event_id, null, 'ضيف العضو', '20000000-0000-0000-0000-000000000002', 'confirmed');
  perform public.join_waitlist(v_event_id, '20000000-0000-0000-0000-000000000002');

  v_result := public.decline_event(v_event_id, 'busy', 'عندي ارتباط عائلي');
  if v_result->>'status' <> 'declined'
     or (v_result->>'removed_participant_rows')::int <> 2
     or (v_result->>'removed_waitlist_rows')::int <> 1 then
    raise exception 'FAIL: decline result %', v_result;
  end if;

  select count(*) into v_count from public.event_participants
  where event_id = v_event_id
    and (user_id = '20000000-0000-0000-0000-000000000002'
      or added_by = '20000000-0000-0000-0000-000000000002');
  if v_count <> 0 then raise exception 'FAIL: decline left participant rows'; end if;
  select count(*) into v_count from public.event_waitlist
  where event_id = v_event_id
    and user_id = '20000000-0000-0000-0000-000000000002';
  if v_count <> 0 then raise exception 'FAIL: decline left waitlist row'; end if;

  select reason_code into v_value from public.event_member_responses
  where event_id = v_event_id
    and user_id = '20000000-0000-0000-0000-000000000002'
    and status = 'declined'
    and reason_text = 'عندي ارتباط عائلي';
  if v_value <> 'busy' then raise exception 'FAIL: decline reason was not stored'; end if;

  v_feed := public.get_workspace_events(v_workspace_id);
  select item->>'my_response_status' into v_value
  from json_array_elements(v_feed) item
  where (item->>'id')::uuid = v_event_id;
  if v_value <> 'declined' then
    raise exception 'FAIL: feed my_response_status %, expected declined', v_value;
  end if;

  -- A regular member reads only their own response; the creator reads all.
  select json_array_length(public.get_event_member_responses(v_event_id)) into v_count;
  if v_count <> 1 then raise exception 'FAIL: member response privacy count %', v_count; end if;
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');
  select json_array_length(public.get_event_member_responses(v_event_id)) into v_count;
  if v_count <> 2 then raise exception 'FAIL: creator response count %', v_count; end if;

  -- Only the event creator may cancel the current visible occurrence.
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  v_failed := false;
  begin
    perform public.cancel_event_occurrence(v_event_id, 'weather', null);
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: non-creator cancelled the event'; end if;

  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000001');
  v_result := public.cancel_event_occurrence(v_event_id, 'weather', 'الملعب غير متاح');
  if v_result->>'status' <> 'cancelled'
     or (v_result->>'notification_count')::int <> 2 then
    raise exception 'FAIL: cancellation result %', v_result;
  end if;
  perform 1 from public.events
  where id = v_event_id
    and cancelled_at is not null
    and registration_locked
    and cancellation_reason_code = 'weather'
    and cancellation_reason_text = 'الملعب غير متاح';
  if not found then raise exception 'FAIL: cancellation fields were not stored'; end if;

  select count(*) into v_count from public.push_outbox
  where event_id = v_event_id and type = 'event_cancelled';
  if v_count <> 2 then raise exception 'FAIL: expected 2 cancellation pushes, got %', v_count; end if;
  v_result := public.cancel_event_occurrence(v_event_id, 'weather', 'ignored retry');
  if v_result->>'status' <> 'already_cancelled' then
    raise exception 'FAIL: cancellation retry was not idempotent';
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_event_id and type = 'event_cancelled';
  if v_count <> 2 then raise exception 'FAIL: cancellation retry duplicated pushes'; end if;

  -- Cancelling an unsent weekly occurrence publishes the cancelled row for
  -- members and activates its template so later weekly drafts still generate.
  v_recurring_event := public.create_event(
    p_creator_id => '20000000-0000-0000-0000-000000000001',
    p_workspace_id => v_workspace_id,
    p_name => 'تمرين أسبوعي سيلغى',
    p_start_date => now() + interval '3 days',
    p_end_date => now() + interval '3 days 1 hour',
    p_recurrence => 'weekly'
  );
  v_recurring_event_id := (v_recurring_event->>'id')::uuid;
  v_recurring_template_id := (v_recurring_event->>'template_id')::uuid;
  perform 1
  from public.events e
  join public.event_templates t on t.id = e.template_id
  where e.id = v_recurring_event_id
    and e.published_at is null
    and t.published_at is null;
  if not found then raise exception 'FAIL: recurring event was not an unsent draft'; end if;

  v_result := public.cancel_event_occurrence(
    v_recurring_event_id,
    'organizer_unavailable',
    null
  );
  perform 1
  from public.events e
  join public.event_templates t on t.id = e.template_id
  where e.id = v_recurring_event_id
    and e.cancelled_at is not null
    and e.published_at is not null
    and t.id = v_recurring_template_id
    and t.published_at is not null
    and t.ended_at is null;
  if not found then
    raise exception 'FAIL: cancelling a recurring draft did not keep future weeks active';
  end if;
  select count(*) into v_count from public.push_outbox
  where event_id = v_recurring_event_id and type = 'event_cancelled';
  if v_count <> 2 then raise exception 'FAIL: recurring draft cancellation pushes %', v_count; end if;

  -- Cancelled events stay in the upcoming feed and never receive reminders.
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000003');
  v_feed := public.get_workspace_events(v_workspace_id);
  select item->>'is_cancelled' into v_value
  from json_array_elements(v_feed) item
  where (item->>'id')::uuid = v_event_id;
  if v_value <> 'true' then raise exception 'FAIL: cancelled event disappeared from feed'; end if;

  v_failed := false;
  begin
    perform public.join_event(v_event_id, '20000000-0000-0000-0000-000000000003');
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: joined a cancelled event'; end if;

  perform public.enqueue_event_reminders();
  select count(*) into v_count from public.push_outbox
  where event_id = v_event_id and type = 'event_reminder';
  if v_count <> 0 then raise exception 'FAIL: cancelled event enqueued a reminder'; end if;

  -- Legacy delete_event can no longer be spoofed with the creator id.
  perform pg_temp.set_auth('20000000-0000-0000-0000-000000000002');
  v_failed := false;
  begin
    perform public.delete_event(v_opened_event_id, '20000000-0000-0000-0000-000000000001');
  exception when others then
    v_failed := true;
  end;
  if not v_failed then raise exception 'FAIL: spoofed delete_event succeeded'; end if;
end $$;

rollback;
