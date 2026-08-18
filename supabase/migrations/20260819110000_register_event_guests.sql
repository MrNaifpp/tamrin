-- Let an already registered member add guests after their own registration.
--
-- The member's participant row is deliberately left untouched: it may carry an
-- immutable snapshot of an earlier payment. A later guest batch owns its own
-- snapshots on the guest rows, and the existing confirm/reject/cancel RPCs can
-- still address that batch through added_by.

-- T-44 guests leave with the member who registered them. T-45 will use the
-- same shape with guest_only = true for guests registered without a self seat.
alter table public.event_participants
  add column if not exists guest_only boolean not null default false;

comment on column public.event_participants.guest_only is
  'True only when a guest was registered without also registering the adding member. False guests remain attached to that member participation.';

alter table public.event_participants
  drop constraint if exists event_participants_guest_only_shape_check;

alter table public.event_participants
  add constraint event_participants_guest_only_shape_check check (
    not guest_only
    or (
      user_id is null
      and added_by is not null
      and not added_manually
    )
  );

-- A registered player must see the event's current choices, not the immutable
-- destination snapshotted on their original participant row. The response is
-- intentionally wire-compatible with get_event_payment_destination.
create or replace function public.get_event_guest_payment_destination(
  p_event_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_method_ids uuid[];
  v_methods jsonb;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null
     and not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Event is not published';
  end if;

  if v_event.total_price <= 0 then
    return json_build_object(
      'status', 'free',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;

  if cardinality(v_method_ids) = 0 then
    return json_build_object(
      'status', 'payment_method_required',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'payment_method_id', pm.id,
        'provider', pm.provider,
        'mobile_number', pm.mobile_number,
        'iban', pm.iban,
        'account_number', pm.account_number
      )
      order by array_position(v_method_ids, pm.id)
    ),
    '[]'::jsonb
  )
  into v_methods
  from public.workspace_payment_methods pm
  where pm.id = any(v_method_ids)
    and pm.workspace_id = v_event.workspace_id;

  if jsonb_array_length(v_methods) = 0 then
    return json_build_object(
      'status', 'payment_method_required',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  return json_build_object(
    'status', 'available',
    'event_id', v_event.id,
    'payment_method_id', null,
    'provider', null,
    'mobile_number', null,
    'iban', null,
    'account_number', null,
    'payment_methods', v_methods,
    'total_price', v_event.total_price,
    'price_per_person', v_event.price_per_person,
    'group_size', null
  );
end;
$$;

revoke execute on function public.get_event_guest_payment_destination(uuid)
  from public, anon;
grant execute on function public.get_event_guest_payment_destination(uuid)
  to authenticated;

-- Add one atomic batch of guests. The event row lock serializes capacity and
-- duplicate-name decisions with every current registration/payment RPC.
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
  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  if not exists (
    select 1
    from public.event_participants ep
    where ep.event_id = p_event_id
      and ep.user_id = v_uid
      and ep.payment_status = 'confirmed'
  ) then
    return json_build_object('status', 'not_registered');
  end if;

  -- Normalize once, preserve the user's order, and cap the stored name at the
  -- same 60 characters used by organizer-entered participants.
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

  -- confirm_payment/reject_payment intentionally operate on every pending row
  -- owned by one member. Keep that group unambiguous by refusing a second paid
  -- guest batch until the organizer has resolved the first one. Free batches
  -- are already confirmed, so they may be added repeatedly.
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

  -- Scope idempotency to the member's non-manual guests. Different members can
  -- bring people with the same name, and a manual roster entry is independent.
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

  -- The player reviewed a particular amount and method. Reject a stale sheet
  -- before creating any rows.
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
      false,
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
    false,
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
    'group_size', v_group_size
  );
end;
$$;

revoke execute on function public.register_event_guests(
  uuid, text[], uuid, decimal, uuid
) from public, anon;
grant execute on function public.register_event_guests(
  uuid, text[], uuid, decimal, uuid
) to authenticated;

notify pgrst, 'reload schema';
