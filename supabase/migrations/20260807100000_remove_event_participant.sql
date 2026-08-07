-- The organizer removing someone from one exercise.
--
-- Everything that existed before is either self-service (decline_event,
-- leave_event) or narrow (reject_payment only touches pending rows,
-- remove_manual_participant only touches rows the organizer typed in). None of
-- them let the organizer free the seat of a member who has already registered,
-- which is the ordinary case of "he can't make it, take him off the list".
--
-- Removing a payer takes their guests with them: those seats were bought as one
-- group and would otherwise be left behind with nobody responsible for them —
-- the same rule reject_payment already applies.

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

  return json_build_object('status', 'removed', 'removed_count', v_removed);
end;
$$;

revoke execute on function public.remove_event_participant(uuid)
  from public, anon;
grant execute on function public.remove_event_participant(uuid)
  to authenticated;

notify pgrst, 'reload schema';
