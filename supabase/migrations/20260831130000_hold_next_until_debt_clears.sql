-- While an exercise is still owed for, it is the only one that member sees.
--
-- 20260831110000 took this block out of get_workspace_events on the grounds
-- that nothing should be withheld over money. It comes back, because it now
-- means something different from what it meant then.
--
-- It used to be permanent: a member who never declared was never shown the
-- next occurrence again, and the only way out was to pay. That is why
-- 20260830200000 called the registration half of it cruel and lifted it — the
-- member could neither pay nor book.
--
-- Now it expires. waive_expired_event_debts() clears the debt 24 hours after
-- the old exercise started, and a waived row does not match the condition
-- below, so the next occurrence appears on its own. The block releases either
-- way: the moment they declare, or a day after kickoff whether they declare or
-- not. Nobody is locked out; they are asked once, for a day.
--
-- The condition is unchanged from the original and reissued verbatim, so a
-- finished occurrence still bypasses it — that is what keeps «دفع القطة» on
-- the shelf rather than hiding the very card being asked for.

CREATE OR REPLACE FUNCTION public.get_workspace_events(p_workspace_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
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
               select 1
               from public.event_templates event_template
               join public.event_templates active_template
                 on active_template.series_key = event_template.series_key
                and active_template.ended_at is null
               where event_template.id = e.template_id
             ) as is_recurring,
             exists (
               select 1
               from public.event_participants mine
               where mine.event_id = e.id
                 and mine.payment_status = 'pending'
                 and mine.payment_declared_at is null
                 and (mine.user_id = v_uid
                   or (mine.user_id is null and mine.added_by = v_uid))
             ) and e.cancelled_at is null
               and coalesce(e.end_date, e.start_date) < now()
               as requires_payment_action
      from public.events e
      left join public.event_member_responses r
        on r.event_id = e.id and r.user_id = v_uid
      where e.workspace_id = p_workspace_id
        and (e.published_at is not null
          or public.is_workspace_owner(e.workspace_id, v_uid))
        and (
          coalesce(e.end_date, e.start_date) >= now()
          or (
            e.cancelled_at is null
            and exists (
              select 1
              from public.event_participants mine
              where mine.event_id = e.id
                and mine.payment_status = 'pending'
                and mine.payment_declared_at is null
                and (mine.user_id = v_uid
                  or (mine.user_id is null and mine.added_by = v_uid))
            )
          )
        )
        and (
          public.is_workspace_owner(e.workspace_id, v_uid)
          or e.template_id is null
          or coalesce(e.end_date, e.start_date) < now()
          or not exists (
            select 1
            from public.events debt_event
            join public.event_templates debt_template
              on debt_template.id = debt_event.template_id
            join public.event_templates current_template
              on current_template.id = e.template_id
            join public.event_participants debt
              on debt.event_id = debt_event.id
            where debt_template.series_key = current_template.series_key
              and debt_event.cancelled_at is null
              and debt_event.start_date < e.start_date
              and coalesce(debt_event.end_date, debt_event.start_date) < now()
              and debt.payment_status = 'pending'
              and debt.payment_declared_at is null
              and (debt.user_id = v_uid
                or (debt.user_id is null and debt.added_by = v_uid))
          )
        )
    ) x
  );
end;
$function$

;

notify pgrst, 'reload schema';
