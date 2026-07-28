-- Daily generator: materialize the next occurrence of each live template as a
-- normal events row once now() enters the lead window, auto-join the creator,
-- and push "انفتح التسجيل" to every other workspace member. Advancing
-- next_occurrence_at in the same transaction as the insert is what makes a
-- double cron run idempotent. Same cron pattern as enqueue_event_reminders.

create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl record;
  new_event public.events;
begin
  for tpl in
    select * from public.event_templates t
    where t.ended_at is null
      and now() >= t.next_occurrence_at - make_interval(days => t.lead_days)
    order by t.next_occurrence_at
    for update
  loop
    -- One-shot skip: consume the flag, advance, create nothing.
    if tpl.skip_next then
      update public.event_templates
        set next_occurrence_at = tpl.next_occurrence_at + interval '7 days',
            skip_next = false
        where id = tpl.id;
      continue;
    end if;

    -- Catch-up: a stale template (e.g. cron was down) advances to the future
    -- without burst-creating past workouts — at most one event per run.
    while tpl.next_occurrence_at <= now() loop
      tpl.next_occurrence_at := tpl.next_occurrence_at + interval '7 days';
    end loop;

    if now() < tpl.next_occurrence_at - make_interval(days => tpl.lead_days) then
      -- Catch-up moved it out of the lead window: persist the new anchor only.
      update public.event_templates
        set next_occurrence_at = tpl.next_occurrence_at
        where id = tpl.id;
      continue;
    end if;

    insert into public.events
      (creator_id, workspace_id, name, location, description, start_date,
       end_date, image_url, max_participants, total_price, price_per_person,
       latitude, longitude, template_id)
    values
      (tpl.creator_id, tpl.workspace_id, tpl.name, tpl.location, tpl.description,
       tpl.next_occurrence_at,
       case when tpl.duration_minutes is not null
            then tpl.next_occurrence_at + make_interval(mins => tpl.duration_minutes) end,
       tpl.image_url, tpl.max_participants, tpl.total_price, tpl.price_per_person,
       tpl.latitude, tpl.longitude, tpl.id)
    returning * into new_event;

    -- Creator auto-joins, same as create_event.
    insert into public.event_participants (event_id, user_id)
    values (new_event.id, tpl.creator_id);

    -- One "registration open" push per workspace member except the creator.
    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, 'event_opened', new_event.id
    from public.workspace_members wm
    where wm.workspace_id = tpl.workspace_id
      and wm.user_id <> tpl.creator_id;

    update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at + interval '7 days'
      where id = tpl.id;
  end loop;
end;
$$;

-- Daily at 05:00 UTC = 08:00 Riyadh, same slot as event-reminders-am.
select cron.schedule('recurring-events', '0 5 * * *', $$select public.generate_recurring_events();$$);
