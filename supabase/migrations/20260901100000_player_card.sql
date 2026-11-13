-- The player card: a generated portrait a member makes once and teammates see.
--
-- Three columns and one function. The function is the point of the migration.
--
-- Generating a card costs real money on every attempt, so the cap on attempts
-- cannot live in the app. A counter the client keeps is a counter the client
-- can reset — reinstall the app, or call the Edge Function directly, and the
-- bill is unbounded. `claim_player_card_attempt` moves the decision to the one
-- place that cannot be bypassed: it increments and checks in a single
-- statement, and the Edge Function spends nothing until it returns true.

alter table public.users
  add column if not exists player_card_url text,
  add column if not exists player_card_generated_at timestamptz,
  add column if not exists player_card_attempts integer not null default 0;

-- How many times one person may generate. Kept here rather than in the
-- function body so raising it is a one-line migration.
create or replace function public.player_card_attempt_limit()
returns integer
language sql
immutable
as $$ select 3 $$;

-- Takes one attempt if any are left.
--
-- `update ... returning` rather than select-then-update: two people cannot
-- race it, and neither can one person tapping "try again" twice. The row lock
-- the update takes is what makes the count true.
create or replace function public.claim_player_card_attempt(p_user_id uuid)
returns table (allowed boolean, attempts_used integer, attempts_left integer)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer := public.player_card_attempt_limit();
  v_used integer;
begin
  update public.users
    set player_card_attempts = player_card_attempts + 1
    where user_id = p_user_id
      and player_card_attempts < v_limit
    returning player_card_attempts into v_used;

  if v_used is null then
    -- Either the row is missing or the attempts are spent. Report what is
    -- left rather than raising: the caller shows the member a count, and an
    -- exception carries no count.
    select player_card_attempts into v_used
      from public.users where user_id = p_user_id;
    return query select false, coalesce(v_used, 0), greatest(v_limit - coalesce(v_used, 0), 0);
    return;
  end if;

  return query select true, v_used, greatest(v_limit - v_used, 0);
end;
$$;

revoke all on function public.claim_player_card_attempt(uuid) from public, anon, authenticated;

-- How many are left, for the screen that has to say so before spending one.
create or replace function public.player_card_attempts_left()
returns integer
language sql
security definer
set search_path = public
stable
as $$
  select greatest(
    public.player_card_attempt_limit()
      - coalesce((select player_card_attempts from public.users where user_id = auth.uid()), 0),
    0
  )
$$;

grant execute on function public.player_card_attempts_left() to authenticated;

-- The card has to reach the people it is for. `get_event_participants` is what
-- a teammate's sheet reads, so the column joins the roster beside the avatar it
-- sits next to on screen.
--
-- Re-issued whole rather than patched: the function has been redefined seven
-- times across branches that meet out of order, and 20260830170000 exists
-- precisely because a partial redefinition once took columns back out of every
-- roster. This is that same body with one column added.
create or replace function public.get_event_participants_lifecycle_impl(p_event_id uuid)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_event public.events;
  v_uid uuid := auth.uid();
begin
  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;

  return (
    select coalesce(
      json_agg(row_to_json(x) order by x.is_waitlisted asc, x.joined_at asc),
      '[]'::json)
    from (
      select
        ep.id as participant_id,
        ep.user_id,
        ep.created_at as joined_at,
        coalesce(usr.name, au.email, ep.guest_name) as display_name,
        usr.avatar_url,
        usr.player_card_url,
        usr.postion as player_position,
        ep.payment_status,
        ep.payment_provider,
        ep.payment_declared_at,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.payment_method_id else null end as payment_method_id,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_number else null end as paid_to_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_iban else null end as paid_to_iban,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_to_account_number else null end as paid_to_account_number,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id or v_uid = ep.added_by
          then ep.paid_price_per_person else null end as paid_price_per_person,
        case when v_uid = v_event.creator_id or v_uid = ep.user_id
          then ep.payment_group_size else null end as payment_group_size,
        ep.guest_name,
        ep.added_by,
        ep.added_manually,
        ep.guest_only,
        case when v_uid = v_event.creator_id
          then ep.payment_reminder_sent_at else null end as payment_reminder_sent_at,
        false as is_waitlisted
      from public.event_participants ep
      left join auth.users au on au.id = ep.user_id
      left join public.users usr on usr.user_id = ep.user_id
      where ep.event_id = p_event_id

      union all

      select
        ew.user_id as participant_id,
        ew.user_id,
        ew.joined_at,
        coalesce(usr.name, au.email) as display_name,
        usr.avatar_url,
        usr.player_card_url,
        null::text as player_position,
        null::text as payment_status,
        null::text as payment_provider,
        null::timestamptz as payment_declared_at,
        null::uuid as payment_method_id,
        null::text as paid_to_number,
        null::text as paid_to_iban,
        null::text as paid_to_account_number,
        null::decimal as paid_price_per_person,
        null::int as payment_group_size,
        null::text as guest_name,
        null::uuid as added_by,
        false as added_manually,
        false as guest_only,
        null::timestamptz as payment_reminder_sent_at,
        true as is_waitlisted
      from public.event_waitlist ew
      left join auth.users au on au.id = ew.user_id
      left join public.users usr on usr.user_id = ew.user_id
      where ew.event_id = p_event_id
    ) x
  );
end;
$$;

notify pgrst, 'reload schema';
