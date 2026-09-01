-- Temporarily stop refusing a seat over last week's contribution.
--
-- guard_event_registration_insert refused a seat in a recurring series while an
-- earlier occurrence of the same series had ended with the payer's row still
-- pending and undeclared.
--
-- It is lifted now, deliberately and for the moment, because of who is caught by
-- it. The builds in the field show the raw server text, so a member meets
-- "Previous event payment is required" in English, and the way to clear it is a
-- button on a finished exercise that the shelf was not even showing them until
-- 20260830180000. They cannot pay and cannot book, and no app update is needed
-- to give them their Sunday back: this is server side, so it reaches every build
-- already installed.
--
-- Only the refusal goes. The other half of the rule stays exactly as it was:
-- publish_recurring_event_internal still withholds the invitation to the next
-- occurrence from a member carrying an undeclared debt, and
-- invite_after_recurring_debt_declaration still delivers it the moment they
-- declare. The debt is still reported through requires_payment_action, still
-- holds its place on the shelf, and still offers «دفع القطة».
--
-- To restore it, reinstate the block this migration removes: the exists() over
-- the series debt, and its `raise exception 'Previous event payment is required'`.
-- The suite carries the inverted assertion, so putting the gate back will fail
-- recurring_payment_gate_test until that assertion is flipped with it.
--
-- Everything else in this trigger is unchanged, and reissued verbatim.

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

notify pgrst, 'reload schema';
