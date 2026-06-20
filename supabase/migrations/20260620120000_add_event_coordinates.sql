-- Add latitude/longitude to events and update create_event RPC to persist coordinates.

alter table public.events
  add column if not exists latitude double precision,
  add column if not exists longitude double precision;

-- Drop the previous overload (without coordinates) to avoid PostgREST function ambiguity.
drop function if exists public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal);

-- Recreate create_event with latitude/longitude params
create or replace function public.create_event(
  p_creator_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null,
  p_total_price int default 0,
  p_price_per_person decimal default 0,
  p_latitude double precision default null,
  p_longitude double precision default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
begin
  insert into public.events (creator_id, name, location, description, start_date, end_date, image_url, max_participants, total_price, price_per_person, latitude, longitude)
  values (p_creator_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants, p_total_price, p_price_per_person, p_latitude, p_longitude)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision) to authenticated;
grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision) to anon;
