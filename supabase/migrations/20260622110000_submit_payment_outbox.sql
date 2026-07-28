-- Adds a push_outbox insert to submit_payment so the creator is notified.
-- Inside the same transaction: if the payment write rolls back, so does the
-- notification.

create or replace function public.submit_payment(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  creator_stc text;
  current_seats int;
  existing_status text;
begin
  -- Lock the event row to serialize concurrent submits for the same event.
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;

  if ev.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  -- Already joined? (any status counts)
  select payment_status into existing_status
    from public.event_participants
    where event_id = p_event_id and user_id = p_user_id;
  if existing_status is not null then
    return json_build_object('status', 'already_joined', 'payment_status', existing_status);
  end if;

  -- Seat cap (pending + confirmed both count).
  if ev.max_participants is not null then
    select count(*) into current_seats
      from public.event_participants
      where event_id = p_event_id
        and payment_status in ('pending', 'confirmed');
    if current_seats >= ev.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  -- Creator's STC Pay number (snapshot).
  select stc_pay_number into creator_stc
    from public.users
    where user_id = ev.creator_id;
  if creator_stc is null or creator_stc = '' then
    return json_build_object('status', 'creator_missing_number');
  end if;

  -- Insert pending row + capture snapshot of the creator's number.
  insert into public.event_participants (event_id, user_id, payment_status, paid_to_number)
  values (p_event_id, p_user_id, 'pending', creator_stc);

  -- If the joiner was on the waitlist, remove them.
  delete from public.event_waitlist
    where event_id = p_event_id and user_id = p_user_id;

  -- Enqueue a push to the creator (server-driven).
  insert into public.push_outbox (user_id, type, event_id)
  values (ev.creator_id, 'payment_submitted', p_event_id);

  return json_build_object(
    'status', 'submitted',
    'creator_id', ev.creator_id,
    'paid_to_number', creator_stc
  );
end;
$$;

grant execute on function public.submit_payment(uuid, uuid) to authenticated;
