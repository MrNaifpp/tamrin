-- A past workout showed nobody registered in the iOS app.
--
-- waive_expired_event_debts() marks an unpaid seat 'waived' 24 hours after
-- the workout starts. App builds released before 2026-10-08 decode
-- payment_status into an enum of pending/confirmed/rejected, so a single
-- waived row failed the whole roster and the page read «كن أول المسجلين».
-- get_my_feed builds its rosters from this function too.
--
-- The roster now reports a waived seat's payment_status as null, which every
-- client already reads as a held seat that owes nothing — exactly what waived
-- means. The table keeps 'waived'; the debt checks read the table, not this.
--
-- Only the wrapper changes. Its guards are copied unchanged from
-- 20260725120000_event_lifecycle.sql, and the roster body it calls
-- (get_event_participants_lifecycle_impl) is left as it is.

create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null
     and not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Event is not published';
  end if;

  return (
    select coalesce(
      json_agg(
        case when row->>'payment_status' = 'waived'
          then (row::jsonb || '{"payment_status": null}'::jsonb)::json
          else row
        end
        order by position
      ),
      '[]'::json
    )
    from json_array_elements(public.get_event_participants_lifecycle_impl(p_event_id))
      with ordinality as t(row, position)
  );
end;
$$;

notify pgrst, 'reload schema';
