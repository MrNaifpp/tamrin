-- Standalone guest registration (T-45).
--
-- A workspace member can reserve seats for named guests without reserving a
-- seat for themselves. These rows are marked guest_only = true so a later
-- self-registration and withdrawal never silently removes the standalone
-- guests. Workspace departure remains broader and still removes every row the
-- member owns through remove_workspace_participation.

-- --------------------------------------------------------------------------
-- One private implementation owns both post-registration guests (T-44) and
-- standalone guests (T-45). Keeping two public RPC names avoids PostgREST
-- overload ambiguity and preserves the existing T-44 wire contract.
-- --------------------------------------------------------------------------
create or replace function public.register_event_guest_batch_impl(
  p_event_id uuid,
  p_guest_names text[],
  p_expected_payment_method_id uuid,
  p_expected_price_per_person decimal,
  p_payment_method_id uuid,
  p_guest_only boolean
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
  v_guests text[];
  v_group_size int;
  v_method_ids uuid[];
  v_selected_method_id uuid;
  v_duplicate_name text;
  v_self_status text;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;
  if p_guest_only is null then
    raise exception 'Guest registration mode is required';
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
  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  select ep.payment_status
  into v_self_status
  from public.event_participants ep
  where ep.event_id = p_event_id
    and ep.user_id = v_uid
    and ep.payment_status in ('pending', 'confirmed')
  limit 1;

  if p_guest_only then
    if v_self_status = 'confirmed' then
      return json_build_object(
        'status', 'self_already_registered',
        'payment_status', v_self_status
      );
    elsif v_self_status = 'pending' then
      return json_build_object(
        'status', 'self_registration_pending',
        'payment_status', v_self_status
      );
    elsif exists (
      select 1
      from public.event_waitlist wl
      where wl.event_id = p_event_id
        and wl.user_id = v_uid
    ) then
      return json_build_object(
        'status', 'self_registration_pending',
        'payment_status', 'waitlisted'
      );
    end if;
  elsif v_self_status is distinct from 'confirmed' then
    return json_build_object('status', 'not_registered');
  end if;

  with normalized as (
    select
      input.ordinality,
      left(
        btrim(regexp_replace(coalesce(input.name, ''), '\s+', ' ', 'g')),
        60
      ) as name
    from unnest(coalesce(p_guest_names, '{}'::text[]))
      with ordinality as input(name, ordinality)
  )
  select coalesce(array_agg(name order by ordinality), '{}'::text[])
  into v_guests
  from normalized
  where name <> '';

  v_group_size := coalesce(cardinality(v_guests), 0);
  if v_group_size = 0 then
    return json_build_object('status', 'empty_guests');
  end if;

  -- confirm_payment/reject_payment address pending rows by added_by. A second
  -- paid guest batch would merge with the first, so it must wait. Confirmed
  -- free batches and previously resolved paid batches remain repeatable.
  if v_event.total_price > 0 and exists (
    select 1
    from public.event_participants ep
    where ep.event_id = p_event_id
      and ep.user_id is null
      and ep.added_by = v_uid
      and not ep.added_manually
      and ep.payment_status = 'pending'
  ) then
    return json_build_object('status', 'pending_guest_request');
  end if;

  select min(requested.name)
  into v_duplicate_name
  from unnest(v_guests) as requested(name)
  group by lower(requested.name)
  having count(*) > 1
  limit 1;

  if v_duplicate_name is not null then
    return json_build_object(
      'status', 'duplicate_name',
      'name', v_duplicate_name
    );
  end if;

  select existing.guest_name
  into v_duplicate_name
  from public.event_participants existing
  join unnest(v_guests) as requested(name)
    on lower(existing.guest_name) = lower(requested.name)
  where existing.event_id = p_event_id
    and existing.user_id is null
    and existing.added_by = v_uid
    and not existing.added_manually
    and existing.payment_status in ('pending', 'confirmed')
  limit 1;

  if v_duplicate_name is not null then
    return json_build_object(
      'status', 'duplicate_name',
      'name', v_duplicate_name
    );
  end if;

  if p_payment_method_id is not null
    and p_expected_payment_method_id is not null
    and p_payment_method_id is distinct from p_expected_payment_method_id then
    return json_build_object('status', 'event_terms_changed');
  end if;
  v_selected_method_id := coalesce(
    p_payment_method_id,
    p_expected_payment_method_id
  );

  if p_expected_price_per_person is not null
    and abs(
      p_expected_price_per_person - coalesce(v_event.price_per_person, 0)
    ) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  if v_event.max_participants is not null then
    select count(*) into v_current_seats
    from public.event_participants
    where event_id = p_event_id
      and payment_status in ('pending', 'confirmed');

    if v_current_seats + v_group_size > v_event.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  if v_event.total_price <= 0 then
    insert into public.event_participants (
      event_id,
      user_id,
      guest_name,
      added_by,
      added_manually,
      guest_only,
      payment_status,
      paid_price_per_person
    )
    select
      p_event_id,
      null,
      guest.name,
      v_uid,
      false,
      p_guest_only,
      'confirmed',
      v_event.price_per_person
    from unnest(v_guests) as guest(name);

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
      'group_size', v_group_size,
      'guest_only', p_guest_only
    );
  end if;

  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;
  if cardinality(v_method_ids) = 0 then
    return json_build_object('status', 'payment_method_required');
  end if;

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

  insert into public.event_participants (
    event_id,
    user_id,
    guest_name,
    added_by,
    added_manually,
    guest_only,
    payment_status,
    payment_method_id,
    payment_provider,
    paid_to_number,
    paid_to_iban,
    paid_to_account_number,
    paid_price_per_person
  )
  select
    p_event_id,
    null,
    guest.name,
    v_uid,
    false,
    p_guest_only,
    'pending',
    v_method.id,
    v_method.provider,
    v_method.mobile_number,
    v_method.iban,
    v_method.account_number,
    v_event.price_per_person
  from unnest(v_guests) as guest(name);

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
    'group_size', v_group_size,
    'guest_only', p_guest_only
  );
end;
$$;

revoke execute on function public.register_event_guest_batch_impl(
  uuid, text[], uuid, decimal, uuid, boolean
) from public, anon, authenticated;

create or replace function public.register_event_guests(
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
begin
  return public.register_event_guest_batch_impl(
    p_event_id,
    p_guest_names,
    p_expected_payment_method_id,
    p_expected_price_per_person,
    p_payment_method_id,
    false
  );
end;
$$;

revoke execute on function public.register_event_guests(
  uuid, text[], uuid, decimal, uuid
) from public, anon;
grant execute on function public.register_event_guests(
  uuid, text[], uuid, decimal, uuid
) to authenticated;

create or replace function public.register_event_guest_only(
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
begin
  return public.register_event_guest_batch_impl(
    p_event_id,
    p_guest_names,
    p_expected_payment_method_id,
    p_expected_price_per_person,
    p_payment_method_id,
    true
  );
end;
$$;

revoke execute on function public.register_event_guest_only(
  uuid, text[], uuid, decimal, uuid
) from public, anon;
grant execute on function public.register_event_guest_only(
  uuid, text[], uuid, decimal, uuid
) to authenticated;

-- --------------------------------------------------------------------------
-- A standalone paid batch must be resolved before the member submits a paid
-- self-registration. Wrap the existing implementation rather than copying it,
-- retaining every T-44/payment compatibility behavior in one place.
-- --------------------------------------------------------------------------
alter function public.submit_payment_v2(uuid, text[], uuid, decimal, uuid)
  rename to submit_payment_v2_before_guest_only;

revoke execute on function public.submit_payment_v2_before_guest_only(
  uuid, text[], uuid, decimal, uuid
) from public, anon, authenticated;

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
begin
  if v_uid is null then
    raise exception 'Not authenticated';
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

  return public.submit_payment_v2_before_guest_only(
    p_event_id,
    p_guest_names,
    p_expected_payment_method_id,
    p_expected_price_per_person,
    p_payment_method_id
  );
end;
$$;

revoke execute on function public.submit_payment_v2(
  uuid, text[], uuid, decimal, uuid
) from public, anon;
grant execute on function public.submit_payment_v2(
  uuid, text[], uuid, decimal, uuid
) to authenticated;

-- Defense in depth for legacy/direct self-registration paths. The event share
-- lock serializes this check with the guest-batch update lock.
create or replace function public.guard_event_registration_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
begin
  select * into v_event
  from public.events
  where id = new.event_id
  for share;
  if v_event.id is null then raise exception 'Event not found'; end if;

  if tg_table_name = 'event_waitlist' then
    if new.user_id is null
       or not public.is_workspace_member(v_event.workspace_id, new.user_id) then
      raise exception 'Not a workspace member';
    end if;
  elsif new.user_id is not null then
    if not public.is_workspace_member(v_event.workspace_id, new.user_id) then
      raise exception 'Not a workspace member';
    end if;
  elsif new.added_by is null
        or not public.is_workspace_member(v_event.workspace_id, new.added_by) then
    raise exception 'A guest must be added by a workspace member';
  end if;

  if tg_table_name in ('event_participants', 'event_waitlist')
     and new.user_id is not null
     and exists (
       select 1
       from public.event_participants ep
       where ep.event_id = new.event_id
         and ep.user_id is null
         and ep.added_by = new.user_id
         and ep.guest_only
         and ep.payment_status = 'pending'
     ) then
    raise exception 'Pending guest request must be resolved before self registration';
  end if;

  if tg_table_name = 'event_participants'
     and new.user_id is not null
     and new.user_id = v_event.creator_id
     and v_event.cancelled_at is null
     and not v_event.registration_locked then
    return new;
  end if;

  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then raise exception 'Registration is closed for this event'; end if;
  return new;
end;
$$;

revoke execute on function public.guard_event_registration_insert()
  from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Self withdrawal releases the member and guests tied to that self seat, but
-- preserves standalone guest_only rows. Pending cancellation/rejection remains
-- intentionally broad because those operations resolve the payment batch.
-- --------------------------------------------------------------------------
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

revoke execute on function public.decline_event(uuid, text, text)
  from public, anon;
grant execute on function public.decline_event(uuid, text, text)
  to authenticated;

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

revoke execute on function public.leave_event(uuid, uuid)
  from public, anon;
grant execute on function public.leave_event(uuid, uuid)
  to authenticated;

-- Organizer removal follows the same ownership boundary when the selected row
-- is a real member. Selecting a guest row still removes exactly that guest.
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

  if v_row.user_id is not null and v_row.user_id = v_event.creator_id then
    return json_build_object('status', 'is_creator');
  end if;

  if v_row.user_id is null then
    delete from public.event_participants where id = p_participant_id;
  else
    delete from public.event_participants
    where event_id = v_row.event_id
      and (
        user_id = v_row.user_id
        or (added_by = v_row.user_id and not guest_only)
      );
  end if;
  get diagnostics v_removed = row_count;

  return json_build_object('status', 'removed', 'removed_count', v_removed);
end;
$$;

revoke execute on function public.remove_event_participant(uuid)
  from public, anon;
grant execute on function public.remove_event_participant(uuid)
  to authenticated;

notify pgrst, 'reload schema';
