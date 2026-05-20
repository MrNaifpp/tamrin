-- Add pricing columns to events and update create_event RPC.

alter table public.events
  add column if not exists total_price int not null default 0,
  add column if not exists price_per_person decimal(10,2) not null default 0;

-- Recreate create_event with price params
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
  p_price_per_person decimal default 0
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
begin
  insert into public.events (creator_id, name, location, description, start_date, end_date, image_url, max_participants, total_price, price_per_person)
  values (p_creator_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants, p_total_price, p_price_per_person)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal) to authenticated;
grant execute on function public.create_event(uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal) to anon;
