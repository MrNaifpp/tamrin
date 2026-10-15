-- The organizer taking himself off his own list.
--
-- remove_event_participant refused the creator's own row, on the reasoning
-- that an exercise without its creator on the list was a state the rest of the
-- app did not expect. It expects it fine: the organizer's powers all read
-- events.creator_id, not his seat, so he keeps editing, removing, reminding and
-- publishing a lineup after his seat is gone. What the refusal actually cost
-- was the ordinary case -- he set the exercise up and cannot make it -- where
-- the only way out was deleting the exercise for everybody.
--
-- He comes back the way anyone else does, through register_event_seat, which
-- is untouched here: on a paid exercise his returning seat falls due like any
-- other.
--
-- The cascade needs one repair before the refusal can go. Removing a member
-- takes the seats they brought with them, matched on added_by -- and the
-- players an organizer types in by hand carry added_by = the organizer with
-- guest_only false, so freeing his seat would have deleted every manually
-- seated player on the list. added_manually tells the two apart: a hand-typed
-- player belongs to the exercise, not to whoever typed him. Nobody but an
-- organizer can create such a row, so the clause changes nothing for members.
--
-- Everything else is reissued verbatim.

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

  if v_row.user_id is null then
    -- A guest or a manual registration: exactly this one seat.
    delete from public.event_participants where id = p_participant_id;
  else
    -- A member: their own seat plus the guests they brought. Players the
    -- organizer typed in are nobody's guests and stay where they are.
    delete from public.event_participants
    where event_id = v_row.event_id
      and (
        user_id = v_row.user_id
        or (added_by = v_row.user_id and not guest_only and not added_manually)
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

notify pgrst, 'reload schema';
