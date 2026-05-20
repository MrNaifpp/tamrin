-- Public event lookup (bypasses RLS so anyone with the link can view).
-- Also: join_event RPC that respects registration_locked.

create or replace function public.get_event_by_id(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  ev public.events;
begin
  select * into ev from public.events where id = p_event_id;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  return row_to_json(ev);
end;
$$;

grant execute on function public.get_event_by_id(uuid) to authenticated;
grant execute on function public.get_event_by_id(uuid) to anon;

-- Join event: inserts participant row. Checks registration_locked and prevents duplicates.
create or replace function public.join_event(p_event_id uuid, p_user_id uuid)
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
  if ev.registration_locked then
    raise exception 'Registration is closed for this event';
  end if;

  insert into public.event_participants (event_id, user_id)
  values (p_event_id, p_user_id)
  on conflict (event_id, user_id) do nothing;

  return true;
end;
$$;

grant execute on function public.join_event(uuid, uuid) to authenticated;
grant execute on function public.join_event(uuid, uuid) to anon;
