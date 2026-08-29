-- Pin the roster function, so its winner stops depending on apply order.
--
-- get_event_participants_lifecycle_impl has been redefined six times, and two
-- of those live on branches that met out of order: the ratings migration is
-- dated 20260818 but reaches a project that already ran staging's 20260822.
-- Applied by filename it loses to staging's version, which is correct; applied
-- by `supabase db push --include-all` onto a project that is already ahead, it
-- arrives last and wins, quietly taking the guest and waitlist columns back out
-- of every roster the app reads.
--
-- This is staging's definition, the newest of the six, re-issued with a
-- timestamp after everything. Whichever way the two branches are applied, this
-- is the one that ends up live.

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
