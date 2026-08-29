-- Automatic capacity-progress notifications.
--
-- A milestone belongs to the concrete occurrence, not its recurring template.
-- The quarter step is floor(max_participants / 4); every positive multiple
-- below the cap is a progress milestone, followed by max - 1 (near-full) and
-- max (full).  For small caps where the quarter step is zero, only near-full
-- and full are meaningful.
--
-- Participant inserts can be batched (a member plus several guests), so the
-- constraint trigger is deferred until transaction end.  The evaluator marks
-- every crossed milestone but queues only the highest newly crossed one.  This
-- avoids delivering several stale progress pushes after one large batch while
-- retaining durable, per-occurrence idempotency for every threshold.
-- Milestones are keyed semantically (quarter_1, quarter_2, near_full, full),
-- not by their numeric threshold.  If max_participants changes later, a stage
-- already reached for this occurrence is therefore not announced a second
-- time; only semantic stages that have never been claimed can still fire.

alter table public.push_outbox
  add column if not exists metadata jsonb not null default '{}'::jsonb;

comment on column public.push_outbox.metadata is
  'Structured notification copy data. Capacity pushes include registered_count, remaining_count, and capacity.';

create table if not exists public.event_capacity_notification_milestones (
  event_id uuid not null references public.events(id) on delete cascade,
  milestone_key text not null,
  milestone int not null,
  capacity int not null,
  milestone_kind text not null,
  reached_at timestamptz not null default now(),
  primary key (event_id, milestone_key),
  constraint event_capacity_milestone_positive
    check (milestone > 0 and capacity > 0 and milestone <= capacity),
  constraint event_capacity_milestone_key
    check (
      milestone_key in ('near_full', 'full')
      or milestone_key ~ '^quarter_[1-9][0-9]*$'
    ),
  constraint event_capacity_milestone_kind
    check (milestone_kind in ('progress', 'near_full', 'full'))
);

comment on table public.event_capacity_notification_milestones is
  'Durable once-per-event claims for capacity notification thresholds.';

alter table public.event_capacity_notification_milestones enable row level security;
revoke all on table public.event_capacity_notification_milestones
  from public, anon, authenticated;

-- Mark capacity stages already reached before this feature is deployed without
-- sending retrospective notifications.  Otherwise the next registration on a
-- long-running occurrence could emit an old quarter-stage alert.
with event_counts as (
  select e.id as event_id,
         e.max_participants as capacity,
         floor(e.max_participants::numeric / 4)::int as quarter_step,
         count(ep.id)::int as registered_count
  from public.events e
  left join public.event_participants ep
    on ep.event_id = e.id
   and ep.payment_status in ('pending', 'confirmed')
  where e.max_participants is not null
    and e.max_participants > 0
    and e.published_at is not null
    and e.cancelled_at is null
  group by e.id, e.max_participants
), candidates as (
  select ec.event_id,
         progress.milestone,
         'quarter_' || progress.ordinality::text as milestone_key,
         ec.capacity,
         'progress'::text as milestone_kind
  from event_counts ec
  cross join lateral generate_series(
    ec.quarter_step,
    ec.capacity - 2,
    greatest(ec.quarter_step, 1)
  ) with ordinality as progress(milestone, ordinality)
  where ec.quarter_step > 0

  union all

  select ec.event_id,
         ec.capacity - 1,
         'near_full'::text,
         ec.capacity,
         'near_full'::text
  from event_counts ec
  where ec.capacity > 1

  union all

  select ec.event_id,
         ec.capacity,
         'full'::text,
         ec.capacity,
         'full'::text
  from event_counts ec
), reached as (
  select distinct on (c.event_id, c.milestone_key)
         c.event_id,
         c.milestone_key,
         c.milestone,
         c.capacity,
         c.milestone_kind
  from candidates c
  join event_counts ec on ec.event_id = c.event_id
  where c.milestone <= least(ec.registered_count, ec.capacity)
  order by c.event_id,
           c.milestone_key,
           case c.milestone_kind
             when 'full' then 3
             when 'near_full' then 2
             else 1
           end desc
)
insert into public.event_capacity_notification_milestones
  (event_id, milestone_key, milestone, capacity, milestone_kind)
select event_id, milestone_key, milestone, capacity, milestone_kind
from reached
on conflict (event_id, milestone_key) do nothing;

create or replace function public.enqueue_event_capacity_notifications(
  p_event_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_registered_count int;
  v_quarter_step int;
  v_milestone_key text;
  v_milestone int;
  v_milestone_kind text;
  v_push_type text;
begin
  -- The registration guard holds a SHARE lock on the event row.  Do not try
  -- to upgrade that lock here: two concurrent registrations can both hold
  -- SHARE and then deadlock while upgrading at commit.  A dedicated advisory
  -- lock serializes deferred evaluators without conflicting with that guard.
  perform pg_advisory_xact_lock(
    hashtextextended('event-capacity:' || p_event_id::text, 0)
  );

  select *
  into v_event
  from public.events
  where id = p_event_id;

  if v_event.id is null
     or v_event.max_participants is null
     or v_event.max_participants <= 0
     or v_event.published_at is null
     or v_event.cancelled_at is not null
     or coalesce(v_event.end_date, v_event.start_date) <= now() then
    return;
  end if;

  select count(*)::int
  into v_registered_count
  from public.event_participants ep
  where ep.event_id = p_event_id
    and ep.payment_status in ('pending', 'confirmed');

  if v_registered_count <= 0 then
    return;
  end if;

  v_quarter_step := floor(v_event.max_participants::numeric / 4)::int;

  with candidates as (
    select 'quarter_' || progress.ordinality::text as milestone_key,
           progress.milestone,
           'progress'::text as milestone_kind
    from generate_series(
      v_quarter_step,
      v_event.max_participants - 2,
      greatest(v_quarter_step, 1)
    ) with ordinality as progress(milestone, ordinality)
    where v_quarter_step > 0

    union all

    select 'near_full'::text,
           v_event.max_participants - 1,
           'near_full'::text
    where v_event.max_participants > 1

    union all

    select 'full'::text,
           v_event.max_participants,
           'full'::text
  ), reached as (
    select distinct on (c.milestone_key)
           c.milestone_key,
           c.milestone,
           c.milestone_kind
    from candidates c
    where c.milestone > 0
      and c.milestone <= v_registered_count
    order by c.milestone_key,
             case c.milestone_kind
               when 'full' then 3
               when 'near_full' then 2
               else 1
             end desc
  ), claimed as (
    insert into public.event_capacity_notification_milestones
      (event_id, milestone_key, milestone, capacity, milestone_kind)
    select p_event_id,
           r.milestone_key,
           r.milestone,
           v_event.max_participants,
           r.milestone_kind
    from reached r
    on conflict (event_id, milestone_key) do nothing
    returning milestone_key, milestone, milestone_kind
  )
  select c.milestone_key, c.milestone, c.milestone_kind
  into v_milestone_key, v_milestone, v_milestone_kind
  from claimed c
  order by c.milestone desc
  limit 1;

  if v_milestone is null then
    return;
  end if;

  v_push_type := case
    when v_milestone_kind = 'full' then 'event_capacity_full'
    else 'event_capacity_progress'
  end;

  insert into public.push_outbox
    (user_id, type, event_id, metadata)
  select wm.user_id,
         v_push_type,
         v_event.id,
         jsonb_build_object(
           'registered_count', v_registered_count,
           'remaining_count', greatest(
             v_event.max_participants - v_registered_count,
             0
           ),
           'capacity', v_event.max_participants
         )
  from public.workspace_members wm
  where wm.workspace_id = v_event.workspace_id
    -- A recurring occurrence stays hidden from a member who still owes for
    -- an earlier occurrence in the same series. Do not send that member an
    -- actionable "reserve your seat" push for an event they cannot join yet.
    and not exists (
      select 1
      from public.events debt_event
      join public.event_templates debt_template
        on debt_template.id = debt_event.template_id
      join public.event_templates current_template
        on current_template.id = v_event.template_id
      join public.event_participants debt
        on debt.event_id = debt_event.id
      where debt_template.series_key = current_template.series_key
        and debt_event.cancelled_at is null
        and debt_event.start_date < v_event.start_date
        and coalesce(debt_event.end_date, debt_event.start_date) < now()
        and debt.payment_status = 'pending'
        and debt.payment_declared_at is null
        and (
          debt.user_id = wm.user_id
          or (debt.user_id is null and debt.added_by = wm.user_id)
        )
    );
end;
$$;

revoke execute on function public.enqueue_event_capacity_notifications(uuid)
  from public, anon, authenticated;

create or replace function public.fire_event_capacity_notifications()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.enqueue_event_capacity_notifications(new.event_id);
  return null;
end;
$$;

revoke execute on function public.fire_event_capacity_notifications()
  from public, anon, authenticated;

drop trigger if exists trg_event_capacity_notifications
  on public.event_participants;

create constraint trigger trg_event_capacity_notifications
after insert on public.event_participants
deferrable initially deferred
for each row
execute function public.fire_event_capacity_notifications();

notify pgrst, 'reload schema';
