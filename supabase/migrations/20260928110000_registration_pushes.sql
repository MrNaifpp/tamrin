-- Every registration tells the organizer, by name, once per tap; fill
-- milestones tell the whole group, not only the organizer.
-- Spec: docs/superpowers/specs/2026-09-28-registration-pushes-design.md
--
-- Still one trigger on event_participants, for the reason
-- 20260827110000_event_fill_notifications gave: eight RPCs insert seats, and
-- a ninth added later must not be able to forget to notify.

alter table public.push_outbox
  add column if not exists actor_id uuid references auth.users(id) on delete set null,
  add column if not exists guest_count smallint,
  add column if not exists fill_pct smallint;

comment on column public.push_outbox.actor_id is
  'Who caused the push, for copy that names them (member_registered, member_added_guests).';
comment on column public.push_outbox.guest_count is
  'Guests the actor added in the tap being announced.';
comment on column public.push_outbox.fill_pct is
  'Fill milestone the tap crossed, appended to the organizer''s registration push.';

-- Seats taken before this migration start as already announced, so the first
-- tap after it does not report them. New seats default to false.
alter table public.event_participants
  add column if not exists registration_announced boolean not null default true;
alter table public.event_participants
  alter column registration_announced set default false;

comment on column public.event_participants.registration_announced is
  'Whether announce_event_fill has already looked at this seat. The first trigger run of a transaction reads the unannounced seats as "this tap" and marks them all.';

comment on column public.events.fill_notified_pct is
  'High-water mark of the fill milestone already announced (organizer and group): 0, 25, 50, 75 or 100. Never decreases, so a withdrawal cannot re-arm a milestone.';

create or replace function public.announce_event_fill()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_self boolean := false;
  v_guests int := 0;
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

  -- A draft or skipped session tells nobody. Its seats are still marked, so
  -- they cannot surface later inside somebody's next tap.
  if v_event.published_at is null or v_event.cancelled_at is not null then
    update public.event_participants
    set registration_announced = true
    where event_id = v_event.id and not registration_announced;
    return null;
  end if;

  -- What this tap added. The trigger is deferred to commit and the event row
  -- is locked, so the unannounced seats are exactly this transaction's. Only a
  -- member's own tap is announced: the organizer's and the system's are not.
  if v_uid is not null and v_uid is distinct from v_event.creator_id then
    select
      coalesce(bool_or(ep.user_id = v_uid), false),
      count(*) filter (where ep.user_id is null and ep.added_by = v_uid)
    into v_self, v_guests
    from public.event_participants ep
    where ep.event_id = v_event.id
      and not ep.registration_announced
      and ep.payment_status in ('pending', 'confirmed');
  end if;

  -- Every later run in this transaction finds nothing, which is what makes
  -- it one push per tap however many seats the tap inserted.
  update public.event_participants
  set registration_announced = true
  where event_id = v_event.id and not registration_announced;

  -- Milestones, unchanged from 20260827110000. Without a cap there is no
  -- percentage, but there are still registrations.
  if v_event.max_participants is not null then
    select count(*) into v_seated
    from public.event_participants ep
    where ep.event_id = v_event.id
      and ep.payment_status in ('pending', 'confirmed');

    v_pct := (v_seated * 100) / v_event.max_participants;

    v_thresholds := case
      when v_event.max_participants >= 8 then array[25, 50, 75, 100]
      else array[50, 100]
    end;

    select max(t) into v_milestone
    from unnest(v_thresholds) as t
    where t <= v_pct and t > v_event.fill_notified_pct;

    if v_milestone is not null then
      update public.events
      set fill_notified_pct = v_milestone
      where id = v_event.id;

      v_type := case v_milestone
        when 100 then 'event_full'
        else 'event_fill_' || v_milestone::text
      end;
    end if;
  end if;

  -- The organizer: one push per tap, carrying the milestone when it crossed
  -- one. Never for the organizer's own taps, which spend the milestone
  -- silently as before.
  if v_uid is distinct from v_event.creator_id then
    if v_self then
      insert into public.push_outbox
        (user_id, type, event_id, actor_id, guest_count, fill_pct)
      values
        (v_event.creator_id, 'member_registered', v_event.id,
         v_uid, v_guests, v_milestone);
    elsif v_guests > 0 then
      insert into public.push_outbox
        (user_id, type, event_id, actor_id, guest_count, fill_pct)
      values
        (v_event.creator_id, 'member_added_guests', v_event.id,
         v_uid, v_guests, v_milestone);
    elsif v_milestone is not null then
      insert into public.push_outbox (user_id, type, event_id)
      values (v_event.creator_id, v_type, v_event.id);
    end if;
  end if;

  -- The group: everyone but the person who crossed it and the organizer, who
  -- already heard above. A system insert (the weekly roll-over carrying
  -- seats) has no one who crossed it and tells only the organizer.
  if v_milestone is not null and v_uid is not null then
    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, v_type, v_event.id
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id is distinct from v_uid
      and wm.user_id is distinct from v_event.creator_id;
  end if;

  return null;
end;
$$;

revoke execute on function public.announce_event_fill()
  from public, anon, authenticated;

notify pgrst, 'reload schema';
