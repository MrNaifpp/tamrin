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
  select * into v_event
  from public.events
  where id = new.event_id
  for update;

  -- Nobody can act on a session they cannot see, a skipped one has no roster
  -- worth reporting, and without a cap there is no percentage.
  if v_event.published_at is null
     or v_event.cancelled_at is not null
     or v_event.max_participants is null then
    return null;
  end if;

  select count(*) into v_seated
  from public.event_participants ep
  where ep.event_id = v_event.id
    and ep.payment_status in ('pending', 'confirmed');

  v_pct := (v_seated * 100) / v_event.max_participants;

  -- Quarters only where a quarter means something. On a four-a-side game that
  -- would be a notification per player, so small sessions get halves.
  v_thresholds := case
    when v_event.max_participants >= 8 then array[25, 50, 75, 100]
    else array[50, 100]
  end;

  -- The highest milestone now passed that has not been announced. Taking the
  -- highest is what makes a registration vaulting 40% to 80% announce 75%
  -- alone rather than 50% and 75% together.
  select max(t) into v_milestone
  from unnest(v_thresholds) as t
  where t <= v_pct and t > v_event.fill_notified_pct;

  if v_milestone is null then
    return null;
  end if;

  update public.events
  set fill_notified_pct = v_milestone
  where id = v_event.id;

  v_type := case v_milestone
    when 100 then 'event_full'
    else 'event_fill_' || v_milestone::text
  end;

  -- The update above runs unconditionally: an organizer who fills their own
  -- session spends the milestone, so it cannot arrive later attached to
  -- somebody else's join, reporting news they already acted on.
  if v_uid is distinct from v_event.creator_id then
    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, v_type, v_event.id);
  end if;

  return null;
end;
$$;

revoke execute on function public.announce_event_fill()
  from public, anon, authenticated;

-- Deferred to the end of the transaction, because one registration is not one
-- statement: register_event_seat inserts the member and then their guests
-- separately, so anything evaluated per statement announces 50% for the member
-- and 75% for their guest — two notifications for one tap. Deferring means the
-- roster is final when this runs, and it stays correct however future RPCs
-- choose to split their inserts.
--
-- Constraint triggers are per-row only, so a batch fires this once per guest.
-- The first firing takes the milestone and the rest find nothing new.
drop trigger if exists trg_announce_event_fill on public.event_participants;
create constraint trigger trg_announce_event_fill
  after insert on public.event_participants
  deferrable initially deferred
  for each row
  execute function public.announce_event_fill();

notify pgrst, 'reload schema';
