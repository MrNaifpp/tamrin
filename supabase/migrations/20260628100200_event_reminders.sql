-- Twice-daily "upcoming events" reminder. A cron job (08:00 and 20:00
-- Asia/Riyadh = 05:00 and 17:00 UTC) enqueues a push for every confirmed
-- participant of any event starting within the next 12h that hasn't been
-- reminded yet. push_outbox's insert trigger fans out to send-push.

create extension if not exists pg_cron with schema extensions;

alter table public.events
  add column if not exists reminder_sent_at timestamptz;

-- Enqueue reminders for events starting in the next 12h, once each.
create or replace function public.enqueue_event_reminders()
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  with due as (
    select e.id
    from public.events e
    where e.reminder_sent_at is null
      and e.start_date > now()
      and e.start_date <= now() + interval '12 hours'
      and exists (
        select 1 from public.event_participants ep
        where ep.event_id = e.id
          and ep.user_id is not null
          and ep.payment_status = 'confirmed'
      )
  ),
  enqueued as (
    insert into public.push_outbox (user_id, type, event_id)
    select ep.user_id, 'event_reminder', ep.event_id
    from public.event_participants ep
    join due on due.id = ep.event_id
    where ep.user_id is not null
      and ep.payment_status = 'confirmed'
    returning event_id
  )
  update public.events e
    set reminder_sent_at = now()
    where e.id in (select id from due);
end;
$$;

-- Schedule two daily runs, 12h apart (UTC).
select cron.schedule('event-reminders-am', '0 5 * * *', $$select public.enqueue_event_reminders();$$);
select cron.schedule('event-reminders-pm', '0 17 * * *', $$select public.enqueue_event_reminders();$$);
