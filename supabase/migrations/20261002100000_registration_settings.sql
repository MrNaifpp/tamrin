-- Exercise registration settings: when registration opens, whether a seat is
-- granted on sight or by the organizer, and whether members may bring guests.
--
-- The organizer edits these from «الإعدادات» on an exercise. What he picks is
-- stored twice: on the exercise itself, and on the workspace as the default
-- every later exercise starts from. A trigger copies the workspace default
-- onto each new events row, so create_event, the recurring roll and any
-- future insert path inherit it without being rewritten here.
--
-- Manual approval turns a registration into requests: one for the member and
-- one for each guest they ask to bring, each decided on its own. The request
-- table is deliberately private: no RLS policy, no timestamp in any payload,
-- and the organizer's list is ordered by name. Nobody can tell who asked
-- first, which is the point of the feature.

-- ===========================================================================
-- 1. Columns
-- ===========================================================================

alter table public.events
  add column if not exists registration_opens_at timestamptz,
  add column if not exists registration_open_days_before int
    check (registration_open_days_before between 0 and 13),
  add column if not exists registration_open_minute int
    check (registration_open_minute between 0 and 1439),
  add column if not exists registration_opened_notified_at timestamptz,
  add column if not exists approval_mode text not null default 'auto'
    check (approval_mode in ('auto', 'manual')),
  add column if not exists guests_allowed boolean not null default true;

alter table public.workspaces
  add column if not exists registration_open_days_before int
    check (registration_open_days_before between 0 and 13),
  add column if not exists registration_open_minute int
    check (registration_open_minute between 0 and 1439),
  add column if not exists approval_mode text not null default 'auto'
    check (approval_mode in ('auto', 'manual')),
  add column if not exists guests_allowed boolean not null default true;

create table if not exists public.event_registration_requests (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events(id) on delete cascade,
  -- The member who asked. For their own row user_id is the same person; for
  -- a guest they want to bring user_id is null and guest_name says who.
  requested_by uuid not null references auth.users(id) on delete cascade,
  user_id uuid references auth.users(id) on delete cascade,
  guest_name text,
  status text not null default 'pending' check (status in ('pending', 'declined')),
  created_at timestamptz not null default now(),
  check ((user_id is null) <> (guest_name is null)),
  check (user_id is null or user_id = requested_by)
);

create unique index if not exists event_registration_requests_member_once
  on public.event_registration_requests (event_id, user_id)
  where user_id is not null;
create index if not exists event_registration_requests_by_requester
  on public.event_registration_requests (event_id, requested_by);

-- Read and written only through the security-definer RPCs below.
alter table public.event_registration_requests enable row level security;

-- ===========================================================================
-- 2. The opening rule
-- ===========================================================================

-- "Two days before, at 12:00" is a wall-clock rule in the group's own time,
-- not an interval: a session at 19:00 Tuesday opens at 12:00 Sunday.
create or replace function public.registration_opens_at_for(
  p_start timestamptz,
  p_days_before int,
  p_minute int
)
returns timestamptz
language sql
immutable
as $$
  select case
    when p_days_before is null or p_minute is null then null
    else (
      (((p_start at time zone 'Asia/Riyadh')::date - p_days_before)::timestamp
        + make_interval(mins => p_minute))
      at time zone 'Asia/Riyadh'
    )
  end;
$$;

create or replace function public.apply_workspace_registration_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ws public.workspaces;
begin
  if tg_op = 'INSERT' then
    select * into v_ws from public.workspaces where id = new.workspace_id;
    if v_ws.id is not null then
      new.approval_mode := coalesce(v_ws.approval_mode, 'auto');
      new.guests_allowed := coalesce(v_ws.guests_allowed, true);
      new.registration_open_days_before := v_ws.registration_open_days_before;
      new.registration_open_minute := v_ws.registration_open_minute;
    end if;
    new.registration_opens_at := public.registration_opens_at_for(
      new.start_date, new.registration_open_days_before, new.registration_open_minute);
    -- Already open on arrival: the publish push already says so.
    if new.registration_opens_at is null or new.registration_opens_at <= now() then
      new.registration_opened_notified_at := now();
    end if;
  elsif new.start_date is distinct from old.start_date
        and new.registration_open_days_before is not null
        and (old.registration_opens_at is null or old.registration_opens_at > now()) then
    -- Moving a session that has not opened yet moves its opening with it.
    new.registration_opens_at := public.registration_opens_at_for(
      new.start_date, new.registration_open_days_before, new.registration_open_minute);
    if new.registration_opens_at > now() then
      new.registration_opened_notified_at := null;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_apply_workspace_registration_defaults on public.events;
create trigger trg_apply_workspace_registration_defaults
  before insert or update of start_date on public.events
  for each row
  execute function public.apply_workspace_registration_defaults();

-- An invitation to a session nobody can register for yet would send people to
-- a locked button. The opening push below replaces it at the right moment.
create or replace function public.hold_invites_until_registration_opens()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.type in ('event_invited', 'event_opened') and exists (
    select 1 from public.events e
    where e.id = new.event_id
      and e.registration_opens_at is not null
      and e.registration_opens_at > now()
  ) then
    return null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_hold_invites_until_registration_opens on public.push_outbox;
create trigger trg_hold_invites_until_registration_opens
  before insert on public.push_outbox
  for each row
  execute function public.hold_invites_until_registration_opens();

-- ===========================================================================
-- 3. Guards on every way into a seat
-- ===========================================================================

-- Only a member acting for themselves is held back. The organizer seating
-- someone, an accepted request, and a waitlist promotion triggered by someone
-- else leaving all insert rows that are not the caller's own.
create or replace function public.guard_registration_settings()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_is_guest boolean;
begin
  if v_uid is null then return new; end if;

  if tg_table_name = 'event_waitlist' then
    if new.user_id is distinct from v_uid then return new; end if;
    v_is_guest := false;
  else
    if new.user_id is not null and new.user_id is distinct from v_uid then return new; end if;
    if new.user_id is null and new.added_by is distinct from v_uid then return new; end if;
    if coalesce(new.added_manually, false) then return new; end if;
    v_is_guest := new.user_id is null;
  end if;

  select * into v_event from public.events where id = new.event_id;
  if v_event.id is null then return new; end if;
  if v_event.creator_id = v_uid
     or public.is_workspace_owner(v_event.workspace_id, v_uid) then
    return new;
  end if;

  if v_event.registration_opens_at is not null and v_event.registration_opens_at > now() then
    raise exception 'registration_not_open';
  end if;
  if v_is_guest and not v_event.guests_allowed then
    raise exception 'guests_not_allowed';
  end if;
  if v_event.approval_mode = 'manual' then
    raise exception 'approval_required';
  end if;
  return new;
end;
$$;

drop trigger if exists trg_guard_registration_settings on public.event_participants;
create trigger trg_guard_registration_settings
  before insert on public.event_participants
  for each row
  execute function public.guard_registration_settings();

drop trigger if exists trg_guard_registration_settings on public.event_waitlist;
create trigger trg_guard_registration_settings
  before insert on public.event_waitlist
  for each row
  execute function public.guard_registration_settings();

-- ===========================================================================
-- 4. register_event_seat answers the new states instead of raising
-- ===========================================================================

-- The seat logic itself is untouched and lives on as the _direct function.
-- A later migration that rewrites register_event_seat must keep this wrapper's
-- checks, or the closed/manual states fall back to the raw trigger errors.
do $$
begin
  if not exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = 'register_event_seat_direct'
  ) then
    alter function public.register_event_seat(uuid, text[], decimal)
      rename to register_event_seat_direct;
  end if;
end;
$$;

revoke execute on function public.register_event_seat_direct(uuid, text[], decimal)
  from public, anon, authenticated;

create or replace function public.register_event_seat(
  p_event_id uuid,
  p_guest_names text[] default '{}',
  p_expected_price_per_person decimal default null
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_guests text[];
  v_existing public.event_registration_requests;
  v_debt_event_id uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  if public.is_workspace_owner(v_event.workspace_id, v_uid) or v_event.creator_id = v_uid then
    return public.register_event_seat_direct(p_event_id, p_guest_names, p_expected_price_per_person);
  end if;

  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  if v_event.registration_opens_at is not null and v_event.registration_opens_at > now() then
    return json_build_object('status', 'registration_not_open',
                             'registration_opens_at', v_event.registration_opens_at);
  end if;

  select coalesce(array_agg(trim(g)), '{}')
  into v_guests
  from unnest(coalesce(p_guest_names, '{}'::text[])) as g
  where g is not null and length(trim(g)) > 0;

  if cardinality(v_guests) > 0 and not v_event.guests_allowed then
    return json_build_object('status', 'guests_not_allowed');
  end if;

  if v_event.approval_mode <> 'manual' then
    return public.register_event_seat_direct(p_event_id, v_guests, p_expected_price_per_person);
  end if;

  if v_event.registration_locked then
    return json_build_object('status', 'registration_closed');
  end if;
  if exists (
    select 1 from public.event_participants
    where event_id = p_event_id and user_id = v_uid
  ) then
    return json_build_object('status', 'already_joined');
  end if;
  if p_expected_price_per_person is not null
    and abs(p_expected_price_per_person - coalesce(v_event.price_per_person, 0)) > 0.005 then
    return json_build_object('status', 'event_terms_changed');
  end if;

  select * into v_existing
  from public.event_registration_requests
  where event_id = p_event_id and user_id = v_uid;
  if v_existing.status = 'declined' then
    return json_build_object('status', 'request_declined');
  end if;

  -- The same refusal a direct registration meets (20260929120000): an unpaid
  -- earlier workout blocks a request too, or the organizer would accept one
  -- the seat guard then refuses.
  v_debt_event_id := public.unpaid_debt_event(v_event.workspace_id, v_uid);
  if v_debt_event_id is not null then
    raise exception using
      message = 'عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.',
      hint = 'payment_owed:' || v_debt_event_id::text;
  end if;

  insert into public.event_registration_requests (event_id, requested_by, user_id)
  values (p_event_id, v_uid, v_uid)
  on conflict (event_id, user_id) where user_id is not null do nothing;

  -- Asking again replaces the guests still waiting, not the ones already
  -- decided.
  delete from public.event_registration_requests
  where event_id = p_event_id and requested_by = v_uid
    and user_id is null and status = 'pending';
  insert into public.event_registration_requests (event_id, requested_by, guest_name)
  select p_event_id, v_uid, g from unnest(v_guests) as g;

  delete from public.event_member_responses
  where event_id = p_event_id and user_id = v_uid and status = 'declined';

  if v_existing.event_id is null then
    insert into public.push_outbox (user_id, type, event_id)
    values (v_event.creator_id, 'registration_requested', p_event_id);
  end if;

  return json_build_object('status', 'requested', 'event_id', p_event_id);
end;
$$;

revoke execute on function public.register_event_seat(uuid, text[], decimal) from public, anon;
grant execute on function public.register_event_seat(uuid, text[], decimal) to authenticated;

-- ===========================================================================
-- 5. Requests
-- ===========================================================================

-- Seats one request: a member, or one guest a member asked to bring. The
-- caller holds the event lock and has checked that the caller may act.
-- Returns 'accepted', 'seats_full' or 'not_found'.
create or replace function public.seat_registration_request_internal(
  p_event public.events,
  p_request_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.event_registration_requests;
  v_seats int;
  v_paid boolean := coalesce(p_event.total_price, 0) > 0;
begin
  select * into v_req
  from public.event_registration_requests
  where id = p_request_id and event_id = p_event.id and status = 'pending';
  if v_req.id is null then return 'not_found'; end if;

  if v_req.user_id is not null and exists (
    select 1 from public.event_participants
    where event_id = p_event.id and user_id = v_req.user_id
  ) then
    delete from public.event_registration_requests where id = v_req.id;
    return 'accepted';
  end if;

  if p_event.max_participants is not null then
    select count(*) into v_seats
    from public.event_participants
    where event_id = p_event.id and payment_status in ('pending', 'confirmed');
    if v_seats + 1 > p_event.max_participants then
      return 'seats_full';
    end if;
  end if;

  if v_req.user_id is not null then
    insert into public.event_participants
      (event_id, user_id, payment_status, payment_declared_at,
       paid_price_per_person, payment_group_size)
    values
      (p_event.id, v_req.user_id,
       case when v_paid then 'pending' else 'confirmed' end,
       case when v_paid then null else now() end,
       p_event.price_per_person, 1);

    delete from public.event_waitlist
    where event_id = p_event.id and user_id = v_req.user_id;

    insert into public.push_outbox (user_id, type, event_id)
    values (v_req.user_id, 'registration_accepted', p_event.id);
  else
    -- A guest can be accepted without the member who asked for them, in
    -- which case the seat is the member's guest-only booking.
    insert into public.event_participants
      (event_id, user_id, guest_name, added_by, payment_status,
       payment_declared_at, paid_price_per_person, guest_only)
    values
      (p_event.id, null, v_req.guest_name, v_req.requested_by,
       case when v_paid then 'pending' else 'confirmed' end,
       case when v_paid then null else now() end,
       p_event.price_per_person,
       not exists (
         select 1 from public.event_participants
         where event_id = p_event.id and user_id = v_req.requested_by
       ));
  end if;

  delete from public.event_registration_requests where id = v_req.id;
  return 'accepted';
end;
$$;

revoke execute on function public.seat_registration_request_internal(public.events, uuid)
  from public, anon, authenticated;

create or replace function public.respond_registration_request(
  p_request_id uuid,
  p_accept boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event_id uuid;
  v_event public.events;
  v_result text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select event_id into v_event_id
  from public.event_registration_requests where id = p_request_id;
  if v_event_id is null then
    return json_build_object('status', 'not_found');
  end if;

  select * into v_event from public.events where id = v_event_id for update;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized: only the organizer can respond to requests';
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;

  if p_accept then
    v_result := public.seat_registration_request_internal(v_event, p_request_id);
  else
    update public.event_registration_requests
    set status = 'declined'
    where id = p_request_id and status = 'pending';
    v_result := case when found then 'declined' else 'not_found' end;
  end if;

  return json_build_object('status', v_result);
end;
$$;

revoke execute on function public.respond_registration_request(uuid, boolean) from public, anon;
grant execute on function public.respond_registration_request(uuid, boolean) to authenticated;

-- Organizer only. Grouped by the member who asked, in name order, with the
-- member before their guests. No timestamp leaves the table.
create or replace function public.get_event_registration_requests(p_event_id uuid)
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
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  return (
    select coalesce(
      json_agg(row_to_json(x) order by x.requester_name, x.user_id is null, x.display_name),
      '[]'::json)
    from (
      select r.id,
             r.user_id,
             r.requested_by,
             r.guest_name,
             coalesce(r.guest_name, usr.name, au.email) as display_name,
             coalesce(usr.name, au.email) as requester_name,
             case when r.user_id is not null then usr.avatar_url end as avatar_url,
             case when r.user_id is not null then usr.postion end as player_position
      from public.event_registration_requests r
      left join public.users usr on usr.user_id = r.requested_by
      left join auth.users au on au.id = r.requested_by
      where r.event_id = p_event_id and r.status = 'pending'
    ) x
  );
end;
$$;

revoke execute on function public.get_event_registration_requests(uuid) from public, anon;
grant execute on function public.get_event_registration_requests(uuid) to authenticated;

create or replace function public.get_my_registration_request(p_event_id uuid)
returns json
language sql
security definer
set search_path = public
stable
as $$
  select json_build_object('status', r.status)
  from public.event_registration_requests r
  where r.event_id = p_event_id and r.user_id = auth.uid();
$$;

revoke execute on function public.get_my_registration_request(uuid) from public, anon;
grant execute on function public.get_my_registration_request(uuid) to authenticated;

-- Takes back the member's own request and the guests still waiting with it.
create or replace function public.withdraw_registration_request(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  delete from public.event_registration_requests
  where event_id = p_event_id and requested_by = auth.uid() and status = 'pending';
  return json_build_object('status', case when found then 'withdrawn' else 'not_found' end);
end;
$$;

revoke execute on function public.withdraw_registration_request(uuid) from public, anon;
grant execute on function public.withdraw_registration_request(uuid) to authenticated;

-- ===========================================================================
-- 6. Opening announcements
-- ===========================================================================

-- Tells the invited members that registration is open, once per exercise.
-- Reads the invitation rows publish wrote, so a member held back by an unpaid
-- earlier session stays held back here too.
create or replace function public.announce_registration_opening_internal(p_event_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event public.events;
begin
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null
     or v_event.registration_opened_notified_at is not null
     or v_event.published_at is null
     or v_event.cancelled_at is not null
     or (v_event.registration_opens_at is not null and v_event.registration_opens_at > now()) then
    return;
  end if;

  update public.events
  set registration_opened_notified_at = now()
  where id = p_event_id;

  insert into public.push_outbox (user_id, type, event_id)
  select r.user_id, 'event_opened', p_event_id
  from public.event_member_responses r
  where r.event_id = p_event_id
    and r.status = 'invited'
    and r.user_id <> v_event.creator_id
    and not exists (
      select 1 from public.event_participants ep
      where ep.event_id = p_event_id and ep.user_id = r.user_id
    )
    and not exists (
      select 1 from public.push_outbox po
      where po.event_id = p_event_id and po.user_id = r.user_id
        and po.type = 'event_opened'
    );
end;
$$;

revoke execute on function public.announce_registration_opening_internal(uuid)
  from public, anon, authenticated;

create or replace function public.announce_registration_openings()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  for v_id in
    select id from public.events
    where registration_opened_notified_at is null
      and registration_opens_at <= now()
      and published_at is not null
      and cancelled_at is null
      and coalesce(end_date, start_date) > now()
  loop
    perform public.announce_registration_opening_internal(v_id);
  end loop;
end;
$$;

revoke execute on function public.announce_registration_openings() from public, anon, authenticated;

do $$
declare
  v_job record;
begin
  for v_job in select jobid from cron.job where jobname = 'registration-openings'
  loop
    perform cron.unschedule(v_job.jobid);
  end loop;
  perform cron.schedule(
    'registration-openings',
    '* * * * *',
    $cron$select public.announce_registration_openings();$cron$
  );
end;
$$;

-- ===========================================================================
-- 7. Organizer controls
-- ===========================================================================

create or replace function public.open_event_registration_now(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  update public.events
  set registration_opens_at = date_trunc('second', now())
  where id = p_event_id
    and registration_opens_at is not null
    and registration_opens_at > now();

  perform public.announce_registration_opening_internal(p_event_id);

  select * into v_event from public.events where id = p_event_id;
  return to_jsonb(v_event);
end;
$$;

revoke execute on function public.open_event_registration_now(uuid) from public, anon;
grant execute on function public.open_event_registration_now(uuid) to authenticated;

-- Saves the organizer's settings on this exercise, on every exercise of the
-- group that has not finished yet, and on the group as the default for the
-- ones still to come. A null rule means registration is open from publish.
create or replace function public.update_event_registration_settings(
  p_event_id uuid,
  p_open_days_before int,
  p_open_minute int,
  p_approval_mode text,
  p_guests_allowed boolean
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_target public.events;
  v_req record;
  v_result text;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_approval_mode not in ('auto', 'manual') then
    raise exception 'Invalid approval mode: %', p_approval_mode;
  end if;
  if (p_open_days_before is null) <> (p_open_minute is null) then
    raise exception 'Opening rule needs both a day and a time';
  end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid)
     and v_event.creator_id <> v_uid then
    raise exception 'Not authorized';
  end if;

  update public.workspaces
  set registration_open_days_before = p_open_days_before,
      registration_open_minute = p_open_minute,
      approval_mode = p_approval_mode,
      guests_allowed = coalesce(p_guests_allowed, true)
  where id = v_event.workspace_id;

  for v_target in
    select * from public.events
    where workspace_id = v_event.workspace_id
      and coalesce(end_date, start_date) > now()
    order by start_date
    for update
  loop
    update public.events
    set registration_open_days_before = p_open_days_before,
        registration_open_minute = p_open_minute,
        registration_opens_at = public.registration_opens_at_for(
          start_date, p_open_days_before, p_open_minute),
        registration_opened_notified_at = case
          when public.registration_opens_at_for(start_date, p_open_days_before, p_open_minute) > now()
            then null
          else coalesce(registration_opened_notified_at, now())
        end,
        approval_mode = p_approval_mode,
        guests_allowed = coalesce(p_guests_allowed, true)
    where id = v_target.id
    returning * into v_target;

    -- Back to automatic: whoever was waiting on the organizer is seated now,
    -- member by member in no particular order, each before their guests. A
    -- member who no longer fits queues like any late registration.
    if p_approval_mode = 'auto' then
      for v_req in
        with requesters as (
          select requested_by, random() as k
          from public.event_registration_requests
          where event_id = v_target.id and status = 'pending'
          group by requested_by
        )
        select q.id, q.user_id
        from public.event_registration_requests q
        join requesters using (requested_by)
        where q.event_id = v_target.id and q.status = 'pending'
        order by requesters.k, q.user_id is null
      loop
        v_result := public.seat_registration_request_internal(v_target, v_req.id);
        if v_result = 'seats_full' then
          if v_req.user_id is not null and v_target.capacity_policy = 'waitlist' then
            insert into public.event_waitlist (event_id, user_id)
            values (v_target.id, v_req.user_id)
            on conflict (event_id, user_id) do nothing;
          end if;
          delete from public.event_registration_requests where id = v_req.id;
        end if;
      end loop;
      delete from public.event_registration_requests
      where event_id = v_target.id and status = 'declined';
    end if;
  end loop;

  select * into v_event from public.events where id = p_event_id;
  return to_jsonb(v_event);
end;
$$;

revoke execute on function public.update_event_registration_settings(uuid, int, int, text, boolean)
  from public, anon;
grant execute on function public.update_event_registration_settings(uuid, int, int, text, boolean)
  to authenticated;

notify pgrst, 'reload schema';
