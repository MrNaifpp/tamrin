-- Freed seats go back to the queue again.
--
-- Two features landed on the same four functions from different branches. The
-- waitlist work made every seat-freeing path call drain_waitlist, so a seat
-- given up is handed to whoever waited longest inside the same transaction.
-- The rolling-recurring rewrite then reissued those functions from a branch
-- that predated it, and the call went with them: the queue simply stopped
-- moving, silently, because nothing errors when a promotion never happens.
--
-- These are the rolling-recurring bodies with that one call put back, placed
-- where it was: after the seat is released and before the remaining queue is
-- read, so `waiter_ids` reports who is still waiting rather than who was about
-- to be promoted.

create or replace function public.cancel_pending(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid)
    and payment_status = 'pending';
  get diagnostics v_deleted_rows = row_count;

  if v_deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  -- The freed seat goes to whoever has waited longest, in the same
  -- transaction that freed it: a client that dies mid-call cannot
  -- lose the promotion.
  perform public.drain_waitlist(p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object('status', 'cancelled', 'waiter_ids', v_waiters);
end;
$$;

create or replace function public.leave_event(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.creator_id = v_uid then
    raise exception 'Event creator cannot leave their own event';
  end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or (added_by = v_uid and not guest_only));
  get diagnostics v_deleted_rows = row_count;

  -- The freed seat goes to whoever has waited longest, in the same
  -- transaction that freed it: a client that dies mid-call cannot
  -- lose the promotion.
  perform public.drain_waitlist(p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', case when v_deleted_rows > 0 then 'left' else 'not_participant' end,
    'waiter_ids', v_waiters
  );
end;
$$;

create or replace function public.decline_event(
  p_event_id uuid,
  p_reason_code text default null,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_reason_code text := nullif(lower(trim(p_reason_code)), '');
  v_reason_text text := nullif(trim(p_reason_text), '');
  v_removed_participants int := 0;
  v_removed_waitlist int := 0;
  v_waiters json;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if v_reason_code is not null and v_reason_code !~ '^[a-z0-9_-]{1,50}$' then
    raise exception 'Invalid reason code';
  end if;
  if v_reason_text is not null and char_length(v_reason_text) > 500 then
    raise exception 'Reason text is too long';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Workspace owner cannot decline an event they administer';
  end if;
  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or (added_by = v_uid and not guest_only));
  get diagnostics v_removed_participants = row_count;

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_uid;
  get diagnostics v_removed_waitlist = row_count;

  insert into public.event_member_responses
    (event_id, user_id, status, reason_code, reason_text,
     responded_at, updated_at)
  values
    (p_event_id, v_uid, 'declined', v_reason_code, v_reason_text,
     now(), now())
  on conflict (event_id, user_id) do update
  set status = 'declined',
      reason_code = excluded.reason_code,
      reason_text = excluded.reason_text,
      responded_at = excluded.responded_at,
      updated_at = excluded.updated_at;

  -- The organizer is told, the same as on the waitlist branch. The rolling
  -- recurring rewrite reissued this function from before that push existed.
  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'member_declined', p_event_id);

  -- The freed seat goes to whoever has waited longest, in the same
  -- transaction that freed it: a client that dies mid-call cannot
  -- lose the promotion.
  perform public.drain_waitlist(p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'declined',
    'event_id', p_event_id,
    'reason_code', v_reason_code,
    'reason_text', v_reason_text,
    'removed_participant_rows', v_removed_participants,
    'removed_waitlist_rows', v_removed_waitlist,
    'waiter_ids', v_waiters
  );
end;
$$;

create or replace function public.reject_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_changed_rows integer := 0;
  v_revoked_future_seats integer := 0;
  v_reopened_event_ids uuid[] := '{}';
  v_series_key uuid;
  v_waiters json := '[]'::json;
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  if v_event.template_id is not null then
    select series_key into v_series_key
    from public.event_templates
    where id = v_event.template_id;
    if v_series_key is not null then
      perform pg_advisory_xact_lock(hashtextextended(v_series_key::text, 0));
    end if;
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  if coalesce(v_event.end_date, v_event.start_date) < now() then
    update public.event_participants
    set payment_declared_at = null
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending'
      and payment_declared_at is not null;
    get diagnostics v_changed_rows = row_count;

    if v_changed_rows > 0 and v_series_key is not null then
      -- Revoke only an unpaid future hold. A transfer already declared or
      -- confirmed for that later occurrence is financial/attendance history
      -- and stays suspended behind the restored old-debt gate.
      with revoked as (
        delete from public.event_participants future_participant
        using public.events future_event,
              public.event_templates future_template
        where future_participant.event_id = future_event.id
          and future_template.id = future_event.template_id
          and future_template.series_key = v_series_key
          and future_event.cancelled_at is null
          and future_event.start_date > now()
          and future_event.start_date > v_event.start_date
          and future_participant.payment_status = 'pending'
          and future_participant.payment_declared_at is null
          and (future_participant.user_id = p_user_id
            or future_participant.added_by = p_user_id)
        returning future_participant.event_id
      )
      select count(*),
             coalesce(array_agg(distinct event_id), '{}'::uuid[])
      into v_revoked_future_seats, v_reopened_event_ids
      from revoked;

      insert into public.push_outbox (user_id, type, event_id)
      select distinct waiter.user_id, 'seat_available', waiter.event_id
      from public.event_waitlist waiter
      where waiter.event_id = any(v_reopened_event_ids);

      delete from public.event_waitlist future_waiter
      using public.events future_event,
            public.event_templates future_template
      where future_waiter.event_id = future_event.id
        and future_template.id = future_event.template_id
        and future_template.series_key = v_series_key
        and future_event.cancelled_at is null
        and future_event.start_date > now()
        and future_event.start_date > v_event.start_date
        and future_waiter.user_id = p_user_id;

      delete from public.event_member_responses future_response
      using public.events future_event,
            public.event_templates future_template
      where future_response.event_id = future_event.id
        and future_template.id = future_event.template_id
        and future_template.series_key = v_series_key
        and future_event.cancelled_at is null
        and future_event.start_date > now()
        and future_event.start_date > v_event.start_date
        and future_response.user_id = p_user_id;
    end if;
  else
    delete from public.event_participants
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';
    get diagnostics v_changed_rows = row_count;

    -- The freed seat goes to whoever has waited longest, in the same
    -- transaction that freed it: a client that dies mid-call cannot
    -- lose the promotion.
    perform public.drain_waitlist(p_event_id);

    select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into v_waiters
    from public.event_waitlist
    where event_id = p_event_id;
  end if;

  if v_changed_rows = 0 then
    return json_build_object(
      'status', 'no_pending_row',
      'waiter_ids', '[]'::json
    );
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  return json_build_object(
    'status', 'rejected',
    'joiner_id', p_user_id,
    'revoked_future_seats', v_revoked_future_seats,
    'waiter_ids', v_waiters
  );
end;
$$;

notify pgrst, 'reload schema';
