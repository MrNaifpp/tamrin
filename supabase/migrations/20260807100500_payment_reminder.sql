-- Organizer-initiated "pay your share" nudge for one participant, plus the
-- participant avatar the player sheet shows.
--
-- The one-hour cooldown lives here, not in the client: the client's disabled
-- button is a courtesy, this is the rule that survives a reinstall, a second
-- device, or a hand-rolled request.

alter table public.event_participants
  add column if not exists payment_reminder_sent_at timestamptz;

-- --------------------------------------------------------------------------
-- The roster has always carried an avatar_url field; it was hardcoded to null
-- because nothing rendered it. The player sheet now leads with the photo, so
-- the column is filled from the joined profile row.
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
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
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
-- remind_participant_payment: one push to one player, at most once an hour.
-- Refusals come back as a status string rather than an exception so the sheet
-- can say precisely why nothing was sent.
-- --------------------------------------------------------------------------
create or replace function public.remind_participant_payment(
  p_event_id uuid,
  p_participant_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_cooldown constant interval := interval '1 hour';
  v_event public.events;
  v_participant public.event_participants;
  v_next_allowed timestamptz;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can send payment reminders';
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;

  select * into v_participant
  from public.event_participants
  where id = p_participant_id and event_id = p_event_id
  for update;

  if v_participant.id is null then
    return json_build_object('status', 'not_found');
  end if;
  -- Guests and manually seated players have no account and no device token.
  if v_participant.user_id is null then
    return json_build_object('status', 'no_account');
  end if;
  if v_participant.user_id = v_uid then
    return json_build_object('status', 'is_self');
  end if;

  v_next_allowed := v_participant.payment_reminder_sent_at + v_cooldown;
  if v_participant.payment_reminder_sent_at is not null and v_next_allowed > now() then
    return json_build_object('status', 'too_soon', 'next_allowed_at', v_next_allowed);
  end if;

  update public.event_participants
  set payment_reminder_sent_at = now()
  where id = v_participant.id;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_participant.user_id, 'payment_reminder', p_event_id);

  return json_build_object(
    'status', 'sent',
    'next_allowed_at', now() + v_cooldown
  );
end;
$$;

revoke execute on function public.remind_participant_payment(uuid, uuid)
  from public, anon;
grant execute on function public.remind_participant_payment(uuid, uuid)
  to authenticated;

notify pgrst, 'reload schema';
