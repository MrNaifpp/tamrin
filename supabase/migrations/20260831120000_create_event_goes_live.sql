-- An exercise is live the moment it is made.
--
-- create_event used to leave both the event and its template unpublished, so a
-- newly composed exercise was visible to nobody but its organizer until they
-- published it. In the builds in the field there is no way to publish: the
-- poster card's action bar was dropped in cf5ae1e while the actions themselves
-- were still being computed and handed to it, and the publish sheet's only
-- trigger lived inside that undrawn list. Every exercise created in those
-- builds is therefore invisible to its own group, permanently.
--
-- Rather than restore the button, the draft state goes. Creation stamps both
-- rows live and invites the workspace on the way out, through the same path
-- the weekly rollover uses, so there is one definition of what it means to let
-- a group know — advisory lock, push de-duplication and all.
--
-- Everything else in the function is unchanged and reissued verbatim.

CREATE OR REPLACE FUNCTION public.create_event(p_creator_id uuid, p_workspace_id uuid, p_name text, p_location text DEFAULT ''::text, p_description text DEFAULT ''::text, p_start_date timestamp with time zone DEFAULT now(), p_end_date timestamp with time zone DEFAULT NULL::timestamp with time zone, p_image_url text DEFAULT NULL::text, p_max_participants integer DEFAULT NULL::integer, p_total_price integer DEFAULT 0, p_price_per_person numeric DEFAULT 0, p_latitude double precision DEFAULT NULL::double precision, p_longitude double precision DEFAULT NULL::double precision, p_recurrence text DEFAULT 'none'::text, p_payment_method_id uuid DEFAULT NULL::uuid, p_payment_method_ids uuid[] DEFAULT NULL::uuid[], p_capacity_policy text DEFAULT 'waitlist'::text)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
  if p_capacity_policy not in ('waitlist', 'closed') then
    raise exception 'Invalid capacity policy: %', p_capacity_policy;
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
       payment_method_ids, published_at, capacity_policy)
    values
      (p_workspace_id, v_uid, p_name, p_location, p_description, p_image_url,
       p_latitude, p_longitude, p_total_price, 0, p_max_participants,
       v_duration_minutes, 'weekly', p_start_date + interval '7 days',
       v_payment_method_ids[1], v_payment_method_ids, now(), p_capacity_policy)
    returning id into v_template_id;
  end if;

  insert into public.events
    (creator_id, workspace_id, name, location, description, start_date,
     end_date, image_url, max_participants, total_price, price_per_person,
     latitude, longitude, template_id, payment_method_id, payment_method_ids,
     published_at, capacity_policy)
  values
    (v_uid, p_workspace_id, p_name, p_location, p_description, p_start_date,
     p_end_date, p_image_url, p_max_participants, p_total_price, 0,
     p_latitude, p_longitude, v_template_id, v_payment_method_ids[1],
     v_payment_method_ids, now(), p_capacity_policy)
  returning * into v_event;

  insert into public.event_participants (event_id, user_id)
  values (v_event.id, v_uid);

  -- What publish_event used to do, done at creation instead. Reusing the
  -- rollover's path keeps one definition of inviting a workspace, including
  -- its advisory lock and its push de-duplication.
  perform public.publish_recurring_event_internal(v_event.id, v_uid);

  select * into v_event from public.events where id = v_event.id;

  return row_to_json(v_event);
end;
$function$;

-- Nothing can be unpublished, so there is nothing left to publish.
drop function if exists public.publish_event(uuid);

notify pgrst, 'reload schema';
