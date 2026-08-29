-- Rolling weekly exercises.
--
-- A recurring template no longer has a configurable "send ahead" window.
-- Its next occurrence opens automatically as soon as the current occurrence
-- ends.  The release pointer is stored explicitly so an occurrence-only edit
-- to the current end time is respected, and so skipping one week does not
-- accidentally open the following week immediately.

alter table public.event_templates
  add column if not exists next_release_at timestamptz,
  add column if not exists series_key uuid;

-- A series edit intentionally replaces the template row. Keep a stable key
-- across those replacements so an unpaid occurrence cannot be detached from
-- the next occurrence merely by editing the recurring template.
update public.event_templates
set series_key = id
where series_key is null;

alter table public.event_templates
  alter column series_key set default gen_random_uuid(),
  alter column series_key set not null;

-- update_event_with_scope(series_template) historically ended one template
-- and inserted its replacement in the same transaction. PostgreSQL's now()
-- is transaction-stable, so ended_at = replacement.created_at is a durable
-- lineage signal for installations that already contain replacement chains.
do $$
declare
  replacement record;
  v_parent_series_key uuid;
begin
  for replacement in
    select t.id, t.workspace_id, t.creator_id, t.created_at
    from public.event_templates t
    order by t.created_at, t.id
  loop
    v_parent_series_key := null;
    select parent.series_key into v_parent_series_key
    from public.event_templates parent
    where parent.id <> replacement.id
      and parent.workspace_id = replacement.workspace_id
      and parent.creator_id = replacement.creator_id
      and parent.ended_at = replacement.created_at
    order by parent.created_at desc, parent.id
    limit 1;

    if v_parent_series_key is not null then
      update public.event_templates
      set series_key = v_parent_series_key
      where id = replacement.id;
    end if;
  end loop;
end;
$$;

-- Repair any legacy double-resume by keeping the newest active replacement,
-- then make "one active generator per stable series" a database invariant.
with ranked_active as (
  select id,
         row_number() over (
           partition by series_key
           order by created_at desc, id desc
         ) as active_rank
  from public.event_templates
  where ended_at is null
)
update public.event_templates template
set ended_at = now()
from ranked_active ranked
where template.id = ranked.id
  and ranked.active_rank > 1;

create unique index if not exists idx_event_templates_one_active_series
  on public.event_templates(series_key)
  where ended_at is null;

comment on column public.event_templates.next_release_at is
  'When the next weekly occurrence may be materialized and published. Normally the effective end of the currently open occurrence.';
comment on column public.event_templates.series_key is
  'Stable identity shared by replacement template rows that belong to one recurring series.';

create index if not exists idx_event_templates_series_key
  on public.event_templates(series_key);

-- One concrete slot per weekly series.  The template row lock below is the
-- concurrency guard; this index is the final idempotency boundary for retries
-- and for legacy cron jobs that may overlap briefly during deployment.
create unique index if not exists idx_events_template_start_unique
  on public.events(template_id, start_date)
  where template_id is not null;

create index if not exists idx_event_templates_next_release
  on public.event_templates(next_release_at)
  where ended_at is null and published_at is not null;

-- Keep the release pointer attached to the latest concrete occurrence.  This
-- also covers create_event, enable_recurrence, and both edit scopes without
-- duplicating their long RPC implementations.
create or replace function public.sync_event_template_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' then
    if old.template_id is not null
       and new.template_id is not null
       and old.template_id is distinct from new.template_id then
      update public.event_templates replacement
      set series_key = original.series_key
      from public.event_templates original
      where replacement.id = new.template_id
        and original.id = old.template_id;
    end if;
  end if;

  if new.template_id is null then
    return new;
  end if;

  -- Draft edits must not postpone release to the draft's own end. Publishing
  -- the draft later fires this trigger again and makes it the active anchor.
  if new.published_at is null then
    return new;
  end if;

  update public.event_templates t
  set next_release_at = coalesce(new.end_date, new.start_date)
  where t.id = new.template_id
    and t.ended_at is null
    and not exists (
      select 1
      from public.events later
      where later.template_id = new.template_id
        and later.id <> new.id
        and later.published_at is not null
        and later.start_date > new.start_date
    );

  return new;
end;
$$;

revoke execute on function public.sync_event_template_release()
  from public, anon, authenticated;

drop trigger if exists trg_sync_event_template_release on public.events;
create trigger trg_sync_event_template_release
after insert or update of template_id, start_date, end_date, published_at on public.events
for each row execute function public.sync_event_template_release();

-- An old lead-days draft can be left behind on the ended half of a template
-- replacement. It carries stale schedule/details and must never compete with
-- the active replacement's next occurrence. Preserve it as a cancelled audit
-- row rather than deleting history.
update public.events stale_draft
set cancelled_at = coalesce(stale_draft.cancelled_at, now()),
    cancelled_by = coalesce(stale_draft.cancelled_by, old_template.creator_id),
    cancellation_reason_code = coalesce(
      stale_draft.cancellation_reason_code,
      'series_replaced'
    ),
    cancellation_reason_text = coalesce(
      stale_draft.cancellation_reason_text,
      'Superseded by a newer recurring template.'
    )
from public.event_templates old_template
where stale_draft.template_id = old_template.id
  and stale_draft.published_at is null
  and stale_draft.cancelled_at is null
  and old_template.ended_at is not null
  and exists (
    select 1
    from public.event_templates active_template
    where active_template.series_key = old_template.series_key
      and active_template.ended_at is null
      and active_template.id <> old_template.id
  );

-- Existing installations may already contain a future organizer-only draft
-- created by the old lead-days generator.  Anchor the release at the latest
-- *published* occurrence so the new generator can publish that draft as soon
-- as the previous occurrence has ended.
update public.event_templates t
set next_release_at = coalesce(
  (
    select coalesce(e.end_date, e.start_date)
    from public.events e
    where e.template_id = t.id
      and e.published_at is not null
      and e.start_date < t.next_occurrence_at
    order by e.start_date desc, e.id desc
    limit 1
  ),
  t.next_occurrence_at - interval '7 days'
    + make_interval(mins => coalesce(t.duration_minutes, 0))
)
where t.next_release_at is null;

-- Cron cannot call publish_event because that public RPC intentionally binds
-- authorization to auth.uid().  This private helper owns only the idempotent
-- publication/invitation part and is executable by neither anon nor clients.
create or replace function public.publish_recurring_event_internal(
  p_event_id uuid,
  p_invited_by uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
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
          and (debt.user_id = wm.user_id
            or (debt.user_id is null and debt.added_by = wm.user_id))
      )
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
$$;

revoke execute on function public.publish_recurring_event_internal(uuid, uuid)
  from public, anon, authenticated;

-- Manual publication uses the same debt-aware invitation path as cron. This
-- keeps an idempotent owner retry from notifying a member whose next event is
-- still gated by an undeclared payment.
create or replace function public.publish_event(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_before_invites integer := 0;
  v_after_invites integer := 0;
  v_before_notifications integer := 0;
  v_after_notifications integer := 0;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event
  from public.events
  where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can publish events';
  end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  select count(*) into v_before_invites
  from public.event_member_responses
  where event_id = p_event_id and status = 'invited';

  select count(*) into v_before_notifications
  from public.push_outbox
  where event_id = p_event_id
    and type in ('event_opened', 'event_invited');

  perform public.publish_recurring_event_internal(p_event_id, v_uid);

  select * into v_event from public.events where id = p_event_id;
  if v_event.template_id is not null then
    update public.event_templates
    set published_at = coalesce(published_at, v_event.published_at)
    where id = v_event.template_id
      and ended_at is null;
  end if;

  select count(*) into v_after_invites
  from public.event_member_responses
  where event_id = p_event_id and status = 'invited';

  select count(*) into v_after_notifications
  from public.push_outbox
  where event_id = p_event_id
    and type in ('event_opened', 'event_invited');

  return json_build_object(
    'status', 'published',
    'event_id', v_event.id,
    'published_at', v_event.published_at,
    'new_invite_count', greatest(v_after_invites - v_before_invites, 0),
    'invited_count', v_after_invites,
    'notification_count', greatest(
      v_after_notifications - v_before_notifications,
      0
    )
  );
end;
$$;

revoke execute on function public.publish_event(uuid) from public, anon;
grant execute on function public.publish_event(uuid) to authenticated;

create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
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
$$;

revoke execute on function public.generate_recurring_events()
  from public, anon, authenticated;

-- Re-enabling recurrence from an occurrence on an older template replacement
-- must resolve to the already-active sibling, never resurrect a second active
-- generator for the same stable series.
create or replace function public.enable_recurrence(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_template public.event_templates;
  v_active_template public.event_templates;
  v_initial_template_id uuid;
  v_duration_minutes integer;
begin
  select * into v_event
  from public.events
  where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_uid is null
     or not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can manage recurrence';
  end if;

  v_initial_template_id := v_event.template_id;
  if v_initial_template_id is not null then
    select * into v_template
    from public.event_templates
    where id = v_initial_template_id;
    if v_template.id is not null then
      perform pg_advisory_xact_lock(
        hashtextextended(v_template.series_key::text, 0)
      );
    end if;
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_event.template_id is distinct from v_initial_template_id then
    raise exception 'Event recurrence changed; retry';
  end if;

  if v_initial_template_id is not null then
    select * into v_template
    from public.event_templates
    where id = v_initial_template_id
    for update;
  end if;

  if v_template.id is not null then
    if v_template.ended_at is null then
      return row_to_json(v_template);
    end if;

    select active_template.* into v_active_template
    from public.event_templates active_template
    where active_template.series_key = v_template.series_key
      and active_template.ended_at is null
      and active_template.id <> v_template.id
    order by active_template.created_at desc, active_template.id
    limit 1
    for update;

    if v_active_template.id is not null then
      return row_to_json(v_active_template);
    end if;

    update public.event_templates
    set ended_at = null,
        skip_next = false,
        creator_id = v_uid,
        published_at = v_event.published_at,
        next_release_at = coalesce(v_event.end_date, v_event.start_date)
    where id = v_template.id
    returning * into v_template;
    return row_to_json(v_template);
  end if;

  if v_event.end_date is not null then
    v_duration_minutes :=
      (extract(epoch from (v_event.end_date - v_event.start_date)) / 60)::int;
  end if;

  insert into public.event_templates
    (workspace_id, creator_id, name, location, description, image_url,
     latitude, longitude, total_price, price_per_person, max_participants,
     duration_minutes, recurrence, next_occurrence_at, payment_method_id,
     payment_method_ids, published_at, next_release_at)
  values
    (v_event.workspace_id, v_uid, v_event.name, v_event.location,
     v_event.description, v_event.image_url, v_event.latitude, v_event.longitude,
     v_event.total_price, 0, v_event.max_participants, v_duration_minutes,
     'weekly', v_event.start_date + interval '7 days',
     v_event.payment_method_id, v_event.payment_method_ids,
     v_event.published_at, coalesce(v_event.end_date, v_event.start_date))
  returning * into v_template;

  update public.events
  set template_id = v_template.id
  where id = p_event_id;
  return row_to_json(v_template);
end;
$$;

revoke execute on function public.enable_recurrence(uuid) from public, anon;
grant execute on function public.enable_recurrence(uuid) to authenticated;

-- Live feed contract:
--   * an ended occurrence stays actionable only while this payer has not yet
--     declared the transfer;
--   * that personal debt hides later occurrences from the same template;
--   * declaring payment releases the next occurrence immediately, without
--     waiting for the organizer's confirmation.
create or replace function public.get_workspace_events(p_workspace_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
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
        and (
          public.is_workspace_owner(e.workspace_id, v_uid)
          or e.template_id is null
          or coalesce(e.end_date, e.start_date) < now()
          or not exists (
            select 1
            from public.events debt_event
            join public.event_templates debt_template
              on debt_template.id = debt_event.template_id
            join public.event_templates current_template
              on current_template.id = e.template_id
            join public.event_participants debt
              on debt.event_id = debt_event.id
            where debt_template.series_key = current_template.series_key
              and debt_event.cancelled_at is null
              and debt_event.start_date < e.start_date
              and coalesce(debt_event.end_date, debt_event.start_date) < now()
              and debt.payment_status = 'pending'
              and debt.payment_declared_at is null
              and (debt.user_id = v_uid
                or (debt.user_id is null and debt.added_by = v_uid))
          )
        )
    ) x
  );
end;
$$;

revoke execute on function public.get_workspace_events(uuid) from public, anon;
grant execute on function public.get_workspace_events(uuid) to authenticated;

-- History keeps the row available for an immediate live-to-past transition;
-- the client uses requires_payment_action to keep an unpaid row off the past
-- shelf until the declaration succeeds.
create or replace function public.get_workspace_past_events(
  p_workspace_id uuid,
  p_before timestamptz default now(),
  p_limit integer default 60,
  p_offset integer default 0
)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_limit integer := least(greatest(coalesce(p_limit, 60), 1), 120);
  v_offset integer := greatest(coalesce(p_offset, 0), 0);
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.is_workspace_member(p_workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(
      json_agg(row_to_json(x) order by x.start_date desc, x.id desc),
      '[]'::json
    )
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
        and coalesce(e.end_date, e.start_date) < coalesce(p_before, now())
      order by e.start_date desc, e.id desc
      limit v_limit
      offset v_offset
    ) x
  );
end;
$$;

revoke execute on function public.get_workspace_past_events(
  uuid, timestamptz, integer, integer
) from public, anon;
grant execute on function public.get_workspace_past_events(
  uuid, timestamptz, integer, integer
) to authenticated;

-- Serialize a declaration with the generator on the active series template.
-- Whichever transaction wins is then sufficient: either cron sees the debt as
-- declared while inviting, or the declaration trigger sees cron's new event.
create or replace function public.declare_event_payment(
  p_event_id uuid,
  p_payment_method_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_method public.workspace_payment_methods;
  v_declared integer;
  v_series_key uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event
  from public.events
  where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
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
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  if v_event.total_price <= 0 then
    return json_build_object('status', 'free_event');
  end if;

  select * into v_method
  from public.workspace_payment_methods
  where id = p_payment_method_id
    and workspace_id = v_event.workspace_id;
  if v_method.id is null then
    return json_build_object('status', 'payment_method_required');
  end if;
  if not (
    p_payment_method_id = any(coalesce(v_event.payment_method_ids, '{}'::uuid[]))
    or p_payment_method_id = v_event.payment_method_id
  ) then
    return json_build_object('status', 'event_terms_changed');
  end if;

  with mine as (
    update public.event_participants ep
    set payment_declared_at = now(),
        payment_method_id = v_method.id,
        payment_provider = v_method.provider,
        paid_to_number = v_method.mobile_number,
        paid_to_iban = v_method.iban,
        paid_to_account_number = v_method.account_number
    where ep.event_id = p_event_id
      and ep.payment_status = 'pending'
      and ep.payment_declared_at is null
      and (ep.user_id = v_uid
        or (ep.user_id is null and ep.added_by = v_uid))
    returning 1
  )
  select count(*) into v_declared from mine;

  if v_declared = 0 then
    return json_build_object('status', 'nothing_due');
  end if;

  insert into public.push_outbox (user_id, type, event_id)
  values (v_event.creator_id, 'payment_declared', p_event_id);

  return json_build_object('status', 'declared', 'seats', v_declared);
end;
$$;

revoke execute on function public.declare_event_payment(uuid, uuid)
  from public, anon;
grant execute on function public.declare_event_payment(uuid, uuid)
  to authenticated;

-- Guest-only/additional-guest RPCs predate payment_declared_at and already
-- snapshot a selected destination at the moment their UI says the transfer
-- was submitted. Preserve that meaning: a pending insert with a snapshotted
-- method is declared, while register_event_seat (method is null) remains an
-- actually unpaid held seat.
create or replace function public.stamp_submitted_payment_declaration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.payment_status = 'pending'
     and new.payment_declared_at is null
     and new.payment_method_id is not null then
    new.payment_declared_at := now();
  end if;
  return new;
end;
$$;

revoke execute on function public.stamp_submitted_payment_declaration()
  from public, anon, authenticated;

drop trigger if exists trg_stamp_submitted_payment_declaration
  on public.event_participants;
create trigger trg_stamp_submitted_payment_declaration
before insert on public.event_participants
for each row execute function public.stamp_submitted_payment_declaration();

update public.event_participants
set payment_declared_at = created_at
where payment_status = 'pending'
  and payment_declared_at is null
  and payment_method_id is not null;

-- A member blocked when the recurring occurrence opened receives their invite
-- at the moment the old transfer is declared. Multiple self/guest rows are
-- harmless: the response primary key makes the trigger idempotent.
create or replace function public.invite_after_recurring_debt_declaration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_payer_id uuid := coalesce(new.user_id, new.added_by);
  v_old_event public.events;
  v_next_event public.events;
  v_series_key uuid;
  v_inserted_user uuid;
begin
  if old.payment_declared_at is not null
     or new.payment_declared_at is null
     or v_payer_id is null then
    return new;
  end if;

  select * into v_old_event
  from public.events
  where id = new.event_id;
  if v_old_event.template_id is null then return new; end if;

  select series_key into v_series_key
  from public.event_templates
  where id = v_old_event.template_id;
  if v_series_key is null then return new; end if;

  select e.* into v_next_event
  from public.events e
  join public.event_templates next_template
    on next_template.id = e.template_id
  where next_template.series_key = v_series_key
    and e.start_date > v_old_event.start_date
    and e.published_at is not null
    and e.cancelled_at is null
    and coalesce(e.end_date, e.start_date) >= now()
  order by e.start_date, e.id
  limit 1;
  if v_next_event.id is null then return new; end if;

  -- A declaration for one occurrence must not unlock the series while a still
  -- older undeclared contribution remains.
  if exists (
    select 1
    from public.events debt_event
    join public.event_templates debt_template
      on debt_template.id = debt_event.template_id
    join public.event_participants debt on debt.event_id = debt_event.id
    where debt_template.series_key = v_series_key
      and debt_event.cancelled_at is null
      and debt_event.start_date < v_next_event.start_date
      and coalesce(debt_event.end_date, debt_event.start_date) < now()
      and debt.payment_status = 'pending'
      and debt.payment_declared_at is null
      and (debt.user_id = v_payer_id
        or (debt.user_id is null and debt.added_by = v_payer_id))
  ) then
    return new;
  end if;

  if not public.is_workspace_member(v_next_event.workspace_id, v_payer_id)
     or exists (
       select 1 from public.event_participants ep
       where ep.event_id = v_next_event.id and ep.user_id = v_payer_id
     ) then
    return new;
  end if;

  insert into public.event_member_responses
    (event_id, user_id, status, invited_by, invited_at, updated_at)
  values
    (v_next_event.id, v_payer_id, 'invited', v_next_event.creator_id, now(), now())
  on conflict (event_id, user_id) do nothing
  returning user_id into v_inserted_user;

  if v_inserted_user is not null
     and not exists (
       select 1
       from public.push_outbox po
       where po.event_id = v_next_event.id
         and po.user_id = v_payer_id
         and po.type in ('event_opened', 'event_invited')
     ) then
    insert into public.push_outbox (user_id, type, event_id)
    values (v_payer_id, 'event_invited', v_next_event.id);
  end if;

  return new;
end;
$$;

revoke execute on function public.invite_after_recurring_debt_declaration()
  from public, anon, authenticated;

drop trigger if exists trg_invite_after_recurring_debt_declaration
  on public.event_participants;
create trigger trg_invite_after_recurring_debt_declaration
after update of payment_declared_at on public.event_participants
for each row execute function public.invite_after_recurring_debt_declaration();

-- No new seat, waitlist place, guest, decline, or withdrawal may be created
-- after the occurrence ends.  Payment declaration deliberately remains
-- allowed: it is the one action the retained historical card exists for.
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
  if v_event.template_id is not null
     and v_payer_id is not null
     and exists (
       select 1
       from public.events debt_event
       join public.event_templates debt_template
         on debt_template.id = debt_event.template_id
       join public.event_templates current_template
         on current_template.id = v_event.template_id
       join public.event_participants debt on debt.event_id = debt_event.id
       where debt_template.series_key = current_template.series_key
         and debt_event.cancelled_at is null
         and debt_event.start_date < v_event.start_date
         and coalesce(debt_event.end_date, debt_event.start_date) < now()
         and debt.payment_status = 'pending'
         and debt.payment_declared_at is null
         and (debt.user_id = v_payer_id
           or (debt.user_id is null and debt.added_by = v_payer_id))
     ) then
    raise exception 'Previous event payment is required';
  end if;

  if tg_table_name in ('event_participants', 'event_waitlist')
     and new.user_id is not null
     and exists (
       select 1
       from public.event_participants ep
       where ep.event_id = new.event_id
         and ep.user_id is null
         and ep.added_by = new.user_id
         and ep.guest_only
         and ep.payment_status = 'pending'
     ) then
    raise exception 'Pending guest request must be resolved before self registration';
  end if;

  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then raise exception 'Registration is closed for this event'; end if;
  return new;
end;
$$;

revoke execute on function public.guard_event_registration_insert()
  from public, anon, authenticated;

-- Every leave now goes through the guarded SECURITY DEFINER RPCs below. The
-- original table policy allowed a member to DELETE their ended debt row
-- directly and bypass the recurring-payment gate.
drop policy if exists "Users can leave events"
  on public.event_participants;
revoke delete on table public.event_participants from anon, authenticated;

create or replace function public.decline_event(
  p_event_id uuid,
  p_reason_code text default null,
  p_reason_text text default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_reason_code text := nullif(lower(trim(p_reason_code)), '');
  v_reason_text text := nullif(trim(p_reason_text), '');
  v_removed_participants int := 0;
  v_removed_waitlist int := 0;
  v_waiters json;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if v_reason_code is not null and v_reason_code !~ '^[a-z0-9_-]{1,50}$' then
    raise exception 'Invalid reason code';
  end if;
  if v_reason_text is not null and char_length(v_reason_text) > 500 then
    raise exception 'Reason text is too long';
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Workspace owner cannot decline an event they administer';
  end if;
  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or (added_by = v_uid and not guest_only));
  get diagnostics v_removed_participants = row_count;

  delete from public.event_waitlist
  where event_id = p_event_id and user_id = v_uid;
  get diagnostics v_removed_waitlist = row_count;

  insert into public.event_member_responses
    (event_id, user_id, status, reason_code, reason_text,
     responded_at, updated_at)
  values
    (p_event_id, v_uid, 'declined', v_reason_code, v_reason_text,
     now(), now())
  on conflict (event_id, user_id) do update
  set status = 'declined',
      reason_code = excluded.reason_code,
      reason_text = excluded.reason_text,
      responded_at = excluded.responded_at,
      updated_at = excluded.updated_at;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', 'declined',
    'event_id', p_event_id,
    'reason_code', v_reason_code,
    'reason_text', v_reason_text,
    'removed_participant_rows', v_removed_participants,
    'removed_waitlist_rows', v_removed_waitlist,
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.decline_event(uuid, text, text)
  from public, anon;
grant execute on function public.decline_event(uuid, text, text)
  to authenticated;

create or replace function public.leave_event(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.creator_id = v_uid then
    raise exception 'Event creator cannot leave their own event';
  end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or (added_by = v_uid and not guest_only));
  get diagnostics v_deleted_rows = row_count;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object(
    'status', case when v_deleted_rows > 0 then 'left' else 'not_participant' end,
    'waiter_ids', v_waiters
  );
end;
$$;

revoke execute on function public.leave_event(uuid, uuid) from public, anon;
grant execute on function public.leave_event(uuid, uuid) to authenticated;

create or replace function public.cancel_pending(
  p_event_id uuid,
  p_user_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_deleted_rows int;
  v_waiters json;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid)
    and payment_status = 'pending';
  get diagnostics v_deleted_rows = row_count;

  if v_deleted_rows = 0 then
    return json_build_object('status', 'no_pending_row', 'waiter_ids', '[]'::json);
  end if;

  select coalesce(json_agg(user_id order by joined_at asc), '[]'::json)
  into v_waiters
  from public.event_waitlist
  where event_id = p_event_id;

  return json_build_object('status', 'cancelled', 'waiter_ids', v_waiters);
end;
$$;

revoke execute on function public.cancel_pending(uuid, uuid) from public, anon;
grant execute on function public.cancel_pending(uuid, uuid) to authenticated;

-- Before an occurrence ends, rejecting a transfer keeps the existing seat-
-- release behavior. Afterwards the attendance record is historical evidence:
-- rejection reopens the same debt instead of deleting the player and silently
-- unlocking the next occurrence.
create or replace function public.reject_payment(
  p_event_id uuid,
  p_user_id uuid,
  p_creator_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
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

    if v_changed_rows > 0 and v_series_key is not null then
      -- Revoke only an unpaid future hold. A transfer already declared or
      -- confirmed for that later occurrence is financial/attendance history
      -- and stays suspended behind the restored old-debt gate.
      with revoked as (
        delete from public.event_participants future_participant
        using public.events future_event,
              public.event_templates future_template
        where future_participant.event_id = future_event.id
          and future_template.id = future_event.template_id
          and future_template.series_key = v_series_key
          and future_event.cancelled_at is null
          and future_event.start_date > now()
          and future_event.start_date > v_event.start_date
          and future_participant.payment_status = 'pending'
          and future_participant.payment_declared_at is null
          and (future_participant.user_id = p_user_id
            or future_participant.added_by = p_user_id)
        returning future_participant.event_id
      )
      select count(*),
             coalesce(array_agg(distinct event_id), '{}'::uuid[])
      into v_revoked_future_seats, v_reopened_event_ids
      from revoked;

      insert into public.push_outbox (user_id, type, event_id)
      select distinct waiter.user_id, 'seat_available', waiter.event_id
      from public.event_waitlist waiter
      where waiter.event_id = any(v_reopened_event_ids);

      delete from public.event_waitlist future_waiter
      using public.events future_event,
            public.event_templates future_template
      where future_waiter.event_id = future_event.id
        and future_template.id = future_event.template_id
        and future_template.series_key = v_series_key
        and future_event.cancelled_at is null
        and future_event.start_date > now()
        and future_event.start_date > v_event.start_date
        and future_waiter.user_id = p_user_id;

      delete from public.event_member_responses future_response
      using public.events future_event,
            public.event_templates future_template
      where future_response.event_id = future_event.id
        and future_template.id = future_event.template_id
        and future_template.series_key = v_series_key
        and future_event.cancelled_at is null
        and future_event.start_date > now()
        and future_event.start_date > v_event.start_date
        and future_response.user_id = p_user_id;
    end if;
  else
    delete from public.event_participants
    where event_id = p_event_id
      and (user_id = p_user_id or added_by = p_user_id)
      and payment_status = 'pending';
    get diagnostics v_changed_rows = row_count;

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
$$;

revoke execute on function public.reject_payment(uuid, uuid, uuid)
  from public, anon;
grant execute on function public.reject_payment(uuid, uuid, uuid)
  to authenticated;

-- The old installation registered this job once per day.  Replace every
-- legacy copy by name, then run once per minute (0-59 seconds after release).
do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'recurring-events'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;

  perform cron.schedule(
    'recurring-events',
    '* * * * *',
    $cron$select public.generate_recurring_events();$cron$
  );
end;
$$;

-- Do not wait for the first cron tick on deploy.  This also heals any future
-- drafts left by the old lead-days implementation.
select public.generate_recurring_events();

notify pgrst, 'reload schema';
