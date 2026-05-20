-- Server-side function to create an event + add creator as participant.
-- Runs as SECURITY DEFINER so it bypasses RLS (auth.uid() is unreliable
-- in RLS context with asymmetric JWTs — supabase/supabase#42235).
-- The caller passes their user_id; the function trusts the SDK session.

create or replace function public.create_event(
  p_creator_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
begin
  insert into public.events (creator_id, name, location, description, start_date, end_date, image_url, max_participants)
  values (p_creator_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int) to authenticated;
grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int) to anon;
