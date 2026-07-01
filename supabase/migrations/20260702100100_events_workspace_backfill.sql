-- Every event now belongs to a workspace. Backfills existing (test) data:
-- one personal workspace per event creator, named from users.name; all of a
-- creator's events move into it; every existing participant becomes a member.
-- One-shot backfill — assumes each creator owns no workspace yet (true on the
-- pre-workspace schema this migration upgrades).

alter table public.events
  add column workspace_id uuid references public.workspaces(id) on delete cascade;

insert into public.workspaces (name, owner_id)
select coalesce(nullif(trim(u.name), ''), 'مساحتي'), c.creator_id
from (select distinct creator_id from public.events) c
left join public.users u on u.user_id = c.creator_id;

insert into public.workspace_members (workspace_id, user_id)
select w.id, w.owner_id
from public.workspaces w
where w.owner_id in (select distinct creator_id from public.events)
on conflict do nothing;

update public.events e
set workspace_id = w.id
from public.workspaces w
where w.owner_id = e.creator_id
  and e.workspace_id is null;

-- Existing participants keep sight of their events by becoming members.
insert into public.workspace_members (workspace_id, user_id)
select e.workspace_id, ep.user_id
from public.event_participants ep
join public.events e on e.id = ep.event_id
where ep.user_id is not null
on conflict do nothing;

alter table public.events alter column workspace_id set not null;
create index idx_events_workspace_id on public.events(workspace_id);

-- Visibility is now workspace membership, not creator-or-participant.
drop policy "Users can select events they created or participate in" on public.events;
create policy "Members can select workspace events"
  on public.events for select
  using (public.is_workspace_member(workspace_id, auth.uid()));
