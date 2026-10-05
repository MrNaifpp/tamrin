-- Reset only a reported transfer, before or after an exercise ends.
-- Existing confirm_payment already supports ended exercises.

CREATE OR REPLACE FUNCTION public.reject_payment(p_event_id uuid, p_user_id uuid, p_creator_id uuid)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_changed_rows integer := 0;
  v_revoked_future_seats integer := 0;
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

  -- A payment decision never changes attendance, including guests and history.
  update public.event_participants
  set payment_declared_at = null
  where event_id = p_event_id
    and (user_id = p_user_id or (user_id is null and added_by = p_user_id))
    and payment_status = 'pending'
    and payment_declared_at is not null;
  get diagnostics v_changed_rows = row_count;

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
$function$;

revoke execute on function public.reject_payment(uuid, uuid, uuid) from public, anon;
grant execute on function public.reject_payment(uuid, uuid, uuid) to authenticated;

-- New clients must not fall back to a pre-migration RPC that deletes seats.
create or replace function public.reset_payment_declaration(
  p_event_id uuid, p_user_id uuid, p_creator_id uuid
) returns json
language sql security invoker set search_path = public
as $$ select public.reject_payment(p_event_id, p_user_id, p_creator_id); $$;
revoke execute on function public.reset_payment_declaration(uuid, uuid, uuid) from public, anon;
grant execute on function public.reset_payment_declaration(uuid, uuid, uuid) to authenticated;

notify pgrst, 'reload schema';
