-- Workspace RPCs. All SECURITY DEFINER; the caller is auth.uid() — these do
-- NOT trust a client-passed user id (unlike the older event RPCs).

-- ----------------------------------------------------------------------------
-- Internal: strip a user's participation from a workspace's UPCOMING events
-- (their own row, guest rows they added, and waitlist rows). Past events keep
-- history. Not granted to clients.
-- ----------------------------------------------------------------------------
create or replace function public.remove_workspace_participation(p_workspace_id uuid, p_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.event_participants ep
  using public.events e
  where ep.event_id = e.id
    and e.workspace_id = p_workspace_id
    and coalesce(e.end_date, e.start_date) >= now()
    and (ep.user_id = p_user_id or ep.added_by = p_user_id);

  delete from public.event_waitlist wl
  using public.events e
  where wl.event_id = e.id
    and e.workspace_id = p_workspace_id
    and wl.user_id = p_user_id;
end;
$$;

revoke execute on function public.remove_workspace_participation(uuid, uuid) from public, anon, authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.create_workspace(p_name text)
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

  insert into public.workspaces (name, owner_id)
  values (trim(p_name), v_uid)
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

grant execute on function public.create_workspace(text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_my_workspaces()
returns json
language sql
security definer
set search_path = public
stable
as $$
  select coalesce(json_agg(row_to_json(t) order by t.created_at asc), '[]'::json)
  from (
    select w.id, w.name, w.owner_id, w.invite_code, w.image_url, w.created_at,
           (select count(*) from public.workspace_members m2
             where m2.workspace_id = w.id) as member_count
    from public.workspaces w
    join public.workspace_members m
      on m.workspace_id = w.id and m.user_id = auth.uid()
  ) t;
$$;

grant execute on function public.get_my_workspaces() to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_workspace(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
begin
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select json_build_object(
      'workspace', row_to_json(w),
      'members', (
        select coalesce(json_agg(json_build_object(
          'user_id', m.user_id,
          'display_name', coalesce(usr.name, au.email),
          'avatar_url', usr.avatar_url,
          'joined_at', m.joined_at,
          'is_owner', m.user_id = w.owner_id
        ) order by (m.user_id = w.owner_id) desc, m.joined_at asc), '[]'::json)
        from public.workspace_members m
        left join public.users usr on usr.user_id = m.user_id
        left join auth.users au on au.id = m.user_id
        where m.workspace_id = w.id
      )
    )
    from public.workspaces w
    where w.id = p_workspace_id
  );
end;
$$;

grant execute on function public.get_workspace(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_workspace_by_invite(p_code text)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  w public.workspaces;
begin
  select * into w from public.workspaces where invite_code = p_code;
  if w.id is null then raise exception 'Invalid invite link'; end if;

  return json_build_object(
    'id', w.id,
    'name', w.name,
    'owner_name', coalesce((select name from public.users where user_id = w.owner_id), ''),
    'member_count', (select count(*) from public.workspace_members where workspace_id = w.id),
    'is_member', public.is_workspace_member(w.id, auth.uid())
  );
end;
$$;

grant execute on function public.get_workspace_by_invite(text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.join_workspace(p_code text)
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
  select * into w from public.workspaces where invite_code = p_code;
  if w.id is null then raise exception 'Invalid invite link'; end if;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid)
  on conflict (workspace_id, user_id) do nothing;

  return json_build_object('status', 'joined', 'workspace_id', w.id, 'name', w.name);
end;
$$;

grant execute on function public.join_workspace(text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.leave_workspace(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  deleted_rows int;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if exists (select 1 from public.workspaces where id = p_workspace_id and owner_id = v_uid) then
    raise exception 'Owner cannot leave the workspace; delete it instead';
  end if;

  delete from public.workspace_members
  where workspace_id = p_workspace_id and user_id = v_uid;
  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'not_member');
  end if;

  perform public.remove_workspace_participation(p_workspace_id, v_uid);
  return json_build_object('status', 'left');
end;
$$;

grant execute on function public.leave_workspace(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.remove_member(p_workspace_id uuid, p_member_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  deleted_rows int;
begin
  if not exists (select 1 from public.workspaces where id = p_workspace_id and owner_id = v_uid) then
    raise exception 'Not authorized: only the workspace owner can remove members';
  end if;
  if p_member_id = v_uid then
    raise exception 'Owner cannot remove themselves; delete the workspace instead';
  end if;

  delete from public.workspace_members
  where workspace_id = p_workspace_id and user_id = p_member_id;
  get diagnostics deleted_rows = row_count;
  if deleted_rows = 0 then
    return json_build_object('status', 'not_member');
  end if;

  perform public.remove_workspace_participation(p_workspace_id, p_member_id);
  return json_build_object('status', 'removed');
end;
$$;

grant execute on function public.remove_member(uuid, uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.update_workspace(p_workspace_id uuid, p_name text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  w public.workspaces;
begin
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  update public.workspaces
  set name = trim(p_name)
  where id = p_workspace_id and owner_id = v_uid
  returning * into w;

  if w.id is null then
    raise exception 'Not authorized: only the workspace owner can rename it';
  end if;
  return row_to_json(w);
end;
$$;

grant execute on function public.update_workspace(uuid, text) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.regenerate_invite_code(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
begin
  update public.workspaces
  set invite_code = public.new_invite_code()
  where id = p_workspace_id and owner_id = v_uid
  returning invite_code into v_code;

  if v_code is null then
    raise exception 'Not authorized: only the workspace owner can regenerate the invite link';
  end if;
  return json_build_object('invite_code', v_code);
end;
$$;

grant execute on function public.regenerate_invite_code(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.delete_workspace(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  deleted_id uuid;
begin
  if not exists (select 1 from public.workspaces where id = p_workspace_id and owner_id = v_uid) then
    raise exception 'Not authorized: only the workspace owner can delete it';
  end if;

  -- push_outbox.event_id has no FK; clean rows for this workspace's events.
  delete from public.push_outbox
  where event_id in (select id from public.events where workspace_id = p_workspace_id);

  delete from public.workspaces
  where id = p_workspace_id
  returning id into deleted_id;

  return json_build_object('status', 'deleted');
end;
$$;

grant execute on function public.delete_workspace(uuid) to authenticated;

-- ----------------------------------------------------------------------------
create or replace function public.get_workspace_events(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
begin
  if not public.is_workspace_member(p_workspace_id, auth.uid()) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(e) order by e.start_date asc), '[]'::json)
    from public.events e
    where e.workspace_id = p_workspace_id
      and coalesce(e.end_date, e.start_date) >= now()
  );
end;
$$;

grant execute on function public.get_workspace_events(uuid) to authenticated;
