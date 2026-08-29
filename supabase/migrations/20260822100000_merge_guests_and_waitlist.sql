-- Where the guest sprint and the waiting list meet.
--
-- Two branches rewrote the same five functions without seeing each other:
-- 20260819120000 / 20260820100000 taught them guests and the register-then-pay
-- walk, and 20260821100000 taught them to promote off the queue. Neither file
-- can be edited now that both are applied somewhere, and whichever runs last
-- wins on a given database -- so the merged definitions live here, once,
-- after both.
--
-- Three corrections come with the merge, all from the same fact: a seat is now
-- taken before it is paid for.
--
--   * promote_from_waitlist counted 'confirmed' seats only. Under the new walk
--     most live seats sit at 'pending', so it read a full event as empty and
--     kept promoting into it. It now counts every live seat, as does
--     submit_payment_v2.
--   * A promoted player was inserted 'confirmed' -- a free seat. On a paid
--     event they now owe the same declare-then-confirm walk as anyone else.
--   * register_event_seat queued people on events whose capacity policy is
--     'closed', the exact promise 20260821100000 stopped the app from making.
--     It now answers 'registration_closed_full', which the clients already read.
--
-- submit_payment_v2 is spelled out in full here rather than wrapping
-- submit_payment_v2_before_guest_only: that helper is the pre-waitlist body,
-- so delegating to it would drop the capacity policy again. It stays in place,
-- unused, for the migration history to remain replayable.

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

  -- Every live seat counts, paid or not. Registering now takes the seat and
  -- settles the money afterwards, so a 'pending' row is a real person holding
  -- a place -- counting only 'confirmed' promotes waiters into a full event.
  select count(*) into v_seats
  from public.event_participants
  where event_id = p_event_id
    and payment_status in ('pending', 'confirmed');
  if v_seats >= v_event.max_participants then return null; end if;

  select user_id into v_user_id
  from public.event_waitlist
  where event_id = p_event_id
  order by joined_at asc
  limit 1;
  if v_user_id is null then return null; end if;

  -- A promoted player holds the seat but has paid nothing for it, so a paid
  -- event owes the same declare-then-confirm walk as any other registration.
  -- A free event has nothing to settle and is simply in.
  insert into public.event_participants
    (event_id, user_id, payment_status, paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_user_id,
     case when coalesce(v_event.total_price, 0) > 0 then 'pending' else 'confirmed' end,
     v_event.price_per_person, 1);

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_user_id;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_user_id, 'waitlist_promoted', p_event_id);

  return v_user_id;
end;
$$;

revoke execute on function public.promote_from_waitlist(uuid) from public, anon;


create or replace function public.register_event_seat(
  p_event_id uuid,
  p_guest_names text[] default '{}',
  p_expected_price_per_person decimal default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_existing_status text;
  v_guests text[];
  v_group_size int;
  v_current_seats int;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select payment_status into v_existing_status
  from public.event_participants
  where event_id = p_event_id and user_id = v_uid;
  if v_existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', v_existing_status);
  end if;

  select coalesce(array_agg(trim(g)), '{}')
  into v_guests
  from unnest(coalesce(p_guest_names, '{}'::text[])) as g
  where g is not null and length(trim(g)) > 0;
  v_group_size := 1 + coalesce(array_length(v_guests, 1), 0);

  if p_expected_price_per_person is not null
    and abs(p_expected_price_per_person - coalesce(v_event.price_per_person, 0)) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  if v_event.max_participants is not null then
    select count(*) into v_current_seats
    from public.event_participants
    where event_id = p_event_id
      and payment_status in ('pending', 'confirmed');
    if v_current_seats + v_group_size > v_event.max_participants then
      -- A 'closed' event keeps no reserve list, so there is nothing to join
      -- and nothing to press: the app draws a locked label instead.
      if v_event.capacity_policy = 'closed' then
        return json_build_object('status', 'registration_closed_full');
      end if;

      -- Full is not a refusal: the seat is gone, so the reserve list is what
      -- registering means now. Guests are not queued — a reserve place is
      -- personal, and there is no seat to attach them to.
      insert into public.event_waitlist (event_id, user_id)
      values (p_event_id, v_uid)
      on conflict (event_id, user_id) do nothing;

      return json_build_object(
        'status', 'waitlisted',
        'event_id', v_event.id,
        'group_size', 1
      );
    end if;
  end if;

  -- A free event has nothing to declare, so its seats are settled on sight.
  insert into public.event_participants
    (event_id, user_id, payment_status, payment_declared_at,
     paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_uid,
     case when v_event.total_price <= 0 then 'confirmed' else 'pending' end,
     case when v_event.total_price <= 0 then now() else null end,
     v_event.price_per_person, v_group_size);

  insert into public.event_participants
    (event_id, user_id, guest_name, added_by, payment_status,
     payment_declared_at, paid_price_per_person)
  select
    p_event_id, null, g, v_uid,
    case when v_event.total_price <= 0 then 'confirmed' else 'pending' end,
    case when v_event.total_price <= 0 then now() else null end,
    v_event.price_per_person
  from unnest(v_guests) as g;

  delete from public.event_waitlist where event_id = p_event_id and user_id = v_uid;

  return json_build_object(
    'status', 'submitted',
    'event_id', v_event.id,
    'price_per_person', v_event.price_per_person,
    'group_size', v_group_size,
    'requires_payment', v_event.total_price > 0
  );
end;
$$;

revoke execute on function public.register_event_seat(uuid, text[], decimal)
  from public, anon;
grant execute on function public.register_event_seat(uuid, text[], decimal)
  to authenticated;

-- --------------------------------------------------------------------------
-- declare_event_payment: «حوّلت المبلغ».
--
-- Stamps the payer's own seat and every guest seat they are responsible for,
-- and snapshots the destination they actually paid to — so a later edit to the
-- workspace's payment methods cannot rewrite history. Seats already declared
-- are left alone, which is what makes a guest added afterwards the only thing
-- that falls due again.

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

  -- A guest-only request belongs to whoever asked for it, not to a seat of
  -- their own: declining does not withdraw guests they registered separately.
  delete from public.event_participants
  where event_id = p_event_id
    and (
      user_id = v_uid
      or (added_by = v_uid and not guest_only)
    );
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
    and (
      user_id = v_uid
      or (added_by = v_uid and not guest_only)
    );
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
      and (
        user_id = v_row.user_id
        or (added_by = v_row.user_id and not guest_only)
      );
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

  -- A guest-only request already waiting on the organizer blocks a second
  -- one. Kept from the guest-only migration, whose wrapper this body replaces.
  if exists (
    select 1
    from public.event_participants ep
    where ep.event_id = p_event_id
      and ep.user_id is null
      and ep.added_by = v_uid
      and ep.guest_only
      and ep.payment_status = 'pending'
  ) then
    return json_build_object('status', 'pending_guest_request');
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
    -- Same rule as promote_from_waitlist: a held-but-unpaid seat is taken.
    select count(*) into v_current_seats
    from public.event_participants
    where event_id = p_event_id
      and payment_status in ('pending', 'confirmed');
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
        usr.postion as player_position,
        ep.payment_status,
        ep.payment_provider,
        ep.payment_declared_at,
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
        ep.guest_only,
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
        null::text as player_position,
        null::text as payment_status,
        null::text as payment_provider,
        null::timestamptz as payment_declared_at,
        null::uuid as payment_method_id,
        null::text as paid_to_number,
        null::text as paid_to_iban,
        null::text as paid_to_account_number,
        null::decimal as paid_price_per_person,
        null::int as payment_group_size,
        null::text as guest_name,
        null::uuid as added_by,
        false as added_manually,
        false as guest_only,
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
