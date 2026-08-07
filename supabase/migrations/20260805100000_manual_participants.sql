-- Manual registration: the organizer writes a name and that person takes a
-- seat without ever holding an account. The row reuses the existing guest
-- shape (null user_id + guest_name + added_by), so seat counting, capacity,
-- reminders and deletion cascades all keep working untouched.
--
-- `added_manually` is what separates these rows from the guests a paying
-- member brings along: only manual rows may be removed by the organizer, and
-- only they are labelled as such on the roster.

alter table public.event_participants
  add column if not exists added_manually boolean not null default false;

comment on column public.event_participants.added_manually is
  'True when the organizer registered this person by name. Such a row has no user_id and no payment submission behind it.';

-- --------------------------------------------------------------------------
-- Register someone by name. Organizer-only, and subject to the same seat cap
-- and lifecycle rules a member registration goes through: the seat is real, so
-- it cannot be created on a draft, a cancelled occurrence, or a closed list.
--
-- Paid events: the organizer is vouching for the person and settles the money
-- with them outside the app, so the seat is confirmed straight away and no
-- payment destination is snapshotted.
-- --------------------------------------------------------------------------
create or replace function public.add_manual_participant(
  p_event_id uuid,
  p_name text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_name text;
  v_seats int;
  v_participant_id uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;

  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized: only the organizer can register someone manually';
  end if;

  -- Collapse the whitespace a phone keyboard leaves behind so "  خالد   م " and
  -- "خالد م" are the same person for the duplicate check below.
  v_name := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  if v_name = '' then
    return json_build_object('status', 'empty_name');
  end if;
  v_name := left(v_name, 60);

  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;

  -- A retried request must not seat the same person twice. Two real people who
  -- share a name are still addable — the organizer distinguishes them.
  if exists (
    select 1 from public.event_participants
    where event_id = p_event_id
      and added_manually
      and lower(guest_name) = lower(v_name)
  ) then
    return json_build_object('status', 'duplicate_name', 'name', v_name);
  end if;

  if v_event.max_participants is not null then
    select count(*) into v_seats
      from public.event_participants
      where event_id = p_event_id
        and payment_status in ('pending', 'confirmed');
    if v_seats + 1 > v_event.max_participants then
      return json_build_object('status', 'seats_full');
    end if;
  end if;

  insert into public.event_participants (
    event_id, user_id, guest_name, added_by, added_manually, payment_status
  )
  values (p_event_id, null, v_name, v_uid, true, 'confirmed')
  returning id into v_participant_id;

  return json_build_object(
    'status', 'added',
    'participant_id', v_participant_id,
    'name', v_name
  );
end;
$$;

revoke execute on function public.add_manual_participant(uuid, text)
  from public, anon;
grant execute on function public.add_manual_participant(uuid, text)
  to authenticated;

-- --------------------------------------------------------------------------
-- Remove a manual registration. A person with no account cannot withdraw
-- themselves, so the organizer who seated them is the one who frees the seat.
-- Deliberately narrow: a member's own row and the guests a member paid for are
-- not reachable here — those go through decline_event / reject_payment, which
-- keep the payment group intact.
-- --------------------------------------------------------------------------
create or replace function public.remove_manual_participant(
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
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_row
  from public.event_participants
  where id = p_participant_id;
  if v_row.id is null then
    return json_build_object('status', 'not_found');
  end if;
  if not v_row.added_manually then
    raise exception 'Only a manually added registration can be removed this way';
  end if;

  select * into v_event from public.events where id = v_row.event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;

  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized: only the organizer can remove a manual registration';
  end if;

  delete from public.event_participants where id = p_participant_id;

  return json_build_object('status', 'removed');
end;
$$;

revoke execute on function public.remove_manual_participant(uuid)
  from public, anon;
grant execute on function public.remove_manual_participant(uuid)
  to authenticated;

-- --------------------------------------------------------------------------
-- Roster output gains the flag. Body otherwise identical to the version this
-- replaces (20260724120000), which the lifecycle wrapper still calls.
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
        null::text as avatar_url,
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
        ep.added_manually
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

notify pgrst, 'reload schema';
