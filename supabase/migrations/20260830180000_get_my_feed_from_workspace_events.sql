-- Home's one request stops reimplementing the shelf query.
--
-- get_my_feed was written by copying get_workspace_events' select list and
-- swapping its workspace filter for a membership one. That copy was already a
-- version behind: get_workspace_events had grown `requires_payment_action`, and
-- a WHERE clause that deliberately keeps a finished occurrence in the feed while
-- the member still owes it and has not declared. The copy carried neither.
--
-- The result was a dead end. An unpaid finished exercise fell out of the feed,
-- so the shelf's «دفع القطة» action never appeared; the archive is read only, so
-- there was nowhere to declare from; and the registration guard refuses the next
-- occurrence in the series until that debt is declared. The member could not pay
-- and therefore could not register, with no way out inside the app.
--
-- So this stops copying. The feed calls get_workspace_events once per workspace
-- and returns exactly what it returns, the same way rosters and apologies
-- already come from the functions that own them. One authority for the row
-- shape, and no second filter to fall behind.

create or replace function public.get_my_feed()
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

  return (
    with my_events as (
      select elem as row_json, (elem->>'id')::uuid as event_id
      from (
        select workspace_id
        from public.workspace_members
        where user_id = v_uid
        offset 0   -- fence: the membership filter must run before the lateral,
      ) m          -- because get_workspace_events raises for a non member.
      cross join lateral json_array_elements(public.get_workspace_events(m.workspace_id)) as elem
    )
    select json_build_object(
      'workspaces', public.get_my_workspaces(),

      -- Ordered across every group, which is what the shelf shows. Timestamps
      -- are ISO, so ordering the text orders the moment.
      'events', (
        select coalesce(json_agg(row_json order by row_json->>'start_date'), '[]'::json)
        from my_events
      ),

      -- Rosters and apologies for exactly the events above, so an occurrence
      -- held back for an unpaid contribution still arrives with its roster.
      'participants', (
        select coalesce(json_agg(t.j), '[]'::json)
        from (
          select jsonb_set(p::jsonb, '{event_id}', to_jsonb(e.event_id))::json as j
          from my_events e
          cross join lateral json_array_elements(public.get_event_participants(e.event_id)) as p
        ) t
      ),

      'responses', (
        select coalesce(json_agg(t.j), '[]'::json)
        from (
          select jsonb_set(r::jsonb, '{event_id}', to_jsonb(e.event_id))::json as j
          from my_events e
          cross join lateral json_array_elements(public.get_event_member_responses(e.event_id)) as r
        ) t
      )
    )
  );
end;
$$;

revoke execute on function public.get_my_feed() from public, anon;
grant execute on function public.get_my_feed() to authenticated;

notify pgrst, 'reload schema';
