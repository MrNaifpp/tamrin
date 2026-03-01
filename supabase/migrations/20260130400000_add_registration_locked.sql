-- Add registration_locked flag to events and RPC to toggle it.

alter table public.events
  add column if not exists registration_locked boolean not null default false;

-- Toggle lock: only the creator can call this. Returns the new value.
create or replace function public.toggle_event_registration_lock(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  new_val boolean;
begin
  update public.events
  set registration_locked = not registration_locked
  where id = p_event_id and creator_id = p_user_id
  returning registration_locked into new_val;

  if new_val is null then
    raise exception 'Event not found or you are not the creator';
  end if;

  return new_val;
end;
$$;

grant execute on function public.toggle_event_registration_lock(uuid, uuid) to authenticated;
grant execute on function public.toggle_event_registration_lock(uuid, uuid) to anon;
