-- Reworks account deletion from a hard delete into a tombstone.
--
-- 20260729110000_delete_account_rpc.sql deleted the auth.users row. That erased
-- the person correctly but took the event history with them: events.creator_id
-- and event_participants.user_id both cascade, so removing an organiser
-- destroyed the events other members had joined and paid for, along with their
-- payment_status and paid_price_per_person. That record is jointly the other
-- members' — it is not the departing user's alone to erase.
--
-- So: erase the person, keep the record. Everything identifying goes, and one
-- anonymous public.users row stays behind as the anchor the event rows hang off.
--
-- This is still a deletion rather than a deactivation, which is what App Review
-- guideline 5.1.1(v) requires: sign-in is blocked, the password is cleared and
-- the identities are unlinked, so signing in again with the same Apple ID
-- creates a genuinely new account instead of resurrecting this one.
--
-- No RPC needs rewriting to display it. get_workspace, get_event_participants
-- and get_event_member_responses all read users.name already, so a tombstone
-- surfaces as عضو محذوف everywhere on its own.
--
-- The function keeps its name and signature so the app's existing call site and
-- its OWNS_SHARED_WORKSPACE handling are unaffected.

alter table public.users
  add column if not exists deleted_at timestamptz;

comment on column public.users.deleted_at is
  'Set when the user deletes their account. The row is kept, stripped of personal data, so event and payment history survives.';

create or replace function public.delete_account()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_shared_workspaces int;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  -- Still required, and for a new reason. Under the old hard delete an owner's
  -- group was cascaded away; now nothing cascades, so the group would simply sit
  -- there owned by someone who can never sign in again — unmanageable rather
  -- than destroyed. Either way the owner has to deal with it first.
  select count(*) into v_shared_workspaces
  from public.workspaces w
  where w.owner_id = v_uid
    and exists (
      select 1 from public.workspace_members m
      where m.workspace_id = w.id and m.user_id <> v_uid
    );

  if v_shared_workspaces > 0 then
    raise exception 'OWNS_SHARED_WORKSPACE'
      using hint = 'Delete or hand over the groups you own before deleting the account';
  end if;

  -- 1. Strip the profile but keep the row. `name` is what every roster reads,
  --    so this is what turns them into عضو محذوف across the app.
  update public.users
  set name = 'عضو محذوف',
      postion = '',
      avatar_url = null,
      stc_pay_number = null,
      deleted_at = now()
  where user_id = v_uid;

  -- 2. Stop anything still addressed to them. Unsent only: a row already sent is
  --    part of the delivery record, and nothing personal is left in it.
  delete from public.device_tokens where user_id = v_uid;
  delete from public.push_outbox where user_id = v_uid and sent_at is null;

  -- 3. Leave the groups, so member counts and rosters drop them. Their
  --    event_participants rows stay — that is the attendance and payment history.
  delete from public.workspace_members where user_id = v_uid;

  -- 4. Close off sign-in. Deleting the identities is the part that makes this a
  --    deletion: without them a later Apple sign-in mints a new auth user rather
  --    than landing back on this tombstone.
  delete from auth.sessions where user_id = v_uid;
  -- auth.refresh_tokens.user_id is varchar in GoTrue, not uuid; compare as text
  -- so this works regardless of which type the running version uses.
  delete from auth.refresh_tokens where user_id::text = v_uid::text;
  delete from auth.identities where user_id = v_uid;

  -- raw_user_meta_data is where Supabase parks the provider's name, email and
  -- avatar, so it has to be emptied too or the personal data is still sitting
  -- there. banned_until blocks GoTrue from issuing a session at all.
  update auth.users
  set email = 'deleted+' || v_uid::text || '@deleted.invalid',
      phone = null,
      encrypted_password = null,
      raw_user_meta_data = '{}'::jsonb,
      banned_until = '9999-12-31'::timestamptz
  where id = v_uid;

  return json_build_object('status', 'deleted');
end;
$$;

grant execute on function public.delete_account() to authenticated;
