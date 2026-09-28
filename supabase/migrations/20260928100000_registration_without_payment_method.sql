-- Taking a seat must not depend on the organizer having added a payment method.
--
-- Since 20260820100000_pay_after_registering, register_event_seat and (since
-- 20260827100000) register_event_guest_batch_impl take the seat as 'pending'
-- without asking for a method; money is declared later from «دفع القطة».
--
-- The client still loads the destination before registering, and every shipped
-- build stops on status 'payment_method_required' with
-- «لم يضف المشرف وسيلة دفع لهذا الموعد بعد» — so on a paid event whose
-- organizer has no method, «سجّل التمرين» and «سجّل معك أحد» never reached the
-- server. Fixing it here reaches the App Store build without a release.
--
-- The answer now depends on why the caller is asking:
--   * get_event_guest_payment_destination is only read to register guests, so
--     it always answers 'available' (with an empty method list when there are
--     none).
--   * get_event_payment_destination is read both to register and to pay. A
--     caller who holds no seat is registering, and gets 'available'. A caller
--     who holds one (their own, or guests they added) is paying, and still
--     gets 'payment_method_required' — the pay sheet keeps its message.

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
  v_result json;
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

  v_result := public.get_event_payment_destination_lifecycle_impl(p_event_id);

  if v_result->>'status' = 'payment_method_required'
     and not exists (
       select 1
       from public.event_participants ep
       where ep.event_id = p_event_id
         and ep.payment_status in ('pending', 'confirmed')
         and (ep.user_id = v_uid
              or (ep.user_id is null and ep.added_by = v_uid))
     ) then
    return (v_result::jsonb || jsonb_build_object('status', 'available'))::json;
  end if;

  return v_result;
end;
$$;

revoke execute on function public.get_event_payment_destination(uuid)
  from public, anon;
grant execute on function public.get_event_payment_destination(uuid)
  to authenticated;

create or replace function public.get_event_guest_payment_destination(
  p_event_id uuid
)
returns json
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_method_ids uuid[];
  v_methods jsonb;
begin
  if v_uid is null then
    raise exception 'Not authenticated';
  end if;

  select * into v_event
  from public.events
  where id = p_event_id;

  if v_event.id is null then
    raise exception 'Event not found';
  end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.published_at is null
     and not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Event is not published';
  end if;

  if v_event.total_price <= 0 then
    return json_build_object(
      'status', 'free',
      'event_id', v_event.id,
      'payment_method_id', null,
      'provider', null,
      'mobile_number', null,
      'iban', null,
      'account_number', null,
      'payment_methods', '[]'::jsonb,
      'total_price', v_event.total_price,
      'price_per_person', v_event.price_per_person,
      'group_size', null
    );
  end if;

  v_method_ids := coalesce(v_event.payment_method_ids, '{}'::uuid[]);
  if cardinality(v_method_ids) = 0 and v_event.payment_method_id is not null then
    v_method_ids := array[v_event.payment_method_id];
  end if;

  -- An event with no usable method yields an empty list, not a refusal.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'payment_method_id', pm.id,
        'provider', pm.provider,
        'mobile_number', pm.mobile_number,
        'iban', pm.iban,
        'account_number', pm.account_number
      )
      order by array_position(v_method_ids, pm.id)
    ),
    '[]'::jsonb
  )
  into v_methods
  from public.workspace_payment_methods pm
  where pm.id = any(v_method_ids)
    and pm.workspace_id = v_event.workspace_id;

  return json_build_object(
    'status', 'available',
    'event_id', v_event.id,
    'payment_method_id', null,
    'provider', null,
    'mobile_number', null,
    'iban', null,
    'account_number', null,
    'payment_methods', v_methods,
    'total_price', v_event.total_price,
    'price_per_person', v_event.price_per_person,
    'group_size', null
  );
end;
$$;

revoke execute on function public.get_event_guest_payment_destination(uuid)
  from public, anon;
grant execute on function public.get_event_guest_payment_destination(uuid)
  to authenticated;
