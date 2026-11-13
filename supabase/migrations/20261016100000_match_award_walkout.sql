-- Man of the match, second pass:
--   * The poll lasts one hour, and closes early once every voter has voted.
--   * One winner. A tie goes to the player who reached the top count first.
--   * The organizer tags each nominee with a home region for the walkout map.
--   * After the result, the team cheers the winner: one emoji and a short note each.

alter table public.match_award_polls
  alter column closes_at set default now() + interval '1 hour',
  add column winner_participant_id uuid;

alter table public.match_award_candidates
  add column region_id text check (region_id in (
    'sa-01','sa-02','sa-03','sa-04','sa-05','sa-06','sa-07',
    'sa-08','sa-09','sa-10','sa-11','sa-12','sa-14'));

create table public.match_award_cheers (
  event_id uuid not null references public.match_award_polls(event_id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  emoji text check (emoji in ('👏','🔥','🐐','💪','😂','❤️')),
  note text check (char_length(note) between 1 and 60),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id),
  check (emoji is not null or note is not null)
);
alter table public.match_award_cheers enable row level security;
revoke all on public.match_award_cheers from public, anon, authenticated;

drop index public.match_award_push_once;
create unique index match_award_push_once on public.push_outbox(event_id, type, user_id)
  where type in ('match_award_nominate', 'match_award_vote', 'match_award_result', 'match_award_won');

-- Most votes wins. On a tie, the nominee whose current ballots were all in
-- first wins: their latest ballot is the moment they reached the top count.
create or replace function public.match_award_winner(p_event_id uuid)
returns uuid language sql stable security definer set search_path = public as $$
  select v.participant_id
  from public.match_award_votes v
  join public.match_award_candidates c
    on c.event_id = v.event_id and c.participant_id = v.participant_id
  where v.event_id = p_event_id
  group by v.participant_id, c.ordinal
  order by count(*) desc, max(v.updated_at), c.ordinal
  limit 1
$$;

-- Runs once per poll, from the last ballot or from cron, whichever is first.
create or replace function public.announce_match_award(p_event_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare
  p public.match_award_polls;
  winner_user uuid;
begin
  select * into p from public.match_award_polls where event_id = p_event_id for update;
  if p.event_id is null or p.result_announced_at is not null or p.closes_at > now() then
    return;
  end if;
  p.winner_participant_id := public.match_award_winner(p_event_id);
  update public.match_award_polls
    set winner_participant_id = p.winner_participant_id, result_announced_at = now()
    where event_id = p_event_id;
  select user_id into winner_user from public.match_award_candidates
    where event_id = p_event_id and participant_id = p.winner_participant_id;
  if winner_user is not null then
    insert into public.push_outbox(user_id, type, event_id)
      values (winner_user, 'match_award_won', p_event_id)
      on conflict do nothing;
  end if;
  insert into public.push_outbox(user_id, type, event_id)
    select v.user_id, 'match_award_result', p_event_id from public.match_award_voters v
    join public.events e on e.id = v.event_id
    where v.event_id = p_event_id and e.cancelled_at is null
      and v.user_id is distinct from winner_user
      and public.is_workspace_member(e.workspace_id, v.user_id)
    on conflict do nothing;
end $$;

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
  voters integer;
  winner uuid;
  cheers jsonb;
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
  select count(*) into voters from public.match_award_voters where event_id=e.id;
  if closed then
    winner := coalesce(p.winner_participant_id, public.match_award_winner(e.id));
    select coalesce(jsonb_agg(jsonb_build_object(
      'userId', ch.user_id, 'name', coalesce(u.name, 'لاعب'), 'avatarURL', u.avatar_url,
      'emoji', ch.emoji, 'note', ch.note, 'updatedAt', ch.updated_at
    ) order by ch.updated_at desc), '[]'::jsonb) into cheers
    from public.match_award_cheers ch
    left join public.users u on u.user_id = ch.user_id
    where ch.event_id = e.id;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', c.participant_id, 'userId', c.user_id, 'name', c.name, 'position', c.position,
    'portraitURL', c.portrait_url, 'avatarURL', c.avatar_url, 'regionId', c.region_id,
    'votes', case when closed then (select count(*) from public.match_award_votes v
      where v.event_id=e.id and v.participant_id=c.participant_id) else null end
  ) order by c.ordinal), '[]'::jsonb) into players
  from public.match_award_candidates c where c.event_id=e.id;
  return jsonb_build_object('eventId',e.id, 'title',e.name,
    'status',case when closed then 'closed' else 'open' end,
    'canNominate',false, 'canVote',eligible and not closed, 'players',players,
    'closesAt',p.closes_at, 'totalVotes',case when closed then total else null end,
    -- How many have voted is not who they voted for; the bar fills as ballots arrive.
    'votedCount', total, 'voterCount', voters,
    'myVoteId',(select participant_id from public.match_award_votes where event_id=e.id and user_id=uid),
    'winnerId', winner,
    'canCheer', closed and winner is not null and p.closes_at > now() - interval '3 days',
    'cheers', coalesce(cheers, '[]'::jsonb),
    'myCheer', (select jsonb_build_object('emoji', emoji, 'note', note)
      from public.match_award_cheers where event_id=e.id and user_id=uid));
end $$;

drop function public.nominate_match_award(uuid, uuid[]);
create or replace function public.nominate_match_award(
  p_event_id uuid, p_participant_ids uuid[], p_region_ids text[] default null
)
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
  if p_region_ids is not null and cardinality(p_region_ids) <> 3 then
    raise exception 'Give one region per nominee';
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
  insert into public.match_award_candidates(event_id,participant_id,user_id,name,position,portrait_url,avatar_url,region_id,ordinal)
    select e.id,ep.id,ep.user_id,coalesce(u.name,ep.guest_name,'لاعب'),coalesce(u.postion,''),
      u.player_card_url,u.avatar_url,nullif(p_region_ids[ids.n],''),ids.n
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
  -- clock_timestamp, not now(): the tie-break orders ballots, even within one transaction.
  insert into public.match_award_votes(event_id,user_id,participant_id,updated_at)
    values(e.id,uid,p_participant_id,clock_timestamp())
    on conflict(event_id,user_id) do update set participant_id=excluded.participant_id,updated_at=clock_timestamp();
  -- The last ballot closes the poll; nobody waits out the hour for nothing.
  if (select count(*) from public.match_award_votes where event_id=e.id)
    >= (select count(*) from public.match_award_voters where event_id=e.id) then
    update public.match_award_polls set closes_at=now() where event_id=e.id;
    perform public.announce_match_award(e.id);
  end if;
  return public.get_match_award(e.id);
end $$;

-- Null emoji and empty note takes the cheer down.
create or replace function public.cheer_match_award(p_event_id uuid, p_emoji text, p_note text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  e public.events;
  uid uuid := auth.uid();
  p public.match_award_polls;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  winner_user uuid;
begin
  if uid is null then raise exception 'Not authenticated'; end if;
  select * into e from public.events where id=p_event_id;
  if e.id is null or not public.is_workspace_member(e.workspace_id,uid) then raise exception 'Not a workspace member'; end if;
  select * into p from public.match_award_polls where event_id=e.id;
  if e.cancelled_at is not null or p.event_id is null or p.closes_at > now()
    or p.closes_at < now() - interval '3 days'
    or coalesce(p.winner_participant_id, public.match_award_winner(e.id)) is null then
    raise exception 'Cheering is closed';
  end if;
  if char_length(v_note) > 60 then raise exception 'A cheer is at most 60 characters'; end if;
  if p_emoji is null and v_note is null then
    delete from public.match_award_cheers where event_id=e.id and user_id=uid;
    return public.get_match_award(e.id);
  end if;
  insert into public.match_award_cheers(event_id,user_id,emoji,note)
    values(e.id,uid,p_emoji,v_note)
    on conflict(event_id,user_id) do update
      set emoji=excluded.emoji, note=excluded.note, updated_at=now();
  -- A burst of cheers is one notification every ten minutes.
  select user_id into winner_user from public.match_award_candidates
    where event_id=e.id and participant_id=coalesce(p.winner_participant_id, public.match_award_winner(e.id));
  if winner_user is not null and winner_user <> uid and not exists(
    select 1 from public.push_outbox where user_id=winner_user and event_id=e.id
      and type='match_award_cheered' and created_at > now() - interval '10 minutes') then
    insert into public.push_outbox(user_id,type,event_id) values(winner_user,'match_award_cheered',e.id);
  end if;
  return public.get_match_award(e.id);
end $$;

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
  for poll in select event_id from public.match_award_polls
    where closes_at <= now() and result_announced_at is null for update skip locked
  loop
    perform public.announce_match_award(poll.event_id);
  end loop;
end $$;

revoke all on function public.match_award_winner(uuid), public.announce_match_award(uuid),
  public.nominate_match_award(uuid,uuid[],text[]), public.cheer_match_award(uuid,text,text)
  from public, anon, authenticated;
grant execute on function public.nominate_match_award(uuid,uuid[],text[]),
  public.cheer_match_award(uuid,text,text) to authenticated;
notify pgrst, 'reload schema';
