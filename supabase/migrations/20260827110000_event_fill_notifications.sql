-- Tell an organizer, unprompted, each time their session crosses a quarter of
-- its capacity — and when it fills.
--
-- Eight functions insert into event_participants (add_manual_participant,
-- create_event, generate_recurring_events, join_event, promote_from_waitlist,
-- register_event_guest_batch_impl, register_event_seat, and
-- submit_payment_v2_before_guest_only). This is a trigger rather than eight
-- call sites because the ninth path added later would silently not notify —
-- exactly how 20260820100000_pay_after_registering left the guest path behind.

alter table public.events
  add column if not exists fill_notified_pct smallint not null default 0;

comment on column public.events.fill_notified_pct is
  'High-water mark of the fill milestone already announced to the owner: 0, 25, 50, 75 or 100. Never decreases, so a withdrawal cannot re-arm a milestone.';

create or replace function public.announce_event_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_seated int;
  v_pct int;
  v_thresholds int[];
  v_milestone int;
  v_type text;
begin
  -- Ordered so two concurrent registrations on different events cannot take
  -- these row locks in opposite orders.
  for v_event in
    select e.*
    from public.events e
    where e.id in (select distinct n.event_id from new_rows n)
    order by e.id
    for update
  loop
    -- Nobody can act on a session they cannot see, a skipped one has no
    -- roster worth reporting, and without a cap there is no percentage.
    if v_event.published_at is null
       or v_event.cancelled_at is not null
       or v_event.max_participants is null then
      continue;
    end if;

    select count(*) into v_seated
    from public.event_participants ep
    where ep.event_id = v_event.id
      and ep.payment_status in ('pending', 'confirmed');

    v_pct := (v_seated * 100) / v_event.max_participants;

    v_thresholds := array[25, 50, 75, 100];

    -- The highest milestone now passed that has not been announced. Taking
    -- the highest is what makes a batch vaulting 40% to 80% announce 75%
    -- alone rather than 50% and 75% together.
    select max(t) into v_milestone
    from unnest(v_thresholds) as t
    where t <= v_pct and t > v_event.fill_notified_pct;

    if v_milestone is null then
      continue;
    end if;

    update public.events
    set fill_notified_pct = v_milestone
    where id = v_event.id;

    v_type := case v_milestone
      when 100 then 'event_full'
      else 'event_fill_' || v_milestone::text
    end;

    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, v_type, v_event.id);
  end loop;

  return null;
end;
$$;

revoke execute on function public.announce_event_fill()
  from public, anon, authenticated;

-- Statement-level with a transition table, because guests are inserted as a
-- batch: a row-level trigger would re-count the roster once per guest and
-- could announce two milestones for a single request.
drop trigger if exists trg_announce_event_fill on public.event_participants;
create trigger trg_announce_event_fill
  after insert on public.event_participants
  referencing new table as new_rows
  for each statement
  execute function public.announce_event_fill();

notify pgrst, 'reload schema';
