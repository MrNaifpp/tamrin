-- Persist the SF Symbol chosen in the exercise creation flow. Existing
-- workspaces keep the product's historical soccer fallback.
alter table public.workspaces
  add column symbol text not null default 'figure.soccer';

alter table public.workspaces
  add constraint workspaces_symbol_not_blank
  check (length(trim(symbol)) between 1 and 80);

-- Keep the original one-argument RPC for older clients and simple workspace
-- creation surfaces. The identity wizard uses this overload to persist the
-- chosen symbol atomically with the workspace.
create function public.create_workspace(p_name text, p_symbol text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_symbol text := coalesce(nullif(trim(p_symbol), ''), 'figure.soccer');
  w public.workspaces;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_name is null or length(trim(p_name)) = 0 then
    raise exception 'Workspace name is required';
  end if;

  insert into public.workspaces (name, owner_id, symbol)
  values (trim(p_name), v_uid, v_symbol)
  returning * into w;

  insert into public.workspace_members (workspace_id, user_id)
  values (w.id, v_uid);

  return row_to_json(w);
end;
$$;

grant execute on function public.create_workspace(text, text) to authenticated;

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
           w.created_at,
           (select count(*) from public.workspace_members m2
             where m2.workspace_id = w.id) as member_count
    from public.workspaces w
    join public.workspace_members m
      on m.workspace_id = w.id and m.user_id = auth.uid()
  ) t;
$$;

grant execute on function public.get_my_workspaces() to authenticated;
