-- create_event gains p_recurrence ('none' | 'weekly'). Weekly also inserts an
-- event_templates row and stamps the first event's template_id — one transaction.
-- Body otherwise identical to 20260702100300.
-- Drop the previous overload to avoid PostgREST ambiguity.

drop function if exists public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision);

create or replace function public.create_event(
  p_creator_id uuid,
  p_workspace_id uuid,
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
  p_longitude double precision default null,
  p_recurrence text default 'none'
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  new_event public.events;
  v_template_id uuid;
  v_duration_minutes int;
begin
  if p_creator_id is distinct from auth.uid() then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_member(p_workspace_id, p_creator_id) then
    raise exception 'Not a workspace member';
  end if;
  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Invalid recurrence: %', p_recurrence;
  end if;

  if p_recurrence = 'weekly' then
    if p_end_date is not null then
      v_duration_minutes := (extract(epoch from (p_end_date - p_start_date)) / 60)::int;
    end if;
    insert into public.event_templates
      (workspace_id, creator_id, name, location, description, image_url,
       latitude, longitude, total_price, price_per_person, max_participants,
       duration_minutes, recurrence, next_occurrence_at)
    values
      (p_workspace_id, p_creator_id, p_name, p_location, p_description, p_image_url,
       p_latitude, p_longitude, p_total_price, p_price_per_person, p_max_participants,
       v_duration_minutes, 'weekly', p_start_date + interval '7 days')
    returning id into v_template_id;
  end if;

  insert into public.events (creator_id, workspace_id, name, location, description, start_date, end_date, image_url, max_participants, total_price, price_per_person, latitude, longitude, template_id)
  values (p_creator_id, p_workspace_id, p_name, p_location, p_description, p_start_date, p_end_date, p_image_url, p_max_participants, p_total_price, p_price_per_person, p_latitude, p_longitude, v_template_id)
  returning * into new_event;

  insert into public.event_participants (event_id, user_id)
  values (new_event.id, p_creator_id);

  return row_to_json(new_event);
end;
$$;

grant execute on function public.create_event(uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int, decimal, double precision, double precision, text) to authenticated;
