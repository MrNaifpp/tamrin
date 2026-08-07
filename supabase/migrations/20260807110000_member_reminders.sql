-- Organizer-initiated reminders to the whole group: register for this
-- exercise, or pay your share of it. One push per recipient, and — like the
-- single-player nudge — rate limited on the server, because a broadcast is
-- exactly the button someone taps twice.

alter table public.events
  add column if not exists register_reminder_sent_at timestamptz,
  add column if not exists payment_reminder_sent_at timestamptz;

-- --------------------------------------------------------------------------
-- remind_event_members: 'register' reaches the workspace members who have no
-- seat yet; 'payment' reaches everyone already seated. Both skip the caller
-- and anyone without an account, and both report the recipient count so the
-- organizer sees that the push actually went somewhere.
-- --------------------------------------------------------------------------
create or replace function public.remind_event_members(
  p_event_id uuid,
  p_kind text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_cooldown constant interval := interval '1 hour';
  v_event public.events;
  v_last_sent timestamptz;
  v_next_allowed timestamptz;
  v_push_type text;
  v_sent int := 0;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if p_kind not in ('register', 'payment') then
    raise exception 'Unknown reminder kind: %', p_kind;
  end if;

  select * into v_event from public.events where id = p_event_id for update;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can remind members';
  end if;
  if v_event.cancelled_at is not null then
    return json_build_object('status', 'cancelled');
  end if;
  -- Nobody can act on a reminder for an exercise they cannot see yet.
  if v_event.published_at is null then
    return json_build_object('status', 'not_published');
  end if;

  v_last_sent := case p_kind
    when 'register' then v_event.register_reminder_sent_at
    else v_event.payment_reminder_sent_at
  end;
  v_next_allowed := v_last_sent + v_cooldown;
  if v_last_sent is not null and v_next_allowed > now() then
    return json_build_object('status', 'too_soon', 'next_allowed_at', v_next_allowed);
  end if;

  v_push_type := case p_kind
    when 'register' then 'registration_reminder'
    else 'payment_reminder'
  end;

  if p_kind = 'register' then
    with recipients as (
      select wm.user_id
      from public.workspace_members wm
      where wm.workspace_id = v_event.workspace_id
        and wm.user_id <> v_uid
        and not exists (
          select 1 from public.event_participants ep
          where ep.event_id = v_event.id and ep.user_id = wm.user_id
        )
    ),
    enqueued as (
      insert into public.push_outbox (user_id, type, event_id)
      select user_id, v_push_type, v_event.id from recipients
      returning 1
    )
    select count(*) into v_sent from enqueued;
  else
    with recipients as (
      select distinct ep.user_id
      from public.event_participants ep
      where ep.event_id = v_event.id
        and ep.user_id is not null
        and ep.user_id <> v_uid
    ),
    enqueued as (
      insert into public.push_outbox (user_id, type, event_id)
      select user_id, v_push_type, v_event.id from recipients
      returning 1
    )
    select count(*) into v_sent from enqueued;
  end if;

  -- No recipients is not a failure, but it must not start a cooldown either:
  -- the organizer should be free to try again once someone joins.
  if v_sent = 0 then
    return json_build_object('status', 'no_recipients');
  end if;

  if p_kind = 'register' then
    update public.events set register_reminder_sent_at = now() where id = v_event.id;
  else
    update public.events set payment_reminder_sent_at = now() where id = v_event.id;
  end if;

  return json_build_object(
    'status', 'sent',
    'recipients', v_sent,
    'next_allowed_at', now() + v_cooldown
  );
end;
$$;

revoke execute on function public.remind_event_members(uuid, text) from public, anon;
grant execute on function public.remind_event_members(uuid, text) to authenticated;

notify pgrst, 'reload schema';
