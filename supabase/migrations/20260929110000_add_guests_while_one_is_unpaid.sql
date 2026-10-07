-- Adding a second guest was refused while the first was still unpaid.
--
-- register_event_guest_batch_impl answered 'pending_guest_request' whenever the
-- member had any pending guest on a paid workout. That rule dates from manual
-- transfers, where "pending" meant a transfer waiting on the organizer and
-- confirm_payment settles every pending row of a payer at once. Card payment
-- changed what pending means: a guest is pending simply because nobody has paid
-- for them yet, and there is no organizer involved. So a member bringing a
-- second guest was told to wait for an organizer who had nothing to confirm.
--
-- The block now applies only while a declared transfer is actually waiting
-- (payment_declared_at set). Everything else about the function is unchanged.

CREATE OR REPLACE FUNCTION public.register_event_guest_batch_impl(p_event_id uuid, p_guest_names text[], p_expected_payment_method_id uuid, p_expected_price_per_person numeric, p_payment_method_id uuid, p_guest_only boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_current_seats int;
  v_guests text[];
  v_group_size int;
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
  elsif v_self_status is null then
    -- A seat is enough. v_self_status is selected only from
    -- ('pending', 'confirmed'), so null is the one case with no seat at all.
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

  -- confirm_payment/reject_payment address pending rows by added_by, so a batch
  -- added while a DECLARED transfer waits on the organizer would be confirmed
  -- under a transfer that never covered it. That, and only that, must wait.
  -- An unpaid batch nobody has declared anything for is just money owed: a
  -- second batch joins it, and one payment (card or transfer) covers both.
  if v_event.total_price > 0 and exists (
    select 1
    from public.event_participants ep
    where ep.event_id = p_event_id
      and ep.user_id is null
      and ep.added_by = v_uid
      and not ep.added_manually
      and ep.payment_status = 'pending'
      and ep.payment_declared_at is not null
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

  -- p_payment_method_id and p_expected_payment_method_id are still accepted so
  -- the wire contract does not change, but a method is no longer part of
  -- registering. Only the price is still worth guarding: the organizer may
  -- have changed it while the sheet was open.
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

  -- The seat first, exactly as register_event_seat does for the member's own.
  -- No method is chosen or snapshotted here: declare_event_payment stamps
  -- these rows together with the member's seat when «دفع القطة» is pressed,
  -- and it already matches guests through (user_id is null and added_by = uid).
  --
  -- Nothing is owed to a destination yet, so a paid event whose organizer has
  -- not added a method no longer blocks the seat — same as self registration.
  insert into public.event_participants (
    event_id,
    user_id,
    guest_name,
    added_by,
    added_manually,
    guest_only,
    payment_status,
    payment_declared_at,
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
    null,
    v_event.price_per_person
  from unnest(v_guests) as guest(name);

  -- Deliberately no push. 'payment_submitted' reads "وصلك طلب دفع جديد… راجعه
  -- وأكّده", which would ask the organizer to confirm a transfer nobody has
  -- declared. declare_event_payment sends 'payment_declared' when one is.
  return json_build_object(
    'status', 'submitted',
    'creator_id', v_event.creator_id,
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
end;
$function$;
