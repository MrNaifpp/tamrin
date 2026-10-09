-- Reactions on a registration, the way a WhatsApp group reacts to "I'm in".
--
-- Anyone in the group answers someone's seat with one emoji. The reaction
-- belongs to the seat row, so a guest or a manually added player can be
-- cheered too; only an account holder is notified.
--
-- The server also says what was notable about each registration, so the app
-- can put the fitting emoji first: the first to register, the one who took
-- the last seat, a first exercise with this group, a return after weeks away,
-- or someone who brought company.
--
-- RPC only: RLS on with no policies, no grants.

create table if not exists public.registration_reactions (
  participant_id uuid not null references public.event_participants(id) on delete cascade,
  reactor_id     uuid not null references auth.users(id) on delete cascade,
  emoji          text not null check (emoji in
                   ('👏', '🔥', '💪', '😂', '❤️', '🥇', '🔒', '👋', '🎉', '🤝')),
  created_at     timestamptz not null default now(),
  primary key (participant_id, reactor_id)
);

alter table public.registration_reactions enable row level security;
revoke all on table public.registration_reactions from public, anon, authenticated;

-- What stands out about one seat. Most specific first.
create or replace function public.registration_context(p_participant_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_seat public.event_participants;
  v_event public.events;
  v_seated int;
  v_previous timestamptz;
begin
  select * into v_seat from public.event_participants where id = p_participant_id;
  if v_seat.id is null then return null; end if;
  select * into v_event from public.events where id = v_seat.event_id;

  select count(*) into v_seated
  from public.event_participants
  where event_id = v_seat.event_id;

  if v_event.max_participants is not null
     and v_seated >= v_event.max_participants
     and not exists (
       select 1 from public.event_participants
       where event_id = v_seat.event_id and created_at > v_seat.created_at
     ) then
    return 'last_seat';
  end if;

  if not exists (
    select 1 from public.event_participants
    where event_id = v_seat.event_id and created_at < v_seat.created_at
  ) then
    return 'first';
  end if;

  if v_seat.user_id is not null then
    select max(e.start_date) into v_previous
    from public.event_participants p
    join public.events e on e.id = p.event_id
    where p.user_id = v_seat.user_id
      and e.workspace_id = v_event.workspace_id
      and e.id <> v_event.id
      and e.start_date < v_event.start_date
      and e.cancelled_at is null;

    if v_previous is null then return 'newcomer'; end if;
    if v_previous < v_event.start_date - interval '21 days' then return 'returning'; end if;

    if exists (
      select 1 from public.event_participants g
      where g.event_id = v_seat.event_id and g.user_id is null and g.added_by = v_seat.user_id
    ) then
      return 'with_guests';
    end if;
  end if;

  return null;
end;
$$;

revoke execute on function public.registration_context(uuid) from public, anon, authenticated;

-- Every seat in the exercise with its context and reactions. Null for anyone
-- outside the group.
create or replace function public.get_registration_reactions(p_event_id uuid)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_workspace uuid;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select workspace_id into v_workspace from public.events where id = p_event_id;
  if v_workspace is null or not public.is_workspace_member(v_workspace, v_uid) then
    return null;
  end if;

  return (
    select coalesce(json_agg(json_build_object(
      'participant_id', p.id,
      'context', public.registration_context(p.id),
      'reactions', (
        select coalesce(json_agg(json_build_object(
          'user_id', r.reactor_id,
          'name', coalesce(nullif(btrim(u.name), ''), 'لاعب'),
          'emoji', r.emoji
        ) order by r.created_at), '[]'::json)
        from public.registration_reactions r
        left join public.users u on u.user_id = r.reactor_id
        where r.participant_id = p.id
      )
    ) order by p.created_at), '[]'::json)
    from public.event_participants p
    where p.event_id = p_event_id
  );
end;
$$;

-- One reaction per person per seat; null takes it back. Open from
-- registration until a day after the exercise ends.
create or replace function public.react_to_registration(p_participant_id uuid, p_emoji text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_seat public.event_participants;
  v_event public.events;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_seat from public.event_participants where id = p_participant_id;
  if v_seat.id is null then raise exception 'That registration is no longer there'; end if;
  select * into v_event from public.events where id = v_seat.event_id;

  if not public.is_workspace_member(v_event.workspace_id, v_uid) then
    raise exception 'Not a workspace member';
  end if;
  if v_event.cancelled_at is not null
     or now() >= coalesce(v_event.end_date, v_event.start_date) + interval '1 day' then
    raise exception 'Reactions on this exercise have closed';
  end if;

  if p_emoji is null or btrim(p_emoji) = '' then
    delete from public.registration_reactions
    where participant_id = p_participant_id and reactor_id = v_uid;
  else
    insert into public.registration_reactions (participant_id, reactor_id, emoji)
    values (p_participant_id, v_uid, p_emoji)
    on conflict (participant_id, reactor_id)
      do update set emoji = excluded.emoji, created_at = now();

    -- A burst of reactions is one notification: one per ten minutes.
    if v_seat.user_id is not null
       and v_seat.user_id <> v_uid
       and not exists (
         select 1 from public.push_outbox
         where user_id = v_seat.user_id and event_id = v_seat.event_id
           and type = 'registration_reacted'
           and created_at > now() - interval '10 minutes'
       ) then
      insert into public.push_outbox (user_id, type, event_id)
      values (v_seat.user_id, 'registration_reacted', v_seat.event_id);
    end if;
  end if;

  return public.get_registration_reactions(v_seat.event_id);
end;
$$;

revoke execute on function public.get_registration_reactions(uuid) from public, anon;
grant execute on function public.get_registration_reactions(uuid) to authenticated;
revoke execute on function public.react_to_registration(uuid, text) from public, anon;
grant execute on function public.react_to_registration(uuid, text) to authenticated;

notify pgrst, 'reload schema';
