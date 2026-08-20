-- Capacity policy + automatic waitlist promotion (ROADMAP F2, core).
-- Spec: docs/superpowers/specs/2026-08-21-waitlist-promotion-design.md
--
-- Until now the organizer's "قائمة انتظار / يقفل عند الاكتمال" choice was
-- never stored, the waiting list was never shown, nobody was ever promoted
-- off it, and an organizer was never told that a member had withdrawn. This
-- migration makes all four real.

-- ===========================================================================
-- 1. The policy column
-- ===========================================================================

-- The column default backfills every existing row to 'waitlist', which is
-- exactly how the client behaved when it hardcoded the value.
alter table public.events
  add column if not exists capacity_policy text not null default 'waitlist'
  check (capacity_policy in ('waitlist', 'closed'));

alter table public.event_templates
  add column if not exists capacity_policy text not null default 'waitlist'
  check (capacity_policy in ('waitlist', 'closed'));

-- A template built from an existing event (إعدادات الموعد ▸ يتكرر أسبوعيًا)
-- must inherit that event's policy, otherwise the series silently reverts to
-- 'waitlist'. update_event_with_scope links the two by setting template_id
-- after inserting the template, so that is where the inheritance hooks in --
-- cheaper and less brittle than re-creating that whole function here.
create or replace function public.sync_template_capacity_policy()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.template_id is not null
     and new.template_id is distinct from old.template_id then
    update public.event_templates
    set capacity_policy = new.capacity_policy
    where id = new.template_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_sync_template_capacity_policy on public.events;
create trigger trg_sync_template_capacity_policy
  after update of template_id on public.events
  for each row
  execute function public.sync_template_capacity_policy();

-- ===========================================================================
-- 2. promote_from_waitlist -- the whole feature, in one place
-- ===========================================================================

-- Promotes the longest-waiting member into a freed seat and returns their
-- user_id, or NULL when it declines to act.
--
-- THE CALLER MUST ALREADY HOLD `select ... for update` ON THE EVENT ROW.
-- That lock is the only thing serializing a promotion against a concurrent
-- registration; without it two callers can hand out the same seat. Every
-- current call site takes it. A future one that frees a seat without it will
-- race silently.
--
-- Deliberately does NOT check capacity_policy: 'closed' stops people joining
-- the queue (see join_waitlist), it does not strand people already in it. An
-- organizer who switches a live session to 'closed' still drains the queue.
--
-- Deliberately does NOT touch payment methods. The promoted seat was never
-- paid for, so it carries no payment_method_id and no paid_to_* snapshot --
-- the same shape submit_payment_v2 already uses for a free event. This also
-- means a removed or misconfigured payment method cannot stall the queue.
create or replace function public.promote_from_waitlist(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_seats int;
  v_user_id uuid;
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then return null; end if;
  if v_event.registration_locked then return null; end if;
  if v_event.cancelled_at is not null then return null; end if;
  -- An uncapped event has no notion of a seat freeing up.
  if v_event.max_participants is null then return null; end if;

  -- Confirmed only: 'pending' is on its way out of the product, and a seat
  -- held by an unconfirmed payment should not block a waiter.
  select count(*) into v_seats
  from public.event_participants
  where event_id = p_event_id
    and payment_status = 'confirmed';
  if v_seats >= v_event.max_participants then return null; end if;

  select user_id into v_user_id
  from public.event_waitlist
  where event_id = p_event_id
  order by joined_at asc
  limit 1;
  if v_user_id is null then return null; end if;

  -- Straight to 'confirmed': the payment-confirmation step is being removed
  -- from the product, so a promoted player is simply in.
  insert into public.event_participants
    (event_id, user_id, payment_status, paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_user_id, 'confirmed', v_event.price_per_person, 1);

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_user_id;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_user_id, 'waitlist_promoted', p_event_id);

  return v_user_id;
end;
$$;

revoke execute on function public.promote_from_waitlist(uuid) from public, anon;

-- Drains as many waiters as there are free seats. A member leaving with the
-- guests they paid for frees several at once, and each should pull someone in.
create or replace function public.drain_waitlist(p_event_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare
  v_promoted int := 0;
begin
  while public.promote_from_waitlist(p_event_id) is not null loop
    v_promoted := v_promoted + 1;
  end loop;
  return v_promoted;
end;
$$;

revoke execute on function public.drain_waitlist(uuid) from public, anon;

-- ===========================================================================
-- 3. Editing the policy on a live session
-- ===========================================================================

create or replace function public.set_event_capacity_policy(
  p_event_id uuid,
  p_capacity_policy text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_drained int := 0;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_capacity_policy not in ('waitlist', 'closed') then
    raise exception 'Invalid capacity policy: %', p_capacity_policy;
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized: only the organizer can change this';
  end if;

  update public.events
  set capacity_policy = p_capacity_policy
  where id = p_event_id
  returning * into v_event;

  if v_event.template_id is not null then
    update public.event_templates
    set capacity_policy = p_capacity_policy
    where id = v_event.template_id;
  end if;

  -- Switching to 'waitlist' can make an already-free seat claimable.
  v_drained := public.drain_waitlist(p_event_id);

  return json_build_object(
    'status', 'updated',
    'capacity_policy', v_event.capacity_policy,
    'promoted_count', v_drained
  );
end;
$$;

revoke execute on function public.set_event_capacity_policy(uuid, text) from public, anon;
grant execute on function public.set_event_capacity_policy(uuid, text) to authenticated;


-- ===========================================================================
-- 4. create_event carries the organizer's choice
-- ===========================================================================

-- The new parameter has a default, which would make the old 16-argument
-- signature ambiguous against this one, so the old signature is dropped first.
drop function if exists public.create_event(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[]
);

create or replace function public.create_event(
  p_creator_id uuid,
  p_workspace_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null,
  p_total_price int default 0,
  p_price_per_person decimal default 0,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_recurrence text default 'none',
  p_payment_method_id uuid default null,
  p_payment_method_ids uuid[] default null,
  p_capacity_policy text default 'waitlist'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_template_id uuid;
  v_duration_minutes int;
  v_payment_method_ids uuid[];
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_owner(p_workspace_id, v_uid) then
    raise exception 'Only the workspace owner can create events';
  end if;
  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Invalid recurrence: %', p_recurrence;
  end if;
  if p_capacity_policy not in ('waitlist', 'closed') then
    raise exception 'Invalid capacity policy: %', p_capacity_policy;
  end if;
  if p_total_price < 0 then
    raise exception 'Total price cannot be negative';
  end if;
  if p_max_participants is not null and p_max_participants <= 0 then
    raise exception 'Player count must be greater than zero';
  end if;
  if p_total_price > 0 and p_max_participants is null then
    raise exception 'Player count is required when total price is greater than zero';
  end if;

  v_payment_method_ids := coalesce(p_payment_method_ids, '{}'::uuid[]);
  if cardinality(v_payment_method_ids) = 0 and p_payment_method_id is not null then
    v_payment_method_ids := array[p_payment_method_id];
  end if;
  if p_total_price > 0 and cardinality(v_payment_method_ids) = 0 then
    raise exception 'A payment method is required when total price is greater than zero';
  end if;
  if cardinality(v_payment_method_ids) <> (
    select count(distinct selected_id)
    from unnest(v_payment_method_ids) as selected(selected_id)
  ) then
    raise exception 'Payment methods must be non-null and unique';
  end if;
  if exists (
    select 1
    from unnest(v_payment_method_ids) as selected(selected_id)
    left join public.workspace_payment_methods pm
      on pm.id = selected.selected_id
     and pm.workspace_id = p_workspace_id
    where pm.id is null
  ) then
    raise exception 'Payment method does not belong to the event workspace';
  end if;

  if p_recurrence = 'weekly' then
    if p_end_date is not null then
      v_duration_minutes :=
        (extract(epoch from (p_end_date - p_start_date)) / 60)::int;
    end if;
    insert into public.event_templates
      (workspace_id, creator_id, name, location, description, image_url,
       latitude, longitude, total_price, price_per_person, max_participants,
       duration_minutes, recurrence, next_occurrence_at, payment_method_id,
       payment_method_ids, published_at, capacity_policy)
    values
      (p_workspace_id, v_uid, p_name, p_location, p_description, p_image_url,
       p_latitude, p_longitude, p_total_price, 0, p_max_participants,
       v_duration_minutes, 'weekly', p_start_date + interval '7 days',
       v_payment_method_ids[1], v_payment_method_ids, null, p_capacity_policy)
    returning id into v_template_id;
  end if;

  insert into public.events
    (creator_id, workspace_id, name, location, description, start_date,
     end_date, image_url, max_participants, total_price, price_per_person,
     latitude, longitude, template_id, payment_method_id, payment_method_ids,
     published_at, capacity_policy)
  values
    (v_uid, p_workspace_id, p_name, p_location, p_description, p_start_date,
     p_end_date, p_image_url, p_max_participants, p_total_price, 0,
     p_latitude, p_longitude, v_template_id, v_payment_method_ids[1],
     v_payment_method_ids, null, p_capacity_policy)
  returning * into v_event;

  insert into public.event_participants (event_id, user_id)
  values (v_event.id, v_uid);

  return row_to_json(v_event);
end;
$$;

revoke execute on function public.create_event(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[], text
) from public, anon;
grant execute on function public.create_event(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[], text
) to authenticated;

-- ===========================================================================
-- 5. Weekly occurrences inherit the series' policy
-- ===========================================================================

create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl record;
  v_event public.events;
begin
  for tpl in
    select * from public.event_templates t
    where t.ended_at is null
      and t.published_at is not null
      and now() >= t.next_occurrence_at - make_interval(days => t.lead_days)
    order by t.next_occurrence_at
    for update
  loop
    -- A removed legacy creator must not abort the whole cron transaction and
    -- block unrelated workspaces. End that orphaned series and continue.
    if not public.is_workspace_member(tpl.workspace_id, tpl.creator_id) then
      update public.event_templates
      set ended_at = coalesce(ended_at, now())
      where id = tpl.id;
      continue;
    end if;

    if tpl.skip_next then
      update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at + interval '7 days',
          skip_next = false
      where id = tpl.id;
      continue;
    end if;

    while tpl.next_occurrence_at <= now() loop
      tpl.next_occurrence_at := tpl.next_occurrence_at + interval '7 days';
    end loop;

    if now() < tpl.next_occurrence_at - make_interval(days => tpl.lead_days) then
      update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at
      where id = tpl.id;
      continue;
    end if;

    insert into public.events
      (creator_id, workspace_id, name, location, description, start_date,
       end_date, image_url, max_participants, total_price, price_per_person,
       latitude, longitude, template_id, payment_method_id, payment_method_ids,
       published_at, capacity_policy)
    values
      (tpl.creator_id, tpl.workspace_id, tpl.name, tpl.location, tpl.description,
       tpl.next_occurrence_at,
       case when tpl.duration_minutes is not null
         then tpl.next_occurrence_at + make_interval(mins => tpl.duration_minutes) end,
       tpl.image_url, tpl.max_participants, tpl.total_price, 0,
       tpl.latitude, tpl.longitude, tpl.id, tpl.payment_method_id,
       tpl.payment_method_ids, null, tpl.capacity_policy)
    returning * into v_event;

    insert into public.event_participants (event_id, user_id)
    values (v_event.id, tpl.creator_id);

    update public.event_templates
    set next_occurrence_at = tpl.next_occurrence_at + interval '7 days'
    where id = tpl.id;
  end loop;
end;
$$;

-- ===========================================================================
-- 6. Declining: notify the organizer, and promote the next waiter
-- ===========================================================================

-- Two bugs fixed here. The organizer was never told that a member had pulled
-- out -- decline_event enqueued nothing at all, while cancel_event_occurrence
-- had used push_outbox correctly all along. And the waiter_ids this returned
-- were dropped on the floor by the Swift caller, so the freed seat sat empty.

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

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid);
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

  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'member_declined', p_event_id);

  -- Freed seats go to whoever has waited longest, in the same transaction
  -- that freed them -- a client that dies mid-call cannot lose the promotion.
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

revoke execute on function public.decline_event(uuid, text, text) from public, anon;
grant execute on function public.decline_event(uuid, text, text) to authenticated;


-- ===========================================================================
-- 7. Every other path that frees a seat drains the queue too
-- ===========================================================================

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
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.creator_id = v_uid then
    raise exception 'Event creator cannot leave their own event';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid);
  get diagnostics v_deleted_rows = row_count;


  -- Freed seats go to whoever has waited longest, in the same transaction
  -- that freed them -- a client that dies mid-call cannot lose the promotion.
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

revoke execute on function public.leave_event(uuid, uuid) from public, anon;
grant execute on function public.leave_event(uuid, uuid) to authenticated;

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
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid)
    and payment_status = 'pending';
  get diagnostics v_deleted_rows = row_count;

  if v_deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;


  -- Freed seats go to whoever has waited longest, in the same transaction
  -- that freed them -- a client that dies mid-call cannot lose the promotion.
  perform public.drain_waitlist(p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'cancelled',
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.cancel_pending(uuid, uuid) from public, anon;
grant execute on function public.cancel_pending(uuid, uuid) to authenticated;

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
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = p_user_id or added_by = p_user_id)
    and payment_status = 'pending';
  get diagnostics v_deleted_rows = row_count;

  if v_deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);


  -- Freed seats go to whoever has waited longest, in the same transaction
  -- that freed them -- a client that dies mid-call cannot lose the promotion.
  perform public.drain_waitlist(p_event_id);

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'rejected',
    'joiner_id', p_user_id,
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.reject_payment(uuid, uuid, uuid) from public, anon;
grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

create or replace function public.remove_event_participant(
  p_participant_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_row public.event_participants;
  v_event public.events;
  v_removed int;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_row
  from public.event_participants
  where id = p_participant_id;
  if v_row.id is null then
    return json_build_object('status', 'not_found');
  end if;

  select * into v_event from public.events where id = v_row.event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;

  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized: only the organizer can remove a participant';
  end if;

  -- The organizer's own seat is not removable here: an event without its
  -- creator on the list is a state the rest of the app does not expect, and
  -- leaving is already refused by leave_event for the same reason.
  if v_row.user_id is not null and v_row.user_id = v_event.creator_id then
    return json_build_object('status', 'is_creator');
  end if;

  if v_row.user_id is null then
    -- A guest or a manual registration: exactly this one seat.
    delete from public.event_participants where id = p_participant_id;
  else
    -- A member: their own seat plus the guests they brought.
    delete from public.event_participants
    where event_id = v_row.event_id
      and (user_id = v_row.user_id or added_by = v_row.user_id);
  end if;
  get diagnostics v_removed = row_count;

  -- Freed seats go to whoever has waited longest, in the same transaction
  -- that freed them -- a client that dies mid-call cannot lose the promotion.
  perform public.drain_waitlist(v_row.event_id);

  return json_build_object('status', 'removed', 'removed_count', v_removed);
end;
$$;

revoke execute on function public.remove_event_participant(uuid) from public, anon;
grant execute on function public.remove_event_participant(uuid) to authenticated;

-- ===========================================================================
-- 8. 'closed' refuses the queue, server-side
-- ===========================================================================

-- The UI rule has to hold here too: a stale screen must not be able to seat
-- someone on a queue the organizer has closed.

create or replace function public.join_waitlist(p_event_id uuid, p_user_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then
    raise exception 'Registration is closed for this event';
  end if;
  if v_event.capacity_policy = 'closed' then
    raise exception 'This event closes at capacity and has no waiting list';
  end if;

  insert into public.event_waitlist (event_id, user_id)
  values (p_event_id, v_uid)
  on conflict (event_id, user_id) do nothing;
  return json_build_object('status', 'joined');
end;
$$;

revoke execute on function public.join_waitlist(uuid, uuid) from public, anon;
grant execute on function public.join_waitlist(uuid, uuid) to authenticated;


-- ===========================================================================
-- 9. Registration: confirmed-only seat count, and the closed-at-capacity state
-- ===========================================================================

-- The cap stops counting 'pending'. That status is being removed from the
-- product, and a seat held by an unconfirmed payment should not lock a real
-- player out. The count stays group-aware -- one registration can bring
-- guests, and each guest is its own row and its own seat.

create or replace function public.submit_payment_v2(
  p_event_id uuid,
  p_guest_names text[] default '{}',
  p_expected_payment_method_id uuid default null,
  p_expected_price_per_person decimal default null,
  p_payment_method_id uuid default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_method public.workspace_payment_methods;
  v_current_seats int;
  v_existing_status text;
  v_guests text[];
  v_group_size int;
  v_method_ids uuid[];
  v_selected_method_id uuid;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into v_existing_status
  from public.event_participants
  where event_id = p_event_id and user_id = v_uid;
  if v_existing_status is not null then
    return json_build_object(
      'status', 'already_joined',
      'payment_status', v_existing_status
    );
  end if;

  select coalesce(array_agg(trim(g)), '{}')
  into v_guests
  from unnest(coalesce(p_guest_names, '{}'::text[])) as g
  where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

  -- The player reviewed a particular choice and amount. Refuse to create a
  -- row if the organizer removed that choice while the half sheet was open.
  if p_payment_method_id is not null
    and p_expected_payment_method_id is not null
    and p_payment_method_id is distinct from p_expected_payment_method_id then
    return json_build_object('status', 'event_terms_changed');
  end if;
  v_selected_method_id := coalesce(p_payment_method_id, p_expected_payment_method_id);

  if p_expected_price_per_person is not null
    and abs(p_expected_price_per_person - coalesce(v_event.price_per_person, 0)) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  if v_event.max_participants is not null then
    select count(*) into v_current_seats
    from public.event_participants
    where event_id = p_event_id
      and payment_status = 'confirmed';
    if v_current_seats + v_group_size > v_event.max_participants then
      -- A 'closed' event offers no queue, so the client renders قفل التسجيل
      -- instead of a waiting list that can never be joined.
      if v_event.capacity_policy = 'closed' then
        return json_build_object('status', 'registration_closed_full');
      end if;
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  -- Legacy free events remain registerable. They bypass payment entirely but
  -- keep the same atomic seat-count and guest behavior as a paid registration.
  if v_event.total_price <= 0 then
    insert into public.event_participants
      (event_id, user_id, payment_status, paid_price_per_person, payment_group_size)
    values
      (p_event_id, v_uid, 'confirmed', v_event.price_per_person, v_group_size);

    insert into public.event_participants
      (event_id, user_id, guest_name, added_by, payment_status, paid_price_per_person)
    select p_event_id, null, g, v_uid, 'confirmed', v_event.price_per_person
    from unnest(v_guests) as g;

    delete from public.event_waitlist
    where event_id = p_event_id and user_id = v_uid;

    return json_build_object(
      'status', 'submitted',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', v_group_size
    );
  end if;

  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;
  if cardinality(v_method_ids) = 0 then
    return json_build_object('status', 'payment_method_required');
  end if;

  -- A one-method event remains compatible with older clients. Modern clients
  -- always submit the explicit choice made in the half sheet.
  if v_selected_method_id is null and cardinality(v_method_ids) = 1 then
    v_selected_method_id := v_method_ids[1];
  end if;
  if v_selected_method_id is null then
    return json_build_object('status', 'payment_method_required');
  end if;
  if not (v_selected_method_id = any(v_method_ids)) then
    return json_build_object('status', 'event_terms_changed');
  end if;

  select * into v_method
  from public.workspace_payment_methods
  where id = v_selected_method_id
    and workspace_id = v_event.workspace_id
  for share;
  if v_method.id is null then
    return json_build_object('status', 'payment_method_required');
  end if;

  insert into public.event_participants
    (event_id, user_id, payment_status, payment_method_id, payment_provider,
     paid_to_number, paid_to_iban, paid_to_account_number,
     paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_uid, 'pending', v_method.id, v_method.provider,
     v_method.mobile_number, v_method.iban, v_method.account_number,
     v_event.price_per_person, v_group_size);

  insert into public.event_participants
    (event_id, user_id, guest_name, added_by, payment_status,
     payment_method_id, payment_provider, paid_to_number, paid_to_iban,
     paid_to_account_number, paid_price_per_person)
  select p_event_id, null, g, v_uid, 'pending',
         v_method.id, v_method.provider, v_method.mobile_number,
         v_method.iban, v_method.account_number, v_event.price_per_person
  from unnest(v_guests) as g;

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_uid;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'payment_submitted', p_event_id);

  return json_build_object(
    'status', 'submitted',
    'creator_id', v_event.creator_id,
    'event_id', v_event.id,
    'payment_method_id', v_method.id,
    'provider', v_method.provider,
    'mobile_number', v_method.mobile_number,
    'iban', v_method.iban,
    'account_number', v_method.account_number,
    'payment_methods', '[]'::jsonb,
    'total_price', v_event.total_price,
    'price_per_person', v_event.price_per_person,
    'group_size', v_group_size
  );
end;
$$;

revoke execute on function public.submit_payment_v2(uuid, text[], uuid, decimal, uuid) from public, anon;
grant execute on function public.submit_payment_v2(uuid, text[], uuid, decimal, uuid) to authenticated;


-- ===========================================================================
-- 10. The roster returns the waiting list
-- ===========================================================================

-- waitlistCount(for:) on the client has always filtered the roster for
-- waitlisted rows, but this RPC only ever read event_participants, so the
-- count was permanently zero and the section never rendered. Waiters now come
-- back as rows flagged is_waitlisted, ordered after the seated players and
-- oldest-first among themselves, which is the order they will be promoted in.
--
-- They carry no payment columns: nothing has been paid, and a waiter must not
-- see another player's payment snapshot. participant_id reuses the waiter's
-- user_id so the row has a stable identity across refreshes.

create or replace function public.get_event_participants_lifecycle_impl(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_event public.events;
  v_uid uuid := auth.uid();
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(
      json_agg(row_to_json(x) order by x.is_waitlisted asc, x.joined_at asc),
      '[]'::json)
    from (
      select
        ep.id as participant_id,
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, au.email, ep.guest_name) as display_name,
        usr.avatar_url,
        ep.payment_status,
        ep.payment_provider,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.payment_method_id else null end as payment_method_id,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_number else null end as paid_to_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_iban else null end as paid_to_iban,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_account_number else null end as paid_to_account_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_price_per_person else null end as paid_price_per_person,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id
          then ep.payment_group_size else null end as payment_group_size,
        ep.guest_name,
        ep.added_by,
        ep.added_manually,
        case when v_uid = v_event.creator_id
          then ep.payment_reminder_sent_at else null end as payment_reminder_sent_at,
        false as is_waitlisted
      from public.event_participants ep
      left join auth.users au on au.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id

      union all

      select
        ew.user_id as participant_id,
        ew.user_id,
        ew.joined_at,
        coalesce(usr.name, au.email) as display_name,
        usr.avatar_url,
        null::text as payment_status,
        null::text as payment_provider,
        null::uuid as payment_method_id,
        null::text as paid_to_number,
        null::text as paid_to_iban,
        null::text as paid_to_account_number,
        null::decimal as paid_price_per_person,
        null::int as payment_group_size,
        null::text as guest_name,
        null::uuid as added_by,
        false as added_manually,
        null::timestamptz as payment_reminder_sent_at,
        true as is_waitlisted
      from public.event_waitlist ew
      left join auth.users au on au.id = ew.user_id
      left join public.users usr on usr.user_id = ew.user_id
      where ew.event_id = p_event_id
    ) x
  );
end;
$$;