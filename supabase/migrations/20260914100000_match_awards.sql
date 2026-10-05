-- Man of the match: three frozen nominees, secret changeable ballots, 24h poll.
-- Registered seats are the attendance proxy; waitlist rows live elsewhere.
create table public.match_award_settings (
  singleton boolean primary key default true check (singleton),
  enabled_at timestamptz not null default now()
);
insert into public.match_award_settings default values;
create table public.match_award_polls (
  event_id uuid primary key references public.events(id) on delete cascade,
  opened_at timestamptz not null default now(),
  closes_at timestamptz not null default now() + interval '24 hours',
  result_announced_at timestamptz
);
create index match_award_pending_results on public.match_award_polls(closes_at) where result_announced_at is null;
create table public.match_award_candidates (
  event_id uuid not null references public.match_award_polls(event_id) on delete cascade,
  participant_id uuid not null,
  user_id uuid references auth.users(id) on delete set null,
  name text not null,
  position text not null default '',
  portrait_url text,
  avatar_url text,
  ordinal integer not null check (ordinal between 1 and 3),
  primary key (event_id, participant_id),
  unique (event_id, ordinal)
);
create table public.match_award_voters (
  event_id uuid not null references public.match_award_polls(event_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  primary key (event_id, user_id)
);
create table public.match_award_votes (
  event_id uuid not null,
  user_id uuid not null,
  participant_id uuid not null,
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id),
  foreign key (event_id, user_id) references public.match_award_voters on delete cascade,
  foreign key (event_id, participant_id) references public.match_award_candidates on delete cascade
);
-- No direct reads, even by the organizer: RPCs disclose only your own ballot
-- until the deadline. Private ballots never appear in a roster or push payload.
alter table public.match_award_settings enable row level security;
alter table public.match_award_polls enable row level security;
alter table public.match_award_candidates enable row level security;
alter table public.match_award_voters enable row level security;
alter table public.match_award_votes enable row level security;
revoke all on public.match_award_settings, public.match_award_polls,
  public.match_award_candidates, public.match_award_voters, public.match_award_votes
  from public, anon, authenticated;
create unique index match_award_push_once on public.push_outbox(event_id, type, user_id)
  where type in ('match_award_nominate', 'match_award_vote', 'match_award_result');

create or replace function public.get_match_award(p_event_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  p public.match_award_polls;
  uid uuid := auth.uid();
  owner boolean;
  eligible boolean;
  closed boolean;
  players jsonb;
  total integer;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into e from public.events where id = p_event_id;
  if e.id is null or not public.is_workspace_member(e.workspace_id, uid) then
    raise exception 'Not a workspace member';
  end if;
  owner := public.is_workspace_owner(e.workspace_id, uid);
  select * into p from public.match_award_polls where event_id = e.id;
  if e.cancelled_at is not null or e.published_at is null then
    return jsonb_build_object('eventId', e.id, 'title', e.name, 'status', 'unavailable',
      'canNominate', false, 'canVote', false, 'players', '[]'::jsonb);
  end if;
  if p.event_id is null then
    if coalesce(e.end_date, e.start_date) > now() - interval '5 minutes'
      or coalesce(e.end_date, e.start_date) < now() - interval '48 hours'
      or coalesce(e.end_date, e.start_date) < (select enabled_at from public.match_award_settings) then
      return jsonb_build_object('eventId', e.id, 'title', e.name, 'status', 'unavailable',
        'canNominate', false, 'canVote', false, 'players', '[]'::jsonb);
    end if;
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', ep.id, 'userId', ep.user_id, 'name', coalesce(u.name, ep.guest_name, 'لاعب'),
      'position', coalesce(u.postion, ''), 'portraitURL', u.player_card_url,
      'avatarURL', u.avatar_url) order by ep.created_at, ep.id), '[]'::jsonb)
    into players from public.event_participants ep
    left join public.users u on u.user_id = ep.user_id
    where ep.event_id = e.id and ep.payment_status in ('pending', 'confirmed');
    return jsonb_build_object('eventId', e.id, 'title', e.name, 'status', 'nomination',
      'canNominate', owner and jsonb_array_length(players) >= 3, 'canVote', false,
      'players', case when owner then players else '[]'::jsonb end);
  end if;
  closed := now() >= p.closes_at;
  eligible := exists(select 1 from public.match_award_voters where event_id=e.id and user_id=uid);
  select count(*) into total from public.match_award_votes where event_id=e.id;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.participant_id, 'userId', c.user_id, 'name', c.name, 'position', c.position,
    'portraitURL', c.portrait_url, 'avatarURL', c.avatar_url,
    'votes', case when closed then (select count(*) from public.match_award_votes v
      where v.event_id=e.id and v.participant_id=c.participant_id) else null end
  ) order by c.ordinal), '[]'::jsonb) into players
  from public.match_award_candidates c where c.event_id=e.id;
  return jsonb_build_object('eventId',e.id, 'title',e.name,
    'status',case when closed then 'closed' else 'open' end,
    'canNominate',false, 'canVote',eligible and not closed, 'players',players,
    'closesAt',p.closes_at, 'totalVotes',case when closed then total else null end,
    'myVoteId',(select participant_id from public.match_award_votes where event_id=e.id and user_id=uid));
end $$;

create or replace function public.nominate_match_award(p_event_id uuid, p_participant_ids uuid[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.events; uid uuid := auth.uid(); existing uuid[]; requested uuid[];
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  -- Serialize nominations, retries and voting against the same event.
  select * into e from public.events where id=p_event_id for update;
  if e.id is null or not public.is_workspace_owner(e.workspace_id,uid) then
    raise exception 'Only the organizer can nominate';
  end if;
  if e.cancelled_at is not null or e.published_at is null then raise exception 'Event unavailable'; end if;
  if cardinality(p_participant_ids) is distinct from 3 or
    (select count(distinct x) from unnest(p_participant_ids) x) <> 3 then
    raise exception 'Choose exactly three different players';
  end if;
  select array_agg(x order by x) into requested from unnest(p_participant_ids) x;
  select array_agg(participant_id order by participant_id) into existing
    from public.match_award_candidates where event_id=e.id;
  if existing is not null then
    if existing = requested then return public.get_match_award(e.id); end if;
    raise exception 'Nominations are already published';
  end if;
  if coalesce(e.end_date,e.start_date) > now()-interval '5 minutes'
    or coalesce(e.end_date,e.start_date) < now()-interval '48 hours'
    or coalesce(e.end_date,e.start_date) < (select enabled_at from public.match_award_settings) then
    raise exception 'Nomination window is closed';
  end if;
  if (select count(*) from public.event_participants where event_id=e.id
    and id=any(p_participant_ids) and payment_status in ('pending','confirmed')) <> 3 then
    raise exception 'Nominees must hold seats in this event';
  end if;
  insert into public.match_award_polls(event_id) values(e.id);
  insert into public.match_award_candidates(event_id,participant_id,user_id,name,position,portrait_url,avatar_url,ordinal)
    select e.id,ep.id,ep.user_id,coalesce(u.name,ep.guest_name,'لاعب'),coalesce(u.postion,''),
      u.player_card_url,u.avatar_url,ids.n
    from unnest(p_participant_ids) with ordinality ids(id,n)
    join public.event_participants ep on ep.id=ids.id
    left join public.users u on u.user_id=ep.user_id;
  insert into public.match_award_voters(event_id,user_id)
    select distinct e.id,user_id from public.event_participants
    where event_id=e.id and user_id is not null and payment_status in ('pending','confirmed');
  insert into public.push_outbox(user_id,type,event_id)
    select user_id,'match_award_vote',e.id from public.match_award_voters where event_id=e.id
    on conflict do nothing;
  return public.get_match_award(e.id);
end $$;

create or replace function public.vote_match_award(p_event_id uuid,p_participant_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare e public.events; uid uuid := auth.uid(); p public.match_award_polls;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into e from public.events where id=p_event_id for update;
  if e.id is null or not public.is_workspace_member(e.workspace_id,uid) then raise exception 'Not a workspace member'; end if;
  select * into p from public.match_award_polls where event_id=e.id;
  if e.cancelled_at is not null or e.published_at is null or p.event_id is null or clock_timestamp() >= p.closes_at then raise exception 'Voting is closed'; end if;
  if not exists(select 1 from public.match_award_voters where event_id=e.id and user_id=uid) then
    raise exception 'Only registered players can vote';
  end if;
  if not exists(select 1 from public.match_award_candidates where event_id=e.id and participant_id=p_participant_id) then
    raise exception 'Choose a nominated player';
  end if;
  -- One account, one vote. A nominee may vote too, including for themselves.
  insert into public.match_award_votes(event_id,user_id,participant_id)
    values(e.id,uid,p_participant_id)
    on conflict(event_id,user_id) do update set participant_id=excluded.participant_id,updated_at=now();
  return public.get_match_award(e.id);
end $$;

create or replace function public.get_my_match_awards()
returns jsonb language plpgsql security definer set search_path = public as $$
declare result jsonb := '[]'; item jsonb; e record;
begin
  if auth.uid() is null then raise exception 'Not authenticated'; end if;
  for e in
    select ev.id from public.events ev
    left join public.match_award_polls p on p.event_id=ev.id
    where public.is_workspace_member(ev.workspace_id,auth.uid())
      and ev.cancelled_at is null and ev.published_at is not null
      and ((p.event_id is null and public.is_workspace_owner(ev.workspace_id,auth.uid())
        and coalesce(ev.end_date,ev.start_date) between greatest(now()-interval '48 hours',
          (select enabled_at from public.match_award_settings)) and now()-interval '5 minutes')
      or (p.closes_at > now()-interval '24 hours' and
        (public.is_workspace_owner(ev.workspace_id,auth.uid()) or exists(
          select 1 from public.match_award_voters v where v.event_id=ev.id and v.user_id=auth.uid()))))
    order by coalesce(p.opened_at,ev.end_date,ev.start_date) desc limit 20
  loop
    item := public.get_match_award(e.id);
    if item->>'status' <> 'unavailable' and
      (item->>'status' <> 'nomination' or (item->>'canNominate')::boolean) then
      result := result || jsonb_build_array(item);
    end if;
  end loop;
  return result;
end $$;

-- Server clock, once a minute. Unique outbox keys make retries and concurrent
-- cron runs harmless. Rollout timestamp prevents nudging old games on deploy.
create or replace function public.enqueue_match_award_notifications()
returns void language plpgsql security definer set search_path = public as $$
declare poll record;
begin
  insert into public.push_outbox(user_id,type,event_id)
    select w.owner_id,'match_award_nominate',e.id from public.events e
    join public.workspaces w on w.id=e.workspace_id
    where e.published_at is not null and e.cancelled_at is null
      and coalesce(e.end_date,e.start_date) between greatest(now()-interval '48 hours',
        (select enabled_at from public.match_award_settings)) and now()-interval '5 minutes'
      and not exists(select 1 from public.match_award_polls where event_id=e.id)
      and not exists(select 1 from public.push_outbox where event_id=e.id and type='match_award_nominate' and user_id=w.owner_id)
      and (select count(*) from public.event_participants ep where ep.event_id=e.id
        and ep.payment_status in ('pending','confirmed')) >= 3
    on conflict do nothing;
  for poll in select * from public.match_award_polls
    where closes_at <= now() and result_announced_at is null for update skip locked
  loop
    insert into public.push_outbox(user_id,type,event_id)
      select v.user_id,'match_award_result',poll.event_id from public.match_award_voters v
      join public.events e on e.id=v.event_id
      where v.event_id=poll.event_id and e.cancelled_at is null
        and public.is_workspace_member(e.workspace_id,v.user_id)
      on conflict do nothing;
    update public.match_award_polls set result_announced_at=now() where event_id=poll.event_id;
  end loop;
end $$;
revoke all on function public.get_match_award(uuid),public.get_my_match_awards(),
  public.nominate_match_award(uuid,uuid[]),public.vote_match_award(uuid,uuid),
  public.enqueue_match_award_notifications() from public,anon,authenticated;
grant execute on function public.get_match_award(uuid),public.get_my_match_awards(),
  public.nominate_match_award(uuid,uuid[]),public.vote_match_award(uuid,uuid) to authenticated;
select cron.schedule('match-award-notifications','* * * * *',$$select public.enqueue_match_award_notifications();$$);
notify pgrst,'reload schema';
