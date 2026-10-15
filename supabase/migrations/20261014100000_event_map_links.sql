-- The map link an organizer pastes for a custom venue.
--
-- The Hudhud app opens only its own place links (l.hudhud.sa/p/<id>); a pin
-- sent as coordinates lands on its "update the app" screen. A venue pasted
-- from Hudhud is the only way to hand it a place it understands, so the link
-- the create flow already asks for is now kept instead of thrown away.
--
-- Its own table rather than another column on events and event_templates:
-- those columns are copied by every create, edit and recurrence function, and
-- the link is only ever read when someone taps directions. A series keeps one
-- link on its template, so every occurrence it rolls out shares it; a one-off
-- workout keeps it on the event.

create table if not exists public.event_map_links (
  id uuid primary key default gen_random_uuid(),
  template_id uuid unique references public.event_templates(id) on delete cascade,
  event_id uuid unique references public.events(id) on delete cascade,
  url text not null,
  updated_at timestamptz not null default now(),
  constraint event_map_links_one_owner check ((template_id is null) <> (event_id is null)),
  constraint event_map_links_url check (url ~ '^https://\S+$' and length(url) <= 500)
);

-- No policies: the two functions below are the only way in.
alter table public.event_map_links enable row level security;

-- Saves, replaces or (with an empty url) removes the link. Workspace owner only.
create or replace function public.set_event_map_link(p_event_id uuid, p_url text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
  v_url text := nullif(trim(p_url), '');
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then raise exception 'Event not found'; end if;
  if not public.is_workspace_owner(v_event.workspace_id, v_uid) then
    raise exception 'Only the workspace owner can change the map link';
  end if;
  if v_url is not null and (v_url !~ '^https://\S+$' or length(v_url) > 500) then
    raise exception 'رابط الخريطة غير صحيح';
  end if;

  if v_event.template_id is not null then
    delete from public.event_map_links where template_id = v_event.template_id;
    if v_url is not null then
      insert into public.event_map_links (template_id, url) values (v_event.template_id, v_url);
    end if;
  else
    delete from public.event_map_links where event_id = v_event.id;
    if v_url is not null then
      insert into public.event_map_links (event_id, url) values (v_event.id, v_url);
    end if;
  end if;
end;
$$;

-- The link for a workout, its own or its series'. Members only; null when none.
create or replace function public.get_event_map_link(p_event_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;

  select * into v_event from public.events where id = p_event_id;
  if v_event.id is null then return null; end if;
  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a member of this workspace';
  end if;

  return (
    select l.url
    from public.event_map_links l
    where l.event_id = v_event.id
       or (v_event.template_id is not null and l.template_id = v_event.template_id)
    order by (l.event_id is not null) desc
    limit 1
  );
end;
$$;

revoke execute on function public.set_event_map_link(uuid, text) from public, anon;
revoke execute on function public.get_event_map_link(uuid) from public, anon;
grant execute on function public.set_event_map_link(uuid, text) to authenticated;
grant execute on function public.get_event_map_link(uuid) to authenticated;

notify pgrst, 'reload schema';
