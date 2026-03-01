-- RPC to get participants for an event (with user profile info).
-- SECURITY DEFINER so it bypasses RLS.
create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  return (
    select coalesce(json_agg(row_to_json(t)), '[]'::json)
    from (
      select
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, u.email) as display_name,
        null::text as avatar_url
      from public.event_participants ep
      left join auth.users u on u.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id
      order by ep.created_at asc
    ) t
  );
end;
$$;

grant execute on function public.get_event_participants(uuid) to authenticated;
grant execute on function public.get_event_participants(uuid) to anon;

-- RPC to leave an event. Deletes the participant row.
create or replace function public.leave_event(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if ev.creator_id = p_user_id then
    raise exception 'Event creator cannot leave their own event';
  end if;

  delete from public.event_participants
  where event_id = p_event_id and user_id = p_user_id;

  return true;
end;
$$;

grant execute on function public.leave_event(uuid, uuid) to authenticated;
