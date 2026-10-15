-- Production only, in place of 20260929120000_unpaid_workout_blocks_registration.
--
-- The rule that an unpaid ended workout blocks registering is held back from
-- this release. 20261002100000_registration_settings still calls the rule's
-- helper from register_event_seat, so the helper has to exist; this one says
-- nobody owes, which keeps production's registration as it is today.
-- Applying 20260929120000 later replaces it with the real definition.
create or replace function public.unpaid_debt_event(p_workspace_id uuid, p_user_id uuid)
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select null::uuid
$$;

revoke execute on function public.unpaid_debt_event(uuid, uuid)
  from public, anon, authenticated;
