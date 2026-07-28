-- Enable weekly recurrence on an existing event, from its settings sheet.
-- Creates the template (or reactivates the ended one the event is already
-- linked to) and stamps the event. Disable = existing end_recurrence.

create or replace function public.enable_recurrence(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  ev public.events;
  tpl public.event_templates;
  v_duration_minutes int;
begin
  select * into ev from public.events where id = p_event_id for update;
  if ev.id is null then
    raise exception 'Event not found';
  end if;
  if ev.creator_id is distinct from auth.uid() then
    raise exception 'Not the event creator';
  end if;

  if ev.template_id is not null then
    select * into tpl from public.event_templates where id = ev.template_id for update;
  end if;

  -- Already recurring: no-op, return the live template.
  if tpl.id is not null and tpl.ended_at is null then
    return row_to_json(tpl);
  end if;

  -- Reactivate the ended series; a stale anchor is caught up by the generator.
  if tpl.id is not null then
    update public.event_templates
      set ended_at = null, skip_next = false
      where id = tpl.id
      returning * into tpl;
    return row_to_json(tpl);
  end if;

  if ev.end_date is not null then
    v_duration_minutes := (extract(epoch from (ev.end_date - ev.start_date)) / 60)::int;
  end if;

  insert into public.event_templates
    (workspace_id, creator_id, name, location, description, image_url,
     latitude, longitude, total_price, price_per_person, max_participants,
     duration_minutes, recurrence, next_occurrence_at)
  values
    (ev.workspace_id, ev.creator_id, ev.name, ev.location, ev.description, ev.image_url,
     ev.latitude, ev.longitude, ev.total_price, ev.price_per_person, ev.max_participants,
     v_duration_minutes, 'weekly', ev.start_date + interval '7 days')
  returning * into tpl;

  update public.events set template_id = tpl.id where id = p_event_id;

  return row_to_json(tpl);
end;
$$;

grant execute on function public.enable_recurrence(uuid) to authenticated;
