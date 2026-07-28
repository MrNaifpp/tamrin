-- Event publication, member invitations, decline reasons, and occurrence
-- cancellation. Participation remains the sole source of truth for occupied
-- seats; an invitation never inserts into event_participants.

-- --------------------------------------------------------------------------
-- Publication/cancellation state. Existing rows stay published. create_event is
-- replaced below so newly composed events are explicit drafts; direct server
-- inserts retain the published default; the recurring generator explicitly
-- creates organizer-only drafts.
-- --------------------------------------------------------------------------
alter table public.events
  add column if not exists published_at timestamptz,
  add column if not exists cancelled_at timestamptz,
  add column if not exists cancelled_by uuid references auth.users(id) on delete set null,
  add column if not exists cancellation_reason_code text,
  add column if not exists cancellation_reason_text text;

update public.events
set published_at = coalesce(created_at, now())
where published_at is null;

alter table public.events
  alter column published_at set default now(),
  add constraint events_cancellation_reason_code_check check (
    cancellation_reason_code is null
    or cancellation_reason_code ~ '^[a-z0-9_-]{1,50}$'
  ),
  add constraint events_cancellation_reason_text_check check (
    cancellation_reason_text is null
    or char_length(cancellation_reason_text) <= 500
  );

create index idx_events_published_at on public.events(published_at);
create index idx_events_cancelled_at on public.events(cancelled_at)
  where cancelled_at is not null;

create or replace function public.is_workspace_owner(
  p_workspace_id uuid,
  p_user_id uuid
)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.workspaces w
    where w.id = p_workspace_id and w.owner_id = p_user_id
  );
$$;

revoke execute on function public.is_workspace_owner(uuid, uuid)
  from public, anon;
grant execute on function public.is_workspace_owner(uuid, uuid)
  to authenticated;

-- Lifecycle transitions must go through the RPCs below. Workspace owners may
-- edit ordinary event fields through the UPDATE policy, but a direct
-- authenticated PATCH cannot publish without invitations or forge/undo a
-- cancellation. SECURITY DEFINER lifecycle RPCs execute as their owner and are
-- therefore permitted through this trigger.
create or replace function public.guard_event_lifecycle_update()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.workspace_id is distinct from old.workspace_id then
    raise exception 'An event cannot be moved to another workspace';
  end if;

  if current_user in ('anon', 'authenticated')
     and (
       new.published_at is distinct from old.published_at
       or new.cancelled_at is distinct from old.cancelled_at
       or new.cancelled_by is distinct from old.cancelled_by
       or new.cancellation_reason_code is distinct from old.cancellation_reason_code
       or new.cancellation_reason_text is distinct from old.cancellation_reason_text
     ) then
    raise exception 'Event lifecycle changes must use the authorized RPC';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_event_lifecycle_update on public.events;
create trigger trg_guard_event_lifecycle_update
before update on public.events
for each row execute function public.guard_event_lifecycle_update();

revoke execute on function public.guard_event_lifecycle_update()
  from public, anon, authenticated;

alter table public.event_templates
  add column if not exists published_at timestamptz;

update public.event_templates
set published_at = coalesce(created_at, now())
where published_at is null;

alter table public.event_templates
  alter column published_at set default now();

create index idx_event_templates_published_at
  on public.event_templates(published_at);

-- Members see published events; only the workspace owner sees administrative
-- drafts, including drafts generated from a legacy member-owned template.
drop policy if exists "Members can select workspace events" on public.events;
create policy "Members can select published events and owner can select drafts"
  on public.events for select
  using (
    public.is_workspace_member(workspace_id, auth.uid())
    and (published_at is not null or public.is_workspace_owner(workspace_id, auth.uid()))
  );

drop policy if exists "Users can insert own events" on public.events;
create policy "Workspace owners can insert own draft events"
  on public.events for insert
  with check (
    creator_id = auth.uid()
    and public.is_workspace_owner(workspace_id, auth.uid())
    and published_at is null
  );

drop policy if exists "Creators can update own events" on public.events;
create policy "Workspace owners can update events"
  on public.events for update
  using (public.is_workspace_owner(workspace_id, auth.uid()))
  with check (public.is_workspace_owner(workspace_id, auth.uid()));

drop policy if exists "Creators can delete own events" on public.events;
create policy "Workspace owners can delete events"
  on public.events for delete
  using (public.is_workspace_owner(workspace_id, auth.uid()));

drop policy if exists "Members can select workspace templates"
  on public.event_templates;
create policy "Members can select published templates and owner can select drafts"
  on public.event_templates for select
  using (
    public.is_workspace_member(workspace_id, auth.uid())
    and (published_at is not null or public.is_workspace_owner(workspace_id, auth.uid()))
  );

-- --------------------------------------------------------------------------
-- A lightweight response is deliberately separate from event_participants:
-- invited/declined users do not reserve seats, enter payment flows, or receive
-- participant reminders. Joining removes the lightweight response.
-- --------------------------------------------------------------------------
create table public.event_member_responses (
  event_id uuid not null references public.events(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  status text not null check (status in ('invited', 'declined')),
  invited_by uuid references auth.users(id) on delete set null,
  reason_code text check (
    reason_code is null or reason_code ~ '^[a-z0-9_-]{1,50}$'
  ),
  reason_text text check (
    reason_text is null or char_length(reason_text) <= 500
  ),
  invited_at timestamptz,
  responded_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index idx_event_member_responses_user
  on public.event_member_responses(user_id, event_id);
create index idx_event_member_responses_event_status
  on public.event_member_responses(event_id, status);

alter table public.event_member_responses enable row level security;
revoke all on table public.event_member_responses from public, anon, authenticated;

-- Any successful real registration supersedes an invitation or decline.
create or replace function public.clear_event_member_response_on_registration()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.user_id is not null then
    delete from public.event_member_responses
    where event_id = new.event_id and user_id = new.user_id;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_clear_event_member_response_on_registration
  on public.event_participants;
create trigger trg_clear_event_member_response_on_registration
after insert on public.event_participants
for each row execute function public.clear_event_member_response_on_registration();

revoke execute on function public.clear_event_member_response_on_registration()
  from public, anon, authenticated;

-- Legacy recurring-event generation emitted event_opened to every current
-- workspace member. Mirror any such durable outbox row into the response table
-- so publish_event never sends the same availability notification twice.
create or replace function public.sync_event_opened_member_response()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
  v_owner_id uuid;
begin
  if new.event_id is null then return new; end if;

  select * into v_event
  from public.events
  where id = new.event_id
  for share;
  select owner_id into v_owner_id
  from public.workspaces
  where id = v_event.workspace_id;
  if v_event.id is null or new.user_id = v_owner_id then return new; end if;
  if not public.is_workspace_member(v_event.workspace_id, new.user_id) then return new; end if;
  if exists (
    select 1 from public.event_participants ep
    where ep.event_id = new.event_id and ep.user_id = new.user_id
  ) then
    return new;
  end if;

  insert into public.event_member_responses
    (event_id, user_id, status, invited_by, invited_at, updated_at)
  values
    (new.event_id, new.user_id, 'invited', v_owner_id,
     coalesce(new.created_at, now()), now())
  on conflict (event_id, user_id) do nothing;

  return new;
end;
$$;

drop trigger if exists trg_sync_event_opened_member_response
  on public.push_outbox;
create trigger trg_sync_event_opened_member_response
after insert on public.push_outbox
for each row when (new.type = 'event_opened')
execute function public.sync_event_opened_member_response();

revoke execute on function public.sync_event_opened_member_response()
  from public, anon, authenticated;

-- Backfill the invitation state for recurring occurrences opened before this
-- migration. Existing declines (if a deploy is retried from a snapshot) win.
insert into public.event_member_responses
  (event_id, user_id, status, invited_by, invited_at, updated_at)
select po.event_id, po.user_id, 'invited', w.owner_id, po.created_at, now()
from public.push_outbox po
join public.events e on e.id = po.event_id
join public.workspaces w on w.id = e.workspace_id
where po.type = 'event_opened'
  and po.event_id is not null
  and po.user_id <> w.owner_id
  and public.is_workspace_member(e.workspace_id, po.user_id)
  and not exists (
    select 1 from public.event_participants ep
    where ep.event_id = po.event_id and ep.user_id = po.user_id
  )
on conflict (event_id, user_id) do nothing;

-- Block every insert path (including direct table writes) once an event is a
-- draft, cancelled, or registration-locked. The creator's initial participant
-- row is allowed so create_event remains atomic.
create or replace function public.guard_event_registration_insert()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
begin
  select * into v_event
  from public.events
  where id = new.event_id
  for share;
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

  if tg_table_name = 'event_participants'
     and new.user_id is not null
     and new.user_id = v_event.creator_id
     and v_event.cancelled_at is null
     and not v_event.registration_locked then
    return new;
  end if;

  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then raise exception 'Registration is closed for this event'; end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_event_participant_insert
  on public.event_participants;
create trigger trg_guard_event_participant_insert
before insert on public.event_participants
for each row execute function public.guard_event_registration_insert();

drop trigger if exists trg_guard_event_waitlist_insert
  on public.event_waitlist;
create trigger trg_guard_event_waitlist_insert
before insert on public.event_waitlist
for each row execute function public.guard_event_registration_insert();

revoke execute on function public.guard_event_registration_insert()
  from public, anon, authenticated;

-- create_event keeps the current wire contract, price calculation, and payment
-- validation, but explicitly creates both the occurrence and a new recurring
-- template as drafts. publish_event activates both in one transaction.
drop function if exists public.create_event(
  uuid, text, text, text, timestamptz, timestamptz, text, int
);

create or replace function public.create_event(
  p_creator_id uuid,
  p_workspace_id uuid,
  p_name text,
  p_location text default '',
  p_description text default '',
  p_start_date timestamptz default now(),
  p_end_date timestamptz default null,
  p_image_url text default null,
  p_max_participants int default null,
  p_total_price int default 0,
  p_price_per_person decimal default 0,
  p_latitude double precision default null,
  p_longitude double precision default null,
  p_recurrence text default 'none',
  p_payment_method_id uuid default null,
  p_payment_method_ids uuid[] default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_template_id uuid;
  v_duration_minutes int;
  v_payment_method_ids uuid[];
begin
  if v_uid is null or p_creator_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  if not public.is_workspace_owner(p_workspace_id, v_uid) then
    raise exception 'Only the workspace owner can create events';
  end if;
  if p_recurrence not in ('none', 'weekly') then
    raise exception 'Invalid recurrence: %', p_recurrence;
  end if;
  if p_total_price < 0 then
    raise exception 'Total price cannot be negative';
  end if;
  if p_max_participants is not null and p_max_participants <= 0 then
    raise exception 'Player count must be greater than zero';
  end if;
  if p_total_price > 0 and p_max_participants is null then
    raise exception 'Player count is required when total price is greater than zero';
  end if;

  v_payment_method_ids := coalesce(p_payment_method_ids, '{}'::uuid[]);
  if cardinality(v_payment_method_ids) = 0 and p_payment_method_id is not null then
    v_payment_method_ids := array[p_payment_method_id];
  end if;
  if p_total_price > 0 and cardinality(v_payment_method_ids) = 0 then
    raise exception 'A payment method is required when total price is greater than zero';
  end if;
  if cardinality(v_payment_method_ids) <> (
    select count(distinct selected_id)
    from unnest(v_payment_method_ids) as selected(selected_id)
  ) then
    raise exception 'Payment methods must be non-null and unique';
  end if;
  if exists (
    select 1
    from unnest(v_payment_method_ids) as selected(selected_id)
    left join public.workspace_payment_methods pm
      on pm.id = selected.selected_id
     and pm.workspace_id = p_workspace_id
    where pm.id is null
  ) then
    raise exception 'Payment method does not belong to the event workspace';
  end if;

  if p_recurrence = 'weekly' then
    if p_end_date is not null then
      v_duration_minutes :=
        (extract(epoch from (p_end_date - p_start_date)) / 60)::int;
    end if;
    insert into public.event_templates
      (workspace_id, creator_id, name, location, description, image_url,
       latitude, longitude, total_price, price_per_person, max_participants,
       duration_minutes, recurrence, next_occurrence_at, payment_method_id,
       payment_method_ids, published_at)
    values
      (p_workspace_id, v_uid, p_name, p_location, p_description, p_image_url,
       p_latitude, p_longitude, p_total_price, 0, p_max_participants,
       v_duration_minutes, 'weekly', p_start_date + interval '7 days',
       v_payment_method_ids[1], v_payment_method_ids, null)
    returning id into v_template_id;
  end if;

  insert into public.events
    (creator_id, workspace_id, name, location, description, start_date,
     end_date, image_url, max_participants, total_price, price_per_person,
     latitude, longitude, template_id, payment_method_id, payment_method_ids,
     published_at)
  values
    (v_uid, p_workspace_id, p_name, p_location, p_description, p_start_date,
     p_end_date, p_image_url, p_max_participants, p_total_price, 0,
     p_latitude, p_longitude, v_template_id, v_payment_method_ids[1],
     v_payment_method_ids, null)
  returning * into v_event;

  insert into public.event_participants (event_id, user_id)
  values (v_event.id, v_uid);

  return row_to_json(v_event);
end;
$$;

revoke execute on function public.create_event(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[]
) from public, anon;
grant execute on function public.create_event(
  uuid, uuid, text, text, text, timestamptz, timestamptz, text, int, int,
  decimal, double precision, double precision, text, uuid, uuid[]
) to authenticated;

-- Atomically edits the concrete occurrence and, when requested, rebuilds its
-- weekly template in the same transaction. Rebuilding ends the old template so
-- historical occurrences keep their original series link, while the new
-- template preserves the old template's published/draft state.
create or replace function public.update_event_with_scope(
  p_event_id uuid,
  p_scope text,
  p_name text,
  p_location text,
  p_start_date timestamptz,
  p_end_date timestamptz,
  p_max_participants int,
  p_total_price int,
  p_latitude double precision,
  p_longitude double precision,
  p_payment_method_ids uuid[]
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_old_template public.event_templates;
  v_new_template public.event_templates;
  v_old_template_id uuid;
  v_payment_method_ids uuid[] := coalesce(p_payment_method_ids, '{}'::uuid[]);
  v_duration_minutes int;
  v_template_published_at timestamptz;
  v_lead_days int := 3;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_scope is null or p_scope not in ('occurrence_only', 'series_template') then
    raise exception 'Invalid edit scope';
  end if;
  if nullif(trim(p_name), '') is null then raise exception 'Event name is required'; end if;
  if p_total_price < 0 then raise exception 'Total price cannot be negative'; end if;
  if p_max_participants is not null and p_max_participants <= 0 then
    raise exception 'Player count must be greater than zero';
  end if;
  if p_total_price > 0 and p_max_participants is null then
    raise exception 'Player count is required when total price is greater than zero';
  end if;
  if p_end_date is not null and p_end_date <= p_start_date then
    raise exception 'Event end must be after its start';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id
  for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can edit events';
  end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;

  if p_total_price > 0 and cardinality(v_payment_method_ids) = 0 then
    raise exception 'A payment method is required when total price is greater than zero';
  end if;
  if cardinality(v_payment_method_ids) <> (
    select count(distinct selected_id)
    from unnest(v_payment_method_ids) as selected(selected_id)
  ) then
    raise exception 'Payment methods must be non-null and unique';
  end if;
  if exists (
    select 1
    from unnest(v_payment_method_ids) as selected(selected_id)
    left join public.workspace_payment_methods pm
      on pm.id = selected.selected_id
     and pm.workspace_id = v_event.workspace_id
    where pm.id is null
  ) then
    raise exception 'Payment method does not belong to the event workspace';
  end if;

  v_old_template_id := v_event.template_id;

  update public.events
  set name = trim(p_name),
      location = coalesce(p_location, ''),
      start_date = p_start_date,
      end_date = p_end_date,
      max_participants = p_max_participants,
      total_price = p_total_price,
      price_per_person = 0,
      latitude = p_latitude,
      longitude = p_longitude,
      payment_method_id = v_payment_method_ids[1],
      payment_method_ids = v_payment_method_ids
  where id = p_event_id
  returning * into v_event;

  if p_scope = 'series_template' then
    if v_old_template_id is null then
      raise exception 'Active recurrence template is required for series_template';
    end if;
    select * into v_old_template
    from public.event_templates
    where id = v_old_template_id
    for update;
    if v_old_template.id is null or v_old_template.ended_at is not null then
      raise exception 'Active recurrence template is required for series_template';
    end if;

    v_template_published_at := v_old_template.published_at;
    v_lead_days := v_old_template.lead_days;
    update public.event_templates
    set ended_at = now()
    where id = v_old_template.id;

    if p_end_date is not null then
      v_duration_minutes :=
        (extract(epoch from (p_end_date - p_start_date)) / 60)::int;
    end if;

    insert into public.event_templates
      (workspace_id, creator_id, name, location, description, image_url,
       latitude, longitude, total_price, price_per_person, max_participants,
       duration_minutes, recurrence, next_occurrence_at, lead_days,
       payment_method_id, payment_method_ids, published_at)
    values
      (v_event.workspace_id, v_uid, v_event.name, v_event.location,
       v_event.description, v_event.image_url, v_event.latitude, v_event.longitude,
       v_event.total_price, 0, v_event.max_participants, v_duration_minutes,
       'weekly', v_event.start_date + interval '7 days', v_lead_days,
       v_event.payment_method_id, v_event.payment_method_ids,
       v_template_published_at)
    returning * into v_new_template;

    update public.events
    set template_id = v_new_template.id
    where id = p_event_id
    returning * into v_event;
  end if;

  return json_build_object(
    'status', 'updated',
    'scope', p_scope,
    'event', row_to_json(v_event),
    'template', case
      when v_new_template.id is null then null
      else row_to_json(v_new_template)
    end
  );
end;
$$;

revoke execute on function public.update_event_with_scope(
  uuid, text, text, text, timestamptz, timestamptz, int, int,
  double precision, double precision, uuid[]
) from public, anon;
grant execute on function public.update_event_with_scope(
  uuid, text, text, text, timestamptz, timestamptz, int, int,
  double precision, double precision, uuid[]
) to authenticated;

-- --------------------------------------------------------------------------
-- Publish an existing event and invite every current workspace member. The
-- operation is idempotent: existing invited/declined responses are untouched,
-- registered members are skipped, and pushes are emitted only for new rows.
-- --------------------------------------------------------------------------
create or replace function public.publish_event(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_new_invites int := 0;
  v_notifications int := 0;
  v_total_invited int := 0;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can publish events';
  end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  update public.events
  set published_at = coalesce(published_at, now())
  where id = p_event_id
  returning * into v_event;

  if v_event.template_id is not null then
    update public.event_templates
    set published_at = coalesce(published_at, v_event.published_at)
    where id = v_event.template_id
      and ended_at is null;
  end if;

  with inserted as (
    insert into public.event_member_responses
      (event_id, user_id, status, invited_by, invited_at, updated_at)
    select v_event.id, wm.user_id, 'invited', v_uid, now(), now()
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id <> v_uid
      and not exists (
        select 1 from public.event_participants ep
        where ep.event_id = v_event.id and ep.user_id = wm.user_id
      )
    on conflict (event_id, user_id) do nothing
    returning user_id
  ), notified as (
    insert into public.push_outbox (user_id, type, event_id)
    select i.user_id, 'event_invited', v_event.id
    from inserted i
    where not exists (
      select 1 from public.push_outbox po
      where po.event_id = v_event.id
        and po.user_id = i.user_id
        and po.type in ('event_opened', 'event_invited')
    )
    returning user_id
  )
  select (select count(*) from inserted), (select count(*) from notified)
  into v_new_invites, v_notifications;

  select count(*) into v_total_invited
  from public.event_member_responses
  where event_id = v_event.id and status = 'invited';

  return json_build_object(
    'status', 'published',
    'event_id', v_event.id,
    'published_at', v_event.published_at,
    'new_invite_count', v_new_invites,
    'invited_count', v_total_invited,
    'notification_count', v_notifications
  );
end;
$$;

revoke execute on function public.publish_event(uuid) from public, anon;
grant execute on function public.publish_event(uuid) to authenticated;

-- The workspace owner reads the whole response list; a regular member may read
-- only their own response. Reasons never leak to the rest of the workspace.
create or replace function public.get_event_member_responses(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(json_agg(row_to_json(x) order by x.updated_at desc), '[]'::json)
    from (
      select r.user_id,
             coalesce(usr.name, au.email, 'عضو') as display_name,
             usr.avatar_url,
             r.status,
             r.reason_code,
             r.reason_text,
             r.invited_by,
             r.invited_at,
             r.responded_at,
             r.updated_at
      from public.event_member_responses r
      left join public.users usr on usr.user_id = r.user_id
      left join auth.users au on au.id = r.user_id
      where r.event_id = p_event_id
        and (public.is_workspace_owner(v_event.workspace_id, v_uid) or r.user_id = v_uid)
    ) x
  );
end;
$$;

revoke execute on function public.get_event_member_responses(uuid) from public, anon;
grant execute on function public.get_event_member_responses(uuid) to authenticated;

-- --------------------------------------------------------------------------
-- Decline/withdraw from a visible event, atomically freeing the caller's whole
-- participant group and waitlist row before persisting the optional reason.
-- --------------------------------------------------------------------------
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

  delete from public.event_participants
  where event_id = p_event_id
    and (user_id = v_uid or added_by = v_uid);
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

revoke execute on function public.decline_event(uuid, text, text) from public, anon;
grant execute on function public.decline_event(uuid, text, text) to authenticated;

-- --------------------------------------------------------------------------
-- Cancel/skip the currently visible occurrence without deleting it. Existing
-- registrations and payment snapshots remain available for reconciliation.
-- Every current workspace member receives one server-driven notification.
-- --------------------------------------------------------------------------
create or replace function public.cancel_event_occurrence(
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
  v_notifications int := 0;
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
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can cancel events';
  end if;
  if coalesce(v_event.end_date, v_event.start_date) < now() then
    raise exception 'Event has ended';
  end if;

  if v_event.cancelled_at is not null then
    return json_build_object(
      'status', 'already_cancelled',
      'event_id', v_event.id,
      'cancelled_at', v_event.cancelled_at,
      'reason_code', v_event.cancellation_reason_code,
      'reason_text', v_event.cancellation_reason_text,
      'notification_count', 0
    );
  end if;

  update public.events
  set published_at = coalesce(published_at, now()),
      cancelled_at = now(),
      cancelled_by = v_uid,
      cancellation_reason_code = v_reason_code,
      cancellation_reason_text = v_reason_text,
      registration_locked = true
  where id = p_event_id
  returning * into v_event;

  -- Cancelling only this week must not end a recurring plan. Publishing the
  -- linked draft template lets later weeks continue through the normal cron.
  if v_event.template_id is not null then
    update public.event_templates
    set published_at = coalesce(published_at, v_event.published_at)
    where id = v_event.template_id
      and ended_at is null;
  end if;

  with notified as (
    insert into public.push_outbox (user_id, type, event_id)
    select wm.user_id, 'event_cancelled', v_event.id
    from public.workspace_members wm
    where wm.workspace_id = v_event.workspace_id
      and wm.user_id <> v_uid
    returning user_id
  )
  select count(*) into v_notifications from notified;

  return json_build_object(
    'status', 'cancelled',
    'event_id', v_event.id,
    'cancelled_at', v_event.cancelled_at,
    'reason_code', v_event.cancellation_reason_code,
    'reason_text', v_event.cancellation_reason_text,
    'notification_count', v_notifications
  );
end;
$$;

revoke execute on function public.cancel_event_occurrence(uuid, text, text)
  from public, anon;
grant execute on function public.cancel_event_occurrence(uuid, text, text)
  to authenticated;

-- Draft recurring templates do not generate. Once publish_event activates the
-- template, cron creates each concrete occurrence as an organizer-only draft.
-- The organizer's explicit publish_event action is the sole point that makes
-- that occurrence visible and sends member invitations.
create or replace function public.generate_recurring_events()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  tpl record;
  v_event public.events;
begin
  for tpl in
    select * from public.event_templates t
    where t.ended_at is null
      and t.published_at is not null
      and now() >= t.next_occurrence_at - make_interval(days => t.lead_days)
    order by t.next_occurrence_at
    for update
  loop
    -- A removed legacy creator must not abort the whole cron transaction and
    -- block unrelated workspaces. End that orphaned series and continue.
    if not public.is_workspace_member(tpl.workspace_id, tpl.creator_id) then
      update public.event_templates
      set ended_at = coalesce(ended_at, now())
      where id = tpl.id;
      continue;
    end if;

    if tpl.skip_next then
      update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at + interval '7 days',
          skip_next = false
      where id = tpl.id;
      continue;
    end if;

    while tpl.next_occurrence_at <= now() loop
      tpl.next_occurrence_at := tpl.next_occurrence_at + interval '7 days';
    end loop;

    if now() < tpl.next_occurrence_at - make_interval(days => tpl.lead_days) then
      update public.event_templates
      set next_occurrence_at = tpl.next_occurrence_at
      where id = tpl.id;
      continue;
    end if;

    insert into public.events
      (creator_id, workspace_id, name, location, description, start_date,
       end_date, image_url, max_participants, total_price, price_per_person,
       latitude, longitude, template_id, payment_method_id, payment_method_ids,
       published_at)
    values
      (tpl.creator_id, tpl.workspace_id, tpl.name, tpl.location, tpl.description,
       tpl.next_occurrence_at,
       case when tpl.duration_minutes is not null
         then tpl.next_occurrence_at + make_interval(mins => tpl.duration_minutes) end,
       tpl.image_url, tpl.max_participants, tpl.total_price, 0,
       tpl.latitude, tpl.longitude, tpl.id, tpl.payment_method_id,
       tpl.payment_method_ids, null)
    returning * into v_event;

    insert into public.event_participants (event_id, user_id)
    values (v_event.id, tpl.creator_id);

    update public.event_templates
    set next_occurrence_at = tpl.next_occurrence_at + interval '7 days'
    where id = tpl.id;
  end loop;
end;
$$;

revoke execute on function public.generate_recurring_events()
  from public, anon, authenticated;

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
  v_duration_minutes int;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if v_uid is null or not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can manage recurrence';
  end if;

  if v_event.template_id is not null then
    select * into v_template
    from public.event_templates
    where id = v_event.template_id
    for update;
  end if;

  if v_template.id is not null and v_template.ended_at is null then
    return row_to_json(v_template);
  end if;

  if v_template.id is not null then
    update public.event_templates
    set ended_at = null,
        skip_next = false,
        creator_id = v_uid,
        published_at = v_event.published_at
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
     payment_method_ids, published_at)
  values
    (v_event.workspace_id, v_uid, v_event.name, v_event.location,
     v_event.description, v_event.image_url, v_event.latitude, v_event.longitude,
     v_event.total_price, 0, v_event.max_participants, v_duration_minutes,
     'weekly', v_event.start_date + interval '7 days',
     v_event.payment_method_id, v_event.payment_method_ids, v_event.published_at)
  returning * into v_template;

  update public.events set template_id = v_template.id where id = p_event_id;
  return row_to_json(v_template);
end;
$$;

revoke execute on function public.enable_recurrence(uuid) from public, anon;
grant execute on function public.enable_recurrence(uuid) to authenticated;

create or replace function public.skip_next_occurrence(
  p_template_id uuid,
  p_event_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_template public.event_templates;
  v_open_event uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_template
  from public.event_templates
  where id = p_template_id
  for update;
  if v_template.id is null then raise exception 'Template not found'; end if;
  if not public.is_workspace_owner(v_template.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can manage recurrence';
  end if;
  if v_template.ended_at is not null then raise exception 'Series has ended'; end if;

  select id into v_open_event
  from public.events
  where template_id = p_template_id
    and start_date > now()
    and id <> p_event_id
  order by start_date asc
  limit 1;
  if v_open_event is not null then
    return json_build_object('status', 'already_open', 'event_id', v_open_event);
  end if;

  update public.event_templates
  set skip_next = true
  where id = p_template_id;
  return json_build_object(
    'status', 'skipped',
    'skipped_date', v_template.next_occurrence_at
  );
end;
$$;

revoke execute on function public.skip_next_occurrence(uuid, uuid)
  from public, anon;
grant execute on function public.skip_next_occurrence(uuid, uuid)
  to authenticated;

create or replace function public.end_recurrence(p_template_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_template public.event_templates;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_template
  from public.event_templates
  where id = p_template_id
  for update;
  if v_template.id is null then raise exception 'Template not found'; end if;
  if not public.is_workspace_owner(v_template.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can manage recurrence';
  end if;

  update public.event_templates
  set ended_at = coalesce(ended_at, now())
  where id = p_template_id;
  return json_build_object('status', 'ended');
end;
$$;

revoke execute on function public.end_recurrence(uuid) from public, anon;
grant execute on function public.end_recurrence(uuid) to authenticated;

create or replace function public.get_event_template(p_template_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_template public.event_templates;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_template
  from public.event_templates
  where id = p_template_id;
  if v_template.id is null then raise exception 'Template not found'; end if;
  if not public.is_workspace_member(v_template.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_template.published_at is null
     and not public.is_workspace_owner(v_template.workspace_id, v_uid) then
    raise exception 'Template is not published';
  end if;
  return row_to_json(v_template);
end;
$$;

revoke execute on function public.get_event_template(uuid) from public, anon;
grant execute on function public.get_event_template(uuid) to authenticated;

-- Preserve the latest payment/participant payloads while putting the same
-- draft-visibility rule in front of their pre-existing SECURITY DEFINER RPCs.
-- The implementation functions are private to the lifecycle wrappers.
alter function public.get_event_payment_destination(uuid)
  rename to get_event_payment_destination_lifecycle_impl;
revoke execute on function public.get_event_payment_destination_lifecycle_impl(uuid)
  from public, anon, authenticated;

create or replace function public.get_event_payment_destination(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null
     and not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Event is not published';
  end if;
  return public.get_event_payment_destination_lifecycle_impl(p_event_id);
end;
$$;

revoke execute on function public.get_event_payment_destination(uuid)
  from public, anon;
grant execute on function public.get_event_payment_destination(uuid)
  to authenticated;

alter function public.get_event_participants(uuid)
  rename to get_event_participants_lifecycle_impl;
revoke execute on function public.get_event_participants_lifecycle_impl(uuid)
  from public, anon, authenticated;

create or replace function public.get_event_participants(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null
     and not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Event is not published';
  end if;
  return public.get_event_participants_lifecycle_impl(p_event_id);
end;
$$;

revoke execute on function public.get_event_participants(uuid) from public, anon;
grant execute on function public.get_event_participants(uuid) to authenticated;

-- --------------------------------------------------------------------------
-- Feed/detail output. Cancelled future events deliberately remain in the same
-- upcoming query and are identified by is_cancelled + reason fields.
-- --------------------------------------------------------------------------
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
               select 1 from public.event_templates t
               where t.id = e.template_id and t.ended_at is null
             ) as is_recurring
      from public.events e
      left join public.event_member_responses r
        on r.event_id = e.id and r.user_id = v_uid
      where e.workspace_id = p_workspace_id
        and (e.published_at is not null or public.is_workspace_owner(e.workspace_id, v_uid))
        and coalesce(e.end_date, e.start_date) >= now()
    ) x
  );
end;
$$;

revoke execute on function public.get_workspace_events(uuid) from public, anon;
grant execute on function public.get_workspace_events(uuid) to authenticated;

create or replace function public.get_event_by_id(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  -- Published and cancelled occurrences preserve the existing public-link
  -- contract. Only the authenticated workspace owner can resolve a draft.
  if v_event.published_at is null
     and (v_uid is null
       or not public.is_workspace_owner(v_event.workspace_id, v_uid)) then
    raise exception 'Event is not published';
  end if;

  return to_jsonb(v_event)
    || jsonb_build_object(
      'is_published', v_event.published_at is not null,
      'is_cancelled', v_event.cancelled_at is not null,
      'my_response_status', (
        select r.status from public.event_member_responses r
        where r.event_id = v_event.id and r.user_id = v_uid
      ),
      'current_user_response', (
        select r.status from public.event_member_responses r
        where r.event_id = v_event.id and r.user_id = v_uid
      ),
      'current_user_reason_code', (
        select r.reason_code from public.event_member_responses r
        where r.event_id = v_event.id and r.user_id = v_uid
      ),
      'current_user_reason_text', (
        select r.reason_text from public.event_member_responses r
        where r.event_id = v_event.id and r.user_id = v_uid
      ),
      'is_recurring', exists (
        select 1 from public.event_templates t
        where t.id = v_event.template_id and t.ended_at is null
      )
    );
end;
$$;

revoke execute on function public.get_event_by_id(uuid) from public;
grant execute on function public.get_event_by_id(uuid) to anon, authenticated;

-- Auth-bound join surfaces. The insert triggers are defense in depth for every
-- other current or legacy path.
create or replace function public.join_event(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then
    raise exception 'Registration is closed for this event';
  end if;

  insert into public.event_participants (event_id, user_id)
  values (p_event_id, v_uid)
  on conflict (event_id, user_id) where user_id is not null do nothing;
  return true;
end;
$$;

revoke execute on function public.join_event(uuid, uuid) from public, anon;
grant execute on function public.join_event(uuid, uuid) to authenticated;

create or replace function public.join_waitlist(p_event_id uuid, p_user_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null then raise exception 'Event is not published'; end if;
  if v_event.cancelled_at is not null then raise exception 'Event is cancelled'; end if;
  if v_event.registration_locked then
    raise exception 'Registration is closed for this event';
  end if;

  insert into public.event_waitlist (event_id, user_id)
  values (p_event_id, v_uid)
  on conflict (event_id, user_id) do nothing;
  return json_build_object('status', 'joined');
end;
$$;

revoke execute on function public.join_waitlist(uuid, uuid) from public, anon;
grant execute on function public.join_waitlist(uuid, uuid) to authenticated;

-- Cancelled/unpublished occurrences never enqueue the normal upcoming reminder.
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
      and e.published_at is not null
      and e.cancelled_at is null
      and e.start_date > now()
      and e.start_date <= now() + interval '12 hours'
      and exists (
        select 1 from public.event_participants ep
        where ep.event_id = e.id
          and ep.user_id is not null
          and ep.payment_status = 'confirmed'
      )
  ), enqueued as (
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

revoke execute on function public.enqueue_event_reminders()
  from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Harden the two legacy administrative RPCs that still trusted p_user_id and
-- were executable by anon. Their signatures remain wire-compatible.
-- --------------------------------------------------------------------------
create or replace function public.delete_event(p_event_id uuid, p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null
     or not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Event not found or you are not the workspace owner';
  end if;

  delete from public.push_outbox where event_id = p_event_id;
  delete from public.events where id = p_event_id;
  return true;
end;
$$;

revoke execute on function public.delete_event(uuid, uuid) from public, anon;
grant execute on function public.delete_event(uuid, uuid) to authenticated;

create or replace function public.toggle_event_registration_lock(
  p_event_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_new_value boolean;
begin
  if v_uid is null or p_user_id is distinct from v_uid then
    raise exception 'Not authorized';
  end if;
  update public.events
  set registration_locked = not registration_locked
  where id = p_event_id
    and public.is_workspace_owner(workspace_id, v_uid)
    and cancelled_at is null
  returning registration_locked into v_new_value;
  if v_new_value is null then
    raise exception 'Event not found, cancelled, or you are not the workspace owner';
  end if;
  return v_new_value;
end;
$$;

revoke execute on function public.toggle_event_registration_lock(uuid, uuid)
  from public, anon;
grant execute on function public.toggle_event_registration_lock(uuid, uuid)
  to authenticated;

notify pgrst, 'reload schema';
