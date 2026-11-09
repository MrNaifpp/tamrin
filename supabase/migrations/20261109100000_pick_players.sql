-- Picking players for a new event.
--
-- The last step of "تمرين جديد" lets an organizer seat people from their own
-- groups, or anyone who played in an event they ran. Spec:
-- docs/superpowers/specs/2026-11-09-new-event-pick-players-design.md

-- What the organizer can pick from: their own groups (with the members other
-- than themselves) and every app user who has played in one of their events.
-- Name-only guests have no account and never appear.
create or replace function public.get_my_pick_sources()
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception 'Not authorized';
  end if;

  return json_build_object(
    'groups', coalesce((
      select json_agg(g order by g.last_played_at desc nulls last, g.name)
      from (
        select
          w.id as workspace_id,
          w.name,
          (select max(e.start_date)
             from events e
            where e.workspace_id = w.id
              and e.start_date < now()
              and e.cancelled_at is null) as last_played_at,
          (select json_agg(json_build_object(
                    'user_id', u.user_id, 'name', u.name, 'avatar_url', u.avatar_url)
                  order by u.name)
             from workspace_members wm
             join users u on u.user_id = wm.user_id
            where wm.workspace_id = w.id
              and wm.user_id <> v_uid) as members
        from workspaces w
        where w.owner_id = v_uid
      ) g
      where g.members is not null
    ), '[]'::json),
    'past_players', coalesce((
      select json_agg(json_build_object(
               'user_id', u.user_id, 'name', u.name, 'avatar_url', u.avatar_url)
             order by u.name)
      from users u
      where u.user_id <> v_uid
        and exists (
          select 1
          from event_participants ep
          join events e on e.id = ep.event_id
          join workspaces w on w.id = e.workspace_id
          where ep.user_id = u.user_id
            and w.owner_id = v_uid
        )
    ), '[]'::json)
  );
end;
$$;

revoke execute on function public.get_my_pick_sources() from public, anon;
grant execute on function public.get_my_pick_sources() to authenticated;
