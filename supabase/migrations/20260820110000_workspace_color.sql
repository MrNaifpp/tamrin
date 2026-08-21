-- Persist the colour chosen beside the symbol in the exercise creation flow.
-- The symbol was already stored; the colour was picked, drawn once in the
-- wizard, and then thrown away — so every group fell back to a hue derived
-- from its id and the choice never survived the screen it was made on.
--
-- Existing workspaces default to the same colour a new draft starts on.

alter table public.workspaces
  add column if not exists color text not null default 'blue';

alter table public.workspaces
  drop constraint if exists workspaces_color_known;
alter table public.workspaces
  add constraint workspaces_color_known
  check (color in ('blue', 'lime', 'red', 'orange', 'yellow', 'purple', 'pink'));

-- The two-argument overload stays for clients that only know the symbol.
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
declare
  v_uid uuid := auth.uid();
  v_symbol text := coalesce(nullif(trim(p_symbol), ''), 'figure.soccer');
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

  insert into public.workspaces (name, owner_id, symbol, color)
  values (trim(p_name), v_uid, v_symbol, v_color)
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

revoke execute on function public.create_workspace(text, text, text) from public, anon;
grant execute on function public.create_workspace(text, text, text) to authenticated;

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
           w.color, w.created_at,
           (select count(*) from public.workspace_members m2
             where m2.workspace_id = w.id) as member_count
    from public.workspaces w
    join public.workspace_members m
      on m.workspace_id = w.id and m.user_id = auth.uid()
  ) t;
$$;

grant execute on function public.get_my_workspaces() to authenticated;

-- --------------------------------------------------------------------------
-- The members payload carries each player's position, so the group's member
-- list can open the same player sheet the exercise roster opens — the sheet
-- cannot offer a rating without knowing which weights to blend it with.
-- --------------------------------------------------------------------------
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
  if v_uid is null then raise exception 'Not authenticated'; end if;
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
          'postion', usr.postion,
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

revoke execute on function public.get_workspace(uuid) from public, anon;
grant execute on function public.get_workspace(uuid) to authenticated;

notify pgrst, 'reload schema';
