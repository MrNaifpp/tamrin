-- Series read + creator controls. All SECURITY DEFINER, guarded like the
-- July 2 RPC batch. Skipping/ending never deletes events.

create or replace function public.get_event_template(p_template_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  tpl public.event_templates;
begin
  select * into tpl from public.event_templates where id = p_template_id;
  if tpl.id is null then
    raise exception 'Template not found';
  end if;
  if not public.is_workspace_member(tpl.workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;
  return row_to_json(tpl);
end;
$$;

grant execute on function public.get_event_template(uuid) to authenticated;

-- Skip the next occurrence — only before it has been generated. p_event_id is
-- the event whose page hosted the button; any OTHER future series event means
-- the next occurrence is already open, so the creator deletes that event
-- instead (existing delete_event).
create or replace function public.skip_next_occurrence(p_template_id uuid, p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl public.event_templates;
  v_open_event uuid;
begin
  select * into tpl from public.event_templates where id = p_template_id for update;
  if tpl.id is null then
    raise exception 'Template not found';
  end if;
  if tpl.creator_id is distinct from auth.uid() then
    raise exception 'Not the series creator';
  end if;
  if tpl.ended_at is not null then
    raise exception 'Series has ended';
  end if;

  select id into v_open_event
    from public.events
    where template_id = p_template_id
      and start_date > now()
      and id <> p_event_id
    order by start_date asc
    limit 1;
  if v_open_event is not null then
    return json_build_object('status', 'already_open', 'event_id', v_open_event);
  end if;

  update public.event_templates set skip_next = true where id = p_template_id;
  return json_build_object('status', 'skipped', 'skipped_date', tpl.next_occurrence_at);
end;
$$;

grant execute on function public.skip_next_occurrence(uuid, uuid) to authenticated;

-- End the series. Existing events are untouched.
create or replace function public.end_recurrence(p_template_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl public.event_templates;
begin
  select * into tpl from public.event_templates where id = p_template_id for update;
  if tpl.id is null then
    raise exception 'Template not found';
  end if;
  if tpl.creator_id is distinct from auth.uid() then
    raise exception 'Not the series creator';
  end if;

  update public.event_templates set ended_at = now() where id = p_template_id and ended_at is null;
  return json_build_object('status', 'ended');
end;
$$;

grant execute on function public.end_recurrence(uuid) to authenticated;
