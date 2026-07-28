-- Feed cards must distinguish a live series from an ended one: events keep
-- template_id after إنهاء التكرار (history preserved), so expose a computed
-- is_recurring flag checked against the template's ended_at.
-- Body otherwise identical to 20260702100200.

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
    select coalesce(json_agg(row_to_json(x) order by x.start_date asc), '[]'::json)
    from (
      select e.*,
             exists (
               select 1 from public.event_templates t
               where t.id = e.template_id and t.ended_at is null
             ) as is_recurring
      from public.events e
      where e.workspace_id = p_workspace_id
        and coalesce(e.end_date, e.start_date) >= now()
    ) x
  );
end;
$$;
