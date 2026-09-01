-- Repair one duplicated Sunday session, and stop it repeating.
--
-- Under the old generator, which ran once a day and opened the next occurrence
-- only a few days ahead, an organizer on a Tuesday could look at «تمرين الطائرة»
-- and see nothing upcoming. He was in a hurry, so he created a second weekly
-- exercise for the same Sunday and shared that instead. Both templates then kept
-- generating, so the group saw the same session twice, every week.
--
-- The rolling generator has since removed the reason: it runs every minute and
-- opens the next occurrence the moment the current one ends, so there is now
-- always exactly one visible upcoming session. Nothing here prevents a second
-- weekly template, and nothing needs to yet; what remains is the pair already
-- in the data.
--
-- Which one survives is decided by where people actually are:
--
--   d476b354  «تمرين الاحد 🏐»  12 seats, first join 2026-08-27 12:50  <- shared
--   ad57ad86  «تمرين الأحد 🏐»   2 seats, first join 2026-08-28 05:00  <- auto
--
-- So the shared one carries the exercise, and the automatic one is cancelled
-- rather than deleted: a session people joined stays in the record, which is the
-- rule everywhere else in this schema.
--
-- Outside production the ids do not exist and this whole block is a no-op.

do $$
declare
  v_duplicate_event uuid := 'a9107ab8-f5f6-4e90-b002-bc5ad3da4081';
  v_duplicate_template uuid := 'ad57ad86-047e-4163-9aaa-d5f3cc082d75';
  v_event public.events;
  v_cancelled integer;
  v_notified integer;
begin
  select * into v_event from public.events where id = v_duplicate_event;
  if v_event.id is null then
    raise notice 'duplicate occurrence is not present here; nothing to repair';
    return;
  end if;

  -- Refuse to act on anything but the row this migration was written about.
  -- If production has moved on since we looked, a human should look again.
  if v_event.template_id is distinct from v_duplicate_template then
    raise exception 'expected the duplicate to belong to template %, found %',
      v_duplicate_template, v_event.template_id;
  end if;

  update public.events
  set cancelled_at = coalesce(cancelled_at, now()),
      cancelled_by = coalesce(cancelled_by, v_event.creator_id),
      cancellation_reason_code = coalesce(cancellation_reason_code, 'duplicate_occurrence'),
      cancellation_reason_text = coalesce(
        cancellation_reason_text,
        'تكرر الموعد بالغلط. سجّل في موعد الأحد الثاني، مكانك محفوظ.'
      )
  where id = v_duplicate_event
    and cancelled_at is null;
  get diagnostics v_cancelled = row_count;

  if v_cancelled > 0 then
    -- Only the people sitting in the duplicate. cancel_event_occurrence tells
    -- the whole workspace, which is right for a session everybody knew about.
    -- This one existed for a day and holds two seats; telling the rest of the
    -- group about a session they never saw is noise, not news.
    with notified as (
      insert into public.push_outbox (user_id, type, event_id)
      select distinct participant.user_id, 'event_cancelled', v_duplicate_event
      from public.event_participants participant
      where participant.event_id = v_duplicate_event
        and participant.user_id is not null
      returning user_id
    )
    select count(*) into v_notified from notified;
    raise notice 'cancelled the duplicate occurrence and notified % member(s)', v_notified;
  else
    raise notice 'duplicate occurrence was already cancelled';
  end if;

  -- The point of the exercise: without this it opens another one next Sunday.
  update public.event_templates
  set ended_at = coalesce(ended_at, now())
  where id = v_duplicate_template
    and ended_at is null;
end $$;
