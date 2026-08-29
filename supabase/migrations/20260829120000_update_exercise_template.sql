-- One organizer action edits both halves of an exercise's identity:
--
-- * workspaces owns the exercise name used by group-level surfaces and the
--   sport symbol that selects its artwork/court/features;
-- * events + event_templates own the schedule and booking details.
--
-- Keeping the two writes inside one database function means a rejected series
-- edit can never leave the workspace renamed (or on another sport), and a
-- rejected workspace update can never leave the template half-edited.

-- Drop the pre-release signature if this migration was exercised manually on
-- a local stack. Payment destination drafts now enter this same transaction;
-- pre-saving them through a separate RPC could otherwise survive a failed edit.
drop function if exists public.update_exercise_template(
  uuid, uuid, text, text, text, text, text, timestamptz, timestamptz,
  int, int, double precision, double precision, uuid[]
);

create or replace function public.update_exercise_template(
  p_workspace_id uuid,
  p_event_id uuid,
  p_scope text,
  p_workspace_name text,
  p_symbol text,
  p_name text,
  p_location text,
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_max_participants int,
  p_total_price int,
  p_latitude double precision,
  p_longitude double precision,
  p_payment_methods jsonb,
  p_existing_payment_method_ids uuid[]
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_workspace public.workspaces;
  v_workspace_name text := nullif(trim(p_workspace_name), '');
  v_symbol text := nullif(trim(p_symbol), '');
  v_method_draft jsonb;
  v_method json;
  v_payment_method_ids uuid[] := coalesce(p_existing_payment_method_ids, '{}'::uuid[]);
  v_returned_event jsonb;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if v_workspace_name is null then raise exception 'Workspace name is required'; end if;
  if v_symbol is null or length(v_symbol) > 80 then
    raise exception 'Workspace sport symbol is invalid';
  end if;
  if jsonb_typeof(coalesce(p_payment_methods, '[]'::jsonb)) <> 'array' then
    raise exception 'Payment methods must be a JSON array';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(coalesce(p_payment_methods, '[]'::jsonb)) draft
    group by draft->>'provider'
    having count(*) > 1
  ) then
    raise exception 'Payment providers must be unique';
  end if;

  -- Workspace first matches deletion's parent-before-child lock order. The
  -- nested update then follows its established event-before-template order.
  select * into v_workspace
  from public.workspaces
  where id = p_workspace_id
  for update;
  if v_workspace.id is null then raise exception 'Workspace not found'; end if;
  if v_workspace.owner_id is distinct from v_uid then
    raise exception 'Only the workspace owner can edit the exercise template';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.workspace_id is distinct from p_workspace_id then
    raise exception 'Event does not belong to workspace';
  end if;

  -- Immutable destination versions are created/reused inside this function's
  -- transaction. Any later event/template/workspace error rolls them back too.
  for v_method_draft in
    select value
    from jsonb_array_elements(coalesce(p_payment_methods, '[]'::jsonb))
  loop
    if jsonb_typeof(v_method_draft) <> 'object' then
      raise exception 'Each payment method must be a JSON object';
    end if;
    v_method := public.upsert_workspace_payment_method(
      p_workspace_id,
      v_method_draft->>'provider',
      v_method_draft->>'mobile_number',
      v_method_draft->>'iban',
      v_method_draft->>'account_number'
    );
    v_payment_method_ids := array_append(
      v_payment_method_ids,
      (v_method->>'id')::uuid
    );
  end loop;

  perform public.update_event_with_scope(
    p_event_id,
    p_scope,
    p_name,
    p_location,
    p_start_date,
    p_end_date,
    p_max_participants,
    p_total_price,
    p_latitude,
    p_longitude,
    v_payment_method_ids
  );

  update public.workspaces
  set name = v_workspace_name,
      symbol = v_symbol
  where id = p_workspace_id
  returning * into v_workspace;

  select to_jsonb(e) || jsonb_build_object(
    'is_recurring', exists (
      select 1
      from public.event_templates t
      where t.id = e.template_id and t.ended_at is null
    ),
    'requires_payment_action', false
  )
  into v_returned_event
  from public.events e
  where e.id = p_event_id;

  return json_build_object(
    'workspace', row_to_json(v_workspace)::jsonb || jsonb_build_object(
      'member_count', (
        select count(*)
        from public.workspace_members wm
        where wm.workspace_id = p_workspace_id
      )
    ),
    'event', v_returned_event,
    'payment_methods', coalesce((
      select json_agg(row_to_json(pm) order by selected.ordinality)
      from unnest(v_payment_method_ids) with ordinality as selected(id, ordinality)
      join public.workspace_payment_methods pm on pm.id = selected.id
    ), '[]'::json)
  );
end;
$$;

revoke execute on function public.update_exercise_template(
  uuid, uuid, text, text, text, text, text, timestamptz, timestamptz,
  int, int, double precision, double precision, jsonb, uuid[]
) from public, anon;
grant execute on function public.update_exercise_template(
  uuid, uuid, text, text, text, text, text, timestamptz, timestamptz,
  int, int, double precision, double precision, jsonb, uuid[]
) to authenticated;

notify pgrst, 'reload schema';
