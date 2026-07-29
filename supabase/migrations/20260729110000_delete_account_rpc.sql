-- Account deletion, called by the app's Settings sheet.
--
-- Everything the user owns hangs off auth.users with `on delete cascade`
-- (public.users, events.creator_id, event_participants, event_waitlist,
-- device_tokens, push_outbox.user_id, workspaces.owner_id, workspace_members),
-- so removing the auth row is the whole deletion. Two things need doing by
-- hand: push_outbox.event_id has no FK, and a workspace that still has other
-- members must not be dragged down with its owner.

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

  -- workspaces.owner_id cascades, so deleting an owner would silently take the
  -- group, its events and everyone else's registrations with it. Make the owner
  -- hand the group over or delete it deliberately first.
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

  -- Queued pushes: rows addressed to this user cascade, but rows about events
  -- that are about to disappear would be left pointing at nothing.
  delete from public.push_outbox
  where event_id in (select id from public.events where creator_id = v_uid);

  delete from auth.users where id = v_uid;

  return json_build_object('status', 'deleted');
end;
$$;

grant execute on function public.delete_account() to authenticated;
