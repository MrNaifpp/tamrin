-- A bounded history feed for Home's "past" shelf.
--
-- Keep this separate from get_workspace_events: that RPC deliberately returns
-- only live/upcoming work, and Home eagerly loads rosters for every row it
-- returns. Mixing history into it would make the normal Home launch fetch a
-- roster (and, for owners, invitation responses) for every old exercise.

create index if not exists idx_events_workspace_start_date_id_desc
  on public.events(workspace_id, start_date desc, id desc);

create or replace function public.get_workspace_past_events(
  p_workspace_id uuid,
  p_before timestamptz default now(),
  p_limit integer default 60,
  p_offset integer default 0
)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  -- Protect both Postgres and the client from an accidentally unbounded call.
  v_limit integer := least(greatest(coalesce(p_limit, 60), 1), 120);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(
      json_agg(row_to_json(x) order by x.start_date desc, x.id desc),
      '[]'::json
    )
    from (
      select e.*,
             e.published_at is not null as is_published,
             e.cancelled_at is not null as is_cancelled,
             r.status as my_response_status,
             r.status as current_user_response,
             r.reason_code as current_user_reason_code,
             r.reason_text as current_user_reason_text,
             exists (
               select 1
               from public.event_templates t
               where t.id = e.template_id and t.ended_at is null
             ) as is_recurring
      from public.events e
      left join public.event_member_responses r
        on r.event_id = e.id and r.user_id = v_uid
      where e.workspace_id = p_workspace_id
        -- Match the visibility contract of get_workspace_events: members see
        -- published exercises, while the workspace owner may also see drafts.
        and (
          e.published_at is not null
          or public.is_workspace_owner(e.workspace_id, v_uid)
        )
        -- An exercise becomes historical after its explicit end, falling back
        -- to its start where legacy rows have no end date.
        and coalesce(e.end_date, e.start_date) < coalesce(p_before, now())
      -- The id tie-breaker makes offset pages deterministic when exercises
      -- share an identical start time.
      order by e.start_date desc, e.id desc
      limit v_limit
      offset v_offset
    ) x
  );
end;
$$;

revoke execute on function public.get_workspace_past_events(uuid, timestamptz, integer, integer)
  from public, anon;
grant execute on function public.get_workspace_past_events(uuid, timestamptz, integer, integer)
  to authenticated;

notify pgrst, 'reload schema';
