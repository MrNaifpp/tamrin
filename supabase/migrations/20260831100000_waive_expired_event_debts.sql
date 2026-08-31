-- A seat nobody paid for stops being owed a day after the exercise starts.
--
-- The deadline is measured from start_date, not from the end, so a two-hour
-- session and a four-hour one give the member the same 24 hours from a time
-- the group already knows. A cancelled exercise owes nothing, and a payment
-- the member declared is never touched — only silence expires.

alter table public.event_participants
  drop constraint if exists event_participants_payment_status_check;

alter table public.event_participants
  add constraint event_participants_payment_status_check
  check (payment_status in ('pending', 'confirmed', 'rejected', 'waived'));

comment on constraint event_participants_payment_status_check
  on public.event_participants is
  'waived is written only by waive_expired_event_debts(), 24h after start_date.';

create or replace function public.waive_expired_event_debts()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  with waived as (
    update public.event_participants ep
    set payment_status = 'waived'
    from public.events e
    where e.id = ep.event_id
      and ep.payment_status = 'pending'
      and ep.payment_declared_at is null
      and e.cancelled_at is null
      and e.start_date + interval '24 hours' <= now()
    returning ep.event_id
  )
  select count(*) into v_count from waived;
  return v_count;
end;
$$;

revoke execute on function public.waive_expired_event_debts()
  from public, anon, authenticated;

-- The generation body is unchanged; it only loses its name to the wrapper
-- below, so the waiver can ride the same per-minute job instead of adding a
-- second schedule that could drift from it.
CREATE OR REPLACE FUNCTION public.generate_recurring_events_internal()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  candidate record;
  tpl record;
  v_candidate_start timestamptz;
  v_candidate_end timestamptz;
  v_event_id uuid;
  v_event_start timestamptz;
  v_event_end timestamptz;
begin
  for candidate in
    select t.id, t.series_key
    from public.event_templates t
    where t.ended_at is null
      and t.published_at is not null
      and now() >= coalesce(
        t.next_release_at,
        t.next_occurrence_at - interval '7 days'
          + make_interval(mins => coalesce(t.duration_minutes, 0))
      )
    order by coalesce(t.next_release_at, t.next_occurrence_at), t.id
  loop
    if not pg_try_advisory_xact_lock(
      hashtextextended(candidate.series_key::text, 0)
    ) then
      continue;
    end if;

    -- If a legacy draft exists, lock the event before the template. This
    -- matches update_event_with_scope and avoids event↔template lock inversion
    -- while an organizer edits that same draft at its release boundary.
    v_event_id := null;
    v_event_start := null;
    v_event_end := null;
    select e.id, e.start_date, e.end_date
    into v_event_id, v_event_start, v_event_end
    from public.events e
    where e.template_id = candidate.id
      and e.published_at is null
      and e.cancelled_at is null
      and coalesce(e.end_date, e.start_date) >= now()
    order by e.start_date, e.id
    limit 1
    for update;

    select * into tpl
    from public.event_templates t
    where t.id = candidate.id
    for update;
    if not found
       or tpl.ended_at is not null
       or tpl.published_at is null
       or now() < coalesce(
         tpl.next_release_at,
         tpl.next_occurrence_at - interval '7 days'
           + make_interval(mins => coalesce(tpl.duration_minutes, 0))
       ) then
      continue;
    end if;

    -- A removed legacy creator must not abort unrelated templates in the same
    -- cron transaction.
    if not public.is_workspace_member(tpl.workspace_id, tpl.creator_id) then
      update public.event_templates
      set ended_at = coalesce(ended_at, now())
      where id = tpl.id;
      continue;
    end if;

    -- Heal a future draft made by the old generator. Its pointer was already
    -- advanced, so publishing it must not advance the template twice.
    if v_event_id is not null then
      insert into public.event_participants (event_id, user_id)
      values (v_event_id, tpl.creator_id)
      on conflict (event_id, user_id) where user_id is not null do nothing;

      perform public.publish_recurring_event_internal(v_event_id, tpl.creator_id);

      update public.event_templates
      set next_occurrence_at = case
            when next_occurrence_at <= v_event_start
              then v_event_start + interval '7 days'
            else next_occurrence_at
          end,
          next_release_at = coalesce(v_event_end, v_event_start)
      where id = tpl.id;
      continue;
    end if;

    -- Never backfill a burst of historical events after cron downtime.  Move
    -- the candidate to the first weekly start still in the future, then create
    -- at most one occurrence.
    v_candidate_start := tpl.next_occurrence_at;
    while v_candidate_start <= now() loop
      v_candidate_start := v_candidate_start + interval '7 days';
    end loop;
    v_candidate_end := case
      when tpl.duration_minutes is null then null
      else v_candidate_start + make_interval(mins => tpl.duration_minutes)
    end;

    if tpl.skip_next then
      update public.event_templates
      set next_occurrence_at = v_candidate_start + interval '7 days',
          next_release_at = coalesce(v_candidate_end, v_candidate_start),
          skip_next = false
      where id = tpl.id;
      continue;
    end if;

    insert into public.events
      (creator_id, workspace_id, name, location, description, start_date,
       end_date, image_url, max_participants, total_price, price_per_person,
       latitude, longitude, template_id, payment_method_id,
       payment_method_ids, published_at)
    values
      (tpl.creator_id, tpl.workspace_id, tpl.name, tpl.location,
       tpl.description, v_candidate_start, v_candidate_end, tpl.image_url,
       tpl.max_participants, tpl.total_price, 0, tpl.latitude, tpl.longitude,
       tpl.id, tpl.payment_method_id, tpl.payment_method_ids, now())
    on conflict (template_id, start_date) where template_id is not null
    do update set published_at = coalesce(events.published_at, excluded.published_at)
    returning id, start_date, end_date
    into v_event_id, v_event_start, v_event_end;

    insert into public.event_participants (event_id, user_id)
    values (v_event_id, tpl.creator_id)
    on conflict (event_id, user_id) where user_id is not null do nothing;

    perform public.publish_recurring_event_internal(v_event_id, tpl.creator_id);

    update public.event_templates
    set next_occurrence_at = v_candidate_start + interval '7 days',
        next_release_at = coalesce(v_event_end, v_event_start)
    where id = tpl.id;
  end loop;
end;
$function$;


revoke execute on function public.generate_recurring_events_internal()
  from public, anon, authenticated;

create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.generate_recurring_events_internal();
  perform public.waive_expired_event_debts();
end;
$$;

notify pgrst, 'reload schema';
