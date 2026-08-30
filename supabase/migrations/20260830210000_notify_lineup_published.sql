-- Tell the players when the split is out.
--
-- Publishing is the moment «التشكيلة» stops being the organizer's draft and
-- becomes the group's answer, and until now nobody was told. A player had to
-- open the exercise and guess that it was there.
--
-- Only on the first publish. The organizer corrects a lineup by dragging and
-- pressing «نشر» again, and that path runs through here too; announcing every
-- correction would make the notification worthless within one evening. The
-- transition is what is announced, so the trigger is the draft -> published
-- edge, not the act of pressing the button.
--
-- Everyone holding a seat is told, whether or not they were placed: being left
-- out of the eleven is exactly the kind of thing a player opens the app to find
-- out. The organizer is not told about his own publish.

create or replace function public.publish_event_lineup(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
  v_was_published boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null then raise exception 'Exercise not found'; end if;
  if not public.is_workspace_owner(v_workspace, v_uid) then
    raise exception 'Only the organizer can publish a lineup';
  end if;

  select status = 'published' into v_was_published
  from public.event_lineups
  where event_id = p_event_id;

  update public.event_lineups
  set status = 'published',
      published_at = coalesce(published_at, now()),
      updated_at = now(),
      updated_by = v_uid
  where event_id = p_event_id;

  if not found then
    raise exception 'There is no lineup to publish yet';
  end if;

  if not coalesce(v_was_published, false) then
    insert into public.push_outbox (user_id, type, event_id)
    select distinct seated.user_id, 'lineup_published', p_event_id
    from public.event_participants seated
    where seated.event_id = p_event_id
      and seated.user_id is not null
      and seated.user_id <> v_uid;
  end if;

  return public.get_event_lineup(p_event_id);
end;
$$;

revoke execute on function public.publish_event_lineup(uuid) from public, anon;
grant execute on function public.publish_event_lineup(uuid) to authenticated;

notify pgrst, 'reload schema';
