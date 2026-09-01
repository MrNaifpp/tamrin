-- The invitation stops being something a member has to earn back.
--
-- 20260830200000 lifted the registration refusal and said it was doing so for
-- the moment. This makes it permanent and takes the other half with it: an
-- undeclared payment no longer withholds the next occurrence's invitation or
-- its notification either. Every member of the workspace is invited when the
-- occurrence opens, and the debt expires on its own a day after the previous
-- exercise started.
--
-- What the app does instead is show the finished card over the new one while
-- the money is still owed. Nothing is taken away; something is added, and it
-- goes away by itself.
--
-- series_key stays. It is what keeps an occurrence attached to its series
-- across a template edit, and the advisory lock below still takes it.
--
-- Everything else in this function is unchanged and reissued verbatim: the
-- lock, the published_at stamp, the self-exclusion of creator and inviter, and
-- the push de-duplication against event_opened / event_invited.

CREATE OR REPLACE FUNCTION public.publish_recurring_event_internal(p_event_id uuid, p_invited_by uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_event public.events;
  v_series_key uuid;
begin
  select * into v_event
  from public.events
  where id = p_event_id;

  if v_event.id is null or v_event.cancelled_at is not null then
    return;
  end if;

  if v_event.template_id is not null then
    select series_key into v_series_key
    from public.event_templates
    where id = v_event.template_id;
    if v_series_key is not null then
      perform pg_advisory_xact_lock(hashtextextended(v_series_key::text, 0));
    end if;
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null or v_event.cancelled_at is not null then return; end if;

  update public.events
  set published_at = coalesce(published_at, now())
  where id = v_event.id
  returning * into v_event;

  with inserted as (
    insert into public.event_member_responses
      (event_id, user_id, status, invited_by, invited_at, updated_at)
    select v_event.id, wm.user_id, 'invited', p_invited_by, now(), now()
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id <> v_event.creator_id
      and wm.user_id <> p_invited_by
      and not exists (
        select 1
        from public.event_participants ep
        where ep.event_id = v_event.id
          and ep.user_id = wm.user_id
      )
    on conflict (event_id, user_id) do nothing
    returning user_id
  )
  insert into public.push_outbox (user_id, type, event_id)
  select i.user_id, 'event_invited', v_event.id
  from inserted i
  where not exists (
    select 1
    from public.push_outbox po
    where po.event_id = v_event.id
      and po.user_id = i.user_id
      and po.type in ('event_opened', 'event_invited')
  );
end;
$function$;

revoke execute on function public.publish_recurring_event_internal(uuid, uuid)
  from public, anon, authenticated;

-- Nothing is delayed any more, so there is no delayed invitation to deliver.
-- The trigger fired on a payment declaration purely to release what the gate
-- above was holding back.
drop trigger if exists trg_invite_after_recurring_debt_declaration
  on public.event_participants;
drop function if exists public.invite_after_recurring_debt_declaration();


-- The gate had a third layer, on the read side: the feed itself hid the next
-- occurrence from a member carrying a debt, so lifting the invitation alone
-- would have invited them to something they still could not see.
--
-- Only that block goes. The two conditions above it that keep the *finished*
-- card on the shelf while it is owed are what draws «دفع القطة», and they stay
-- exactly as they are — that card is the whole point of the new rule.
--
-- get_workspace_past_events carries no gate and is left untouched.

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
    ) x
  );
end;
$function$;


-- The fourth and last layer. A rejected declaration used to delete the
-- member's seat, their waitlist place and their invitation across every later
-- occurrence in the series — suspending them until they settled.
--
-- With the gate gone that revocation stands alone, and it punishes a debt the
-- waiver clears a day after the old exercise started. So the rejection now
-- does what it says and no more: the money is owed again, the «دفع القطة» card
-- comes back, and next week's place is untouched.

CREATE OR REPLACE FUNCTION public.reject_payment(p_event_id uuid, p_user_id uuid, p_creator_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_changed_rows integer := 0;
  v_revoked_future_seats integer := 0;
  v_reopened_event_ids uuid[] := '{}';
  v_series_key uuid;
  v_waiters json := '[]'::json;
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  if v_event.template_id is not null then
    select series_key into v_series_key
    from public.event_templates
    where id = v_event.template_id;
    if v_series_key is not null then
      perform pg_advisory_xact_lock(hashtextextended(v_series_key::text, 0));
    end if;
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.creator_id is distinct from v_uid then
    raise exception 'Not authorized: only the event creator can reject payments';
  end if;

  if coalesce(v_event.end_date, v_event.start_date) < now() then
    update public.event_participants
    set payment_declared_at = null
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending'
      and payment_declared_at is not null;
    get diagnostics v_changed_rows = row_count;

    -- A rejection reopens the debt and nothing more. It used to also strip the
    -- member's seat, waitlist place and invitation from every later occurrence
    -- in the series, to hold them behind the old-debt gate; that gate is gone,
    -- and the debt itself is waived a day after the old exercise started, so
    -- taking next week's place over it would punish something the app forgives
    -- hours later. revoked_future_seats stays in the result, now always 0.

  else
    delete from public.event_participants
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';
    get diagnostics v_changed_rows = row_count;

    -- The freed seat goes to whoever has waited longest, in the same
    -- transaction that freed it: a client that dies mid-call cannot
    -- lose the promotion.
    perform public.drain_waitlist(p_event_id);

    select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
    into v_waiters
    from public.event_waitlist
    where event_id = p_event_id;
  end if;

  if v_changed_rows = 0 then
    return json_build_object(
      'status', 'no_pending_row',
      'waiter_ids', '[]'::json
    );
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (p_user_id, 'payment_rejected', p_event_id);

  return json_build_object(
    'status', 'rejected',
    'joiner_id', p_user_id,
    'revoked_future_seats', v_revoked_future_seats,
    'waiter_ids', v_waiters
  );
end;
$function$;

notify pgrst, 'reload schema';
