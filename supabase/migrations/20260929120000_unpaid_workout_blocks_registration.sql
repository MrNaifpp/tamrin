-- An unpaid workout blocks registering until it is paid.
--
-- Spec: docs/superpowers/specs/2026-09-29-unpaid-debt-blocks-registration-design.md
--
-- 20260830200000 lifted the old registration refusal because it trapped people:
-- the error reached them in English and the unpaid workout was not on their
-- home page, so they could neither pay nor book. Both are answered now. The
-- refusal is Arabic and names the workout in its hint, and the workout stays on
-- home until it is paid, with Apple Pay on it.
--
-- One helper defines a debt, and everything that asks the question calls it,
-- so the block, the feed and the waitlist can never disagree about who owes.

-- ---------------------------------------------------------------------------
-- 1. What a debt is
-- ---------------------------------------------------------------------------
-- An unpaid seat, the member's own or a guest they added, on a workout in this
-- workspace that has ended and was not cancelled. Whether a transfer was ever
-- "declared" does not matter: that flow is retired, a seat is paid or it is not.
create or replace function public.unpaid_debt_event(p_workspace_id uuid, p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select e.id
  from public.event_participants ep
  join public.events e on e.id = ep.event_id
  where e.workspace_id = p_workspace_id
    and e.cancelled_at is null
    and coalesce(e.end_date, e.start_date) < now()
    and ep.payment_status = 'pending'
    and (ep.user_id = p_user_id
      or (ep.user_id is null and ep.added_by = p_user_id))
  order by e.start_date asc, e.id
  limit 1
$$;

revoke execute on function public.unpaid_debt_event(uuid, uuid)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. The block
-- ---------------------------------------------------------------------------
-- Reissued from 20260830200000 with two changes: the debt rule is added, and
-- the "Pending guest request must be resolved before self registration"
-- refusal is removed (a declare-then-confirm leftover; paying covers the member
-- and their guests together). Everything else is verbatim.
create or replace function public.guard_event_registration_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_payer_id uuid;
  v_series_key uuid;
  v_debt_event_id uuid;
begin
  select * into v_event
  from public.events
  where id = new.event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;

  if tg_table_name = 'event_waitlist' then
    if new.user_id is null
       or not public.is_workspace_member(v_event.workspace_id, new.user_id) then
      raise exception 'Not a workspace member';
    end if;
  elsif new.user_id is not null then
    if not public.is_workspace_member(v_event.workspace_id, new.user_id) then
      raise exception 'Not a workspace member';
    end if;
  elsif new.added_by is null
        or not public.is_workspace_member(v_event.workspace_id, new.added_by) then
    raise exception 'A guest must be added by a workspace member';
  end if;

  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
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
  where id = new.event_id
  for share;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  if tg_table_name = 'event_participants'
     and new.user_id is not null
     and new.user_id = v_event.creator_id
     and v_event.cancelled_at is null
     and not v_event.registration_locked then
    return new;
  end if;

  if tg_table_name = 'event_waitlist' then
    v_payer_id := new.user_id;
  else
    v_payer_id := coalesce(new.user_id, new.added_by);
  end if;

  -- The organizer is never blocked in their own workspace. This is also what
  -- keeps add_manual_participant working: its rows are added_by the organizer.
  if v_payer_id is not null
     and v_payer_id is distinct from v_event.creator_id
     and not public.is_workspace_owner(v_event.workspace_id, v_payer_id) then
    v_debt_event_id := public.unpaid_debt_event(v_event.workspace_id, v_payer_id);
    if v_debt_event_id is not null then
      raise exception using
        message = 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.',
        hint = 'payment_owed:' || v_debt_event_id::text;
    end if;
  end if;

  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then raise exception 'Registration is closed for this event'; end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Debts stop expiring
-- ---------------------------------------------------------------------------
-- The per-minute job stops calling waive_expired_event_debts(). The function
-- is left in place, unused: putting the call back is the whole undo.
create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.generate_recurring_events_internal();
end;
$$;

-- Old "I transferred" claims nobody answered were never waived (the waiver
-- skipped declared rows). Under the new rule they would suddenly block people
-- over months-old workouts, so they are forgiven once, like the other old debts.
update public.event_participants ep
set payment_status = 'waived'
from public.events e
where e.id = ep.event_id
  and ep.payment_status = 'pending'
  and ep.payment_declared_at is not null
  and e.cancelled_at is null
  and coalesce(e.end_date, e.start_date) < now();

comment on constraint event_participants_payment_status_check
  on public.event_participants is
  'waived: forgiven by the retired 24h waiver, or by the one-time cleanup in 20260929120000. Nothing writes it now.';

-- ---------------------------------------------------------------------------
-- 4. Every workout is shown
-- ---------------------------------------------------------------------------
-- Reissued from 20260831130000. The clause that hid a series' next occurrence
-- from a member who owed for an earlier one is removed: the refusal now happens
-- at registration. requires_payment_action and the clause that keeps an unpaid
-- ended workout listed drop `payment_declared_at is null`, matching
-- unpaid_debt_event, so the workout that blocks is always the one on home.
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
                and (mine.user_id = v_uid
                  or (mine.user_id is null and mine.added_by = v_uid))
            )
          )
        )
    ) x
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 5. Promotion skips a member who owes, and reminds the promoted one to pay
-- ---------------------------------------------------------------------------
-- Reissued from 20260822100000. Without the skip, the block above would raise
-- inside drain_waitlist and fail whatever freed the seat, such as another
-- member's withdrawal. A skipped member keeps their place in the queue.
create or replace function public.promote_from_waitlist(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_seats int;
  v_user_id uuid;
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then return null; end if;
  if v_event.registration_locked then return null; end if;
  if v_event.cancelled_at is not null then return null; end if;
  -- An uncapped event has no notion of a seat freeing up.
  if v_event.max_participants is null then return null; end if;

  -- Every live seat counts, paid or not.
  select count(*) into v_seats
  from public.event_participants
  where event_id = p_event_id
    and payment_status in ('pending', 'confirmed');
  if v_seats >= v_event.max_participants then return null; end if;

  select w.user_id into v_user_id
  from public.event_waitlist w
  where w.event_id = p_event_id
    and public.unpaid_debt_event(v_event.workspace_id, w.user_id) is null
  order by w.joined_at asc
  limit 1;
  if v_user_id is null then return null; end if;

  -- A paid event leaves the promoted seat owing; a free one is simply in.
  insert into public.event_participants
    (event_id, user_id, payment_status, paid_price_per_person, payment_group_size)
  values
    (p_event_id, v_user_id,
     case when coalesce(v_event.total_price, 0) > 0 then 'pending' else 'confirmed' end,
     v_event.price_per_person, 1);

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_user_id;

  insert into public.push_outbox (user_id, type, event_id)
  values (
    v_user_id,
    case when coalesce(v_event.total_price, 0) > 0
      then 'waitlist_promoted_unpaid' else 'waitlist_promoted' end,
    p_event_id
  );

  return v_user_id;
end;
$$;
revoke execute on function public.promote_from_waitlist(uuid) from public, anon;

notify pgrst, 'reload schema';
