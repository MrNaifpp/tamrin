-- Home in one request.
--
-- Home is every exercise the person is part of, nearest first, so it was asking
-- for the workspace list, then each workspace's events, then each workspace's
-- detail, then a roster for every event, and for an organizer the invitation
-- responses on top. That is 1 + 2N + M requests before the first card can be
-- trusted, run in sequence.
--
-- The rows are the ones get_workspace_events already returns, with the
-- workspace filter replaced by membership. The visibility rule travels with
-- them: an unpublished exercise is the organizer's alone.
--
-- Rosters and apologies come out of the functions that already answer for them,
-- one call per event, rather than a second copy of their select lists. Those
-- functions decide what a given reader may see: the payment destination is the
-- payer's and the organizer's, the reminder stamp is the organizer's alone, and
-- an apology is the organizer's except for the member's own. Rewriting that
-- rule here would mean maintaining it twice and leaking the day the two drift.
--
-- The `offset 0` on the event subqueries is an optimization fence. Those
-- functions raise for a non member, so the membership filter has to run before
-- the lateral does, not merely alongside it.

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

  return json_build_object(
    'workspaces', public.get_my_workspaces(),

    'events', (
      select coalesce(json_agg(row_to_json(x) order by x.start_date asc), '[]'::json)
      from (
        select e.*,
               e.published_at is not null as is_published,
               e.cancelled_at is not null as is_cancelled,
               r.status as my_response_status,
               r.status as current_user_response,
               r.reason_code as current_user_reason_code,
               r.reason_text as current_user_reason_text,
               exists (
                 select 1 from public.event_templates t
                 where t.id = e.template_id and t.ended_at is null
               ) as is_recurring
        from public.events e
        left join public.event_member_responses r
          on r.event_id = e.id and r.user_id = v_uid
        where e.workspace_id in (
                select m.workspace_id from public.workspace_members m
                where m.user_id = v_uid
              )
          and (e.published_at is not null or public.is_workspace_owner(e.workspace_id, v_uid))
          and coalesce(e.end_date, e.start_date) >= now()
      ) x
    ),

    'participants', (
      select coalesce(json_agg(t.j), '[]'::json)
      from (
        select jsonb_set(elem::jsonb, '{event_id}', to_jsonb(e.id))::json as j
        from (
          select id, workspace_id
          from public.events
          where workspace_id in (
                  select m.workspace_id from public.workspace_members m
                  where m.user_id = v_uid
                )
            and (published_at is not null or public.is_workspace_owner(workspace_id, v_uid))
            and coalesce(end_date, start_date) >= now()
          offset 0
        ) e
        cross join lateral json_array_elements(public.get_event_participants(e.id)) as elem
      ) t
    ),

    'responses', (
      select coalesce(json_agg(t.j), '[]'::json)
      from (
        select jsonb_set(elem::jsonb, '{event_id}', to_jsonb(e.id))::json as j
        from (
          select id
          from public.events
          where workspace_id in (
                  select m.workspace_id from public.workspace_members m
                  where m.user_id = v_uid
                )
            and (published_at is not null or public.is_workspace_owner(workspace_id, v_uid))
            and coalesce(end_date, start_date) >= now()
          offset 0
        ) e
        cross join lateral json_array_elements(public.get_event_member_responses(e.id)) as elem
      ) t
    )
  );
end;
$$;

revoke execute on function public.get_my_feed() from public, anon;
grant execute on function public.get_my_feed() to authenticated;

notify pgrst, 'reload schema';
