-- The RPCs that write a sport.
--
-- Both symbol-taking overloads are replaced rather than left alone: they
-- inserted into `symbol`, and an insert into a generated column is an error.
-- They now map the symbol to a sport and let the symbol compute itself, so a
-- build in the field keeps working without knowing the enum exists.

create or replace function public.symbol_to_sport(p_symbol text)
returns public.sport
language sql
immutable
as $$
  select (case coalesce(nullif(trim(p_symbol), ''), 'figure.soccer')
    when 'figure.soccer'        then 'soccer'
    when 'figure.basketball'    then 'basketball'
    when 'figure.volleyball'    then 'volleyball'
    when 'figure.pickleball'    then 'padel'
    when 'figure.tennis'        then 'tennis'
    when 'figure.cricket'       then 'cricket'
    when 'figure.run'           then 'running'
    when 'figure.outdoor.cycle' then 'cycling'
    else 'soccer'
  end)::public.sport;
$$;

create or replace function public.create_workspace(p_name text, p_sport public.sport)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  insert into public.workspaces (name, owner_id, sport)
  values (trim(p_name), v_uid, coalesce(p_sport, 'soccer'))
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

-- The legacy overload, now a thin translation onto the one above.
create or replace function public.create_workspace(p_name text, p_symbol text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_workspace(p_name, public.symbol_to_sport(p_symbol));
end;
$$;

create or replace function public.update_workspace(
  p_workspace_id uuid,
  p_name text,
  p_sport public.sport
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_owner(p_workspace_id, v_uid) then
    raise exception 'Only the owner can update this exercise';
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  update public.workspaces
  set name = trim(p_name),
      sport = coalesce(p_sport, sport)
  where id = p_workspace_id
  returning * into w;

  return row_to_json(w);
end;
$$;

-- The sport joins the explicit select list. get_workspace returns row_to_json(w)
-- and therefore already carries it.
create or replace function public.get_my_workspaces()
returns json
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(json_agg(row_to_json(t) order by t.created_at asc), '[]'::json)
  from (
    select w.id, w.name, w.owner_id, w.invite_code, w.image_url, w.symbol,
           w.sport, w.color, w.created_at,
           (select count(*) from public.workspace_members m2
             where m2.workspace_id = w.id) as member_count
    from public.workspaces w
    join public.workspace_members m
      on m.workspace_id = w.id and m.user_id = auth.uid()
  ) t;
$$;

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

  -- The caller still sends an SF Symbol, because that is what the picker has
  -- always sent. It is translated once, here, and the symbol column computes
  -- itself from the result.
  update public.workspaces
  set name = v_workspace_name,
      sport = public.symbol_to_sport(v_symbol)
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
-- The colour-taking overloads.
--
-- This is the pair the app actually calls: the identity step picks a sport and
-- a colour together. The three argument symbol version was the last function
-- left inserting into `symbol`, which is now generated and rejects the write.

create or replace function public.create_workspace(
  p_name text,
  p_sport public.sport,
  p_color text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_color text := coalesce(nullif(trim(p_color), ''), 'blue');
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;
  if v_color not in ('blue', 'lime', 'red', 'orange', 'yellow', 'purple', 'pink') then
    v_color := 'blue';
  end if;

  insert into public.workspaces (name, owner_id, sport, color)
  values (trim(p_name), v_uid, coalesce(p_sport, 'soccer'), v_color)
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

create or replace function public.create_workspace(
  p_name text,
  p_symbol text,
  p_color text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.create_workspace(p_name, public.symbol_to_sport(p_symbol), p_color);
end;
$$;

revoke execute on function public.create_workspace(text, public.sport) from public, anon;
grant execute on function public.create_workspace(text, public.sport) to authenticated;
revoke execute on function public.update_workspace(uuid, text, public.sport) from public, anon;
grant execute on function public.update_workspace(uuid, text, public.sport) to authenticated;
revoke execute on function public.create_workspace(text, public.sport, text) from public, anon;
grant execute on function public.create_workspace(text, public.sport, text) to authenticated;
grant execute on function public.symbol_to_sport(text) to authenticated;

notify pgrst, 'reload schema';
