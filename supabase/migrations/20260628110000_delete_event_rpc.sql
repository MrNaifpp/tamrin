-- Delete an event. Only the creator can call this. Returns true on success.
-- event_participants & event_waitlist rows are removed automatically via their
-- existing `references events(id) on delete cascade` foreign keys.

create or replace function public.delete_event(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  deleted_id uuid;
begin
  -- Clean up pending notifications (push_outbox.event_id has no FK / no cascade).
  delete from public.push_outbox where event_id = p_event_id;

  delete from public.events
  where id = p_event_id and creator_id = p_user_id
  returning id into deleted_id;

  if deleted_id is null then
    raise exception 'Event not found or you are not the creator';
  end if;

  return true;
end;
$$;

grant execute on function public.delete_event(uuid, uuid) to authenticated;
grant execute on function public.delete_event(uuid, uuid) to anon;
