-- Paying moves after registering.
--
-- Until now a paid event seated nobody until they had walked the payment steps,
-- so the only states were «awaiting the organizer's confirmation» and
-- «confirmed». The seat and the money are now separate acts:
--
--   1. Register — the seat is held, nothing has been paid.        «دفع القطة»
--   2. Declare  — the player says they transferred.   «بانتظار تأكيد وصول القطة»
--   3. Confirm  — the organizer says it arrived.            «تم دفع القطة»
--
-- This is a new column rather than a fourth `payment_status`, deliberately.
-- Every capacity count, registration guard and organizer action in the
-- existing RPCs is written against `payment_status in ('pending','confirmed')`;
-- adding a status would have meant rewriting all of them and risking a seat
-- that no longer counts. A held seat stays `pending` exactly as before, and the
-- new column only records whether its owner has claimed to have paid yet.

alter table public.event_participants
  add column if not exists payment_declared_at timestamptz;

comment on column public.event_participants.payment_declared_at is
  'When the payer said they transferred. Null on a held-but-unpaid seat; set by declare_event_payment; irrelevant once payment_status = confirmed.';

-- Rows created before this migration were only ever inserted after the payer
-- had been through the payment steps, so they are all already declared.
update public.event_participants
set payment_declared_at = coalesce(payment_declared_at, created_at)
where payment_status in ('pending', 'confirmed')
  and payment_declared_at is null;

-- --------------------------------------------------------------------------
-- register_event_seat: take a seat on a paid event without paying for it.
--
-- The same guards a payment submission runs — locked registration, an existing
-- row, the seat cap, the price the client last saw — minus everything about a
-- payment method, which is not chosen until the player actually pays.
-- --------------------------------------------------------------------------
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
-- --------------------------------------------------------------------------
create or replace function public.declare_event_payment(
  p_event_id uuid,
  p_payment_method_id uuid
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
  v_declared int;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.total_price <= 0 then
    return json_build_object('status', 'free_event');
  end if;

  select * into v_method
  from public.workspace_payment_methods
  where id = p_payment_method_id
    and workspace_id = v_event.workspace_id;
  if v_method.id is null then
    return json_build_object('status', 'payment_method_required');
  end if;
  if not (
    p_payment_method_id = any(coalesce(v_event.payment_method_ids, '{}'::uuid[]))
    or p_payment_method_id = v_event.payment_method_id
  ) then
    return json_build_object('status', 'event_terms_changed');
  end if;

  with mine as (
    update public.event_participants ep
    set payment_declared_at = now(),
        payment_method_id = v_method.id,
        payment_provider = v_method.provider,
        paid_to_number = v_method.mobile_number,
        paid_to_iban = v_method.iban,
        paid_to_account_number = v_method.account_number
    where ep.event_id = p_event_id
      and ep.payment_status = 'pending'
      and ep.payment_declared_at is null
      and (ep.user_id = v_uid or (ep.user_id is null and ep.added_by = v_uid))
    returning 1
  )
  select count(*) into v_declared from mine;

  if v_declared = 0 then
    return json_build_object('status', 'nothing_due');
  end if;

  -- The organizer is the one who confirms it arrived, so they are told.
  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'payment_declared', p_event_id);

  return json_build_object('status', 'declared', 'seats', v_declared);
end;
$$;

revoke execute on function public.declare_event_payment(uuid, uuid) from public, anon;
grant execute on function public.declare_event_payment(uuid, uuid) to authenticated;

-- --------------------------------------------------------------------------
-- The roster carries the new field, so the payer's own screen and the
-- organizer's review can tell a held seat from a declared one.
-- --------------------------------------------------------------------------
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
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(x) order by x.joined_at asc), '[]'::json)
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
          then ep.payment_reminder_sent_at else null end as payment_reminder_sent_at
      from public.event_participants ep
      left join auth.users au on au.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id
    ) x
  );
end;
$$;

revoke execute on function public.get_event_participants_lifecycle_impl(uuid)
  from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- A finished exercise you still owe money on stays on your list.
--
-- The feed otherwise drops an event the moment it ends, which would hide the
-- only screen that can take the payment — someone who pays late would have
-- nowhere to pay. The exception is narrow and personal: it applies only to the
-- caller, only while they hold a seat that is not confirmed, and it disappears
-- the moment the organizer confirms it arrived.
-- --------------------------------------------------------------------------
create or replace function public.get_workspace_events(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(x) order by x.start_date asc), '[]'::json)
    from (
      select e.*,
             e.published_at is not null as is_published,
             e.cancelled_at is not null as is_cancelled,
             r.status as my_response_status,
             r.status as current_user_response,
             r.reason_code as current_user_reason_code,
             r.reason_text as current_user_reason_text,
             exists (
               select 1 from public.event_templates t
               where t.id = e.template_id and t.ended_at is null
             ) as is_recurring
      from public.events e
      left join public.event_member_responses r
        on r.event_id = e.id and r.user_id = v_uid
      where e.workspace_id = p_workspace_id
        and (e.published_at is not null or public.is_workspace_owner(e.workspace_id, v_uid))
        and (
          coalesce(e.end_date, e.start_date) >= now()
          or exists (
            select 1
            from public.event_participants ep
            where ep.event_id = e.id
              and ep.payment_status = 'pending'
              and (ep.user_id = v_uid or (ep.user_id is null and ep.added_by = v_uid))
          )
        )
    ) x
  );
end;
$$;

revoke execute on function public.get_workspace_events(uuid) from public, anon;
grant execute on function public.get_workspace_events(uuid) to authenticated;

notify pgrst, 'reload schema';
