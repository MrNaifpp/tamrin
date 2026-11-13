-- Thoughts on the lineup, «خواطر التشكيلة».
--
-- Once the split is out, each player may leave one short thought on it, the
-- way a note sits over a face in Instagram. Anyone in the exercise reacts to
-- a thought with one emoji, the way a WhatsApp message takes one reaction per
-- person, or answers it in a line. Everyone also says what they make of the
-- split as a whole: balanced, fire, or unfair.
--
-- Who takes part is exactly who may read the published lineup: the organizer,
-- and every account holding a seat. A draft has no thoughts.
--
-- A thought is about tonight. It stops being shown, and stops taking
-- reactions, a day after the exercise ends. Verdict counts stay readable.
--
-- All four tables are RPC only: RLS on with no policies, no grants.

create table if not exists public.lineup_thoughts (
  event_id   uuid not null references public.events(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 60),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create table if not exists public.lineup_thought_reactions (
  event_id   uuid not null,
  author_id  uuid not null,
  reactor_id uuid not null references auth.users(id) on delete cascade,
  emoji      text not null check (emoji in ('👍', '😂', '🔥', '💪', '😤', '❤️')),
  created_at timestamptz not null default now(),
  primary key (event_id, author_id, reactor_id),
  foreign key (event_id, author_id)
    references public.lineup_thoughts(event_id, user_id) on delete cascade
);

create table if not exists public.lineup_thought_replies (
  id         uuid primary key default gen_random_uuid(),
  event_id   uuid not null,
  author_id  uuid not null,
  replier_id uuid not null references auth.users(id) on delete cascade,
  body       text not null check (char_length(btrim(body)) between 1 and 60),
  created_at timestamptz not null default now(),
  foreign key (event_id, author_id)
    references public.lineup_thoughts(event_id, user_id) on delete cascade
);

create index if not exists idx_lineup_thought_replies_thought
  on public.lineup_thought_replies(event_id, author_id, created_at);

create table if not exists public.lineup_verdicts (
  event_id   uuid not null references public.events(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  verdict    text not null check (verdict in ('balanced', 'fire', 'unfair')),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

alter table public.lineup_thoughts enable row level security;
alter table public.lineup_thought_reactions enable row level security;
alter table public.lineup_thought_replies enable row level security;
alter table public.lineup_verdicts enable row level security;
revoke all on table public.lineup_thoughts from public, anon, authenticated;
revoke all on table public.lineup_thought_reactions from public, anon, authenticated;
revoke all on table public.lineup_thought_replies from public, anon, authenticated;
revoke all on table public.lineup_verdicts from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- The same line get_event_lineup draws: the organizer, or a seat holder once
-- the lineup is published. Here a draft does not count even for the
-- organizer, since nobody else could answer him.
-- --------------------------------------------------------------------------
create or replace function public.can_join_lineup_talk(p_event_id uuid, p_uid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.events e
    join public.event_lineups l on l.event_id = e.id and l.status = 'published'
    where e.id = p_event_id
      and (
        public.is_workspace_owner(e.workspace_id, p_uid)
        or exists (
          select 1 from public.event_participants p
          where p.event_id = e.id and p.user_id = p_uid
        )
      )
  )
$$;

-- Thoughts are about tonight: open until a day after the exercise ends.
create or replace function public.lineup_talk_is_open(p_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select now() < coalesce(e.end_date, e.start_date) + interval '1 day'
    from public.events e
    where e.id = p_event_id
  ), false)
$$;

revoke execute on function public.can_join_lineup_talk(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.lineup_talk_is_open(uuid) from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Reading. Null when the caller may not take part, so the app shows nothing
-- rather than an error.
-- --------------------------------------------------------------------------
create or replace function public.get_lineup_talk(p_event_id uuid)
returns json
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_open boolean;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  if not public.can_join_lineup_talk(p_event_id, v_uid) then return null; end if;

  v_open := public.lineup_talk_is_open(p_event_id);

  return json_build_object(
    'is_open', v_open,
    'thoughts', case when not v_open then '[]'::json else (
      select coalesce(json_agg(json_build_object(
        'user_id', t.user_id,
        'name', coalesce(nullif(btrim(u.name), ''), 'لاعب'),
        'body', t.body,
        'updated_at', t.updated_at,
        'reactions', (
          select coalesce(json_agg(json_build_object(
            'user_id', r.reactor_id,
            'name', coalesce(nullif(btrim(ru.name), ''), 'لاعب'),
            'emoji', r.emoji
          ) order by r.created_at), '[]'::json)
          from public.lineup_thought_reactions r
          left join public.users ru on ru.user_id = r.reactor_id
          where r.event_id = t.event_id and r.author_id = t.user_id
        ),
        'replies', (
          select coalesce(json_agg(json_build_object(
            'id', rp.id,
            'user_id', rp.replier_id,
            'name', coalesce(nullif(btrim(pu.name), ''), 'لاعب'),
            'body', rp.body,
            'created_at', rp.created_at
          ) order by rp.created_at), '[]'::json)
          from public.lineup_thought_replies rp
          left join public.users pu on pu.user_id = rp.replier_id
          where rp.event_id = t.event_id and rp.author_id = t.user_id
        )
      ) order by t.updated_at desc), '[]'::json)
      from public.lineup_thoughts t
      left join public.users u on u.user_id = t.user_id
      where t.event_id = p_event_id
    ) end,
    'verdicts', json_build_object(
      'balanced', (select count(*) from public.lineup_verdicts where event_id = p_event_id and verdict = 'balanced'),
      'fire', (select count(*) from public.lineup_verdicts where event_id = p_event_id and verdict = 'fire'),
      'unfair', (select count(*) from public.lineup_verdicts where event_id = p_event_id and verdict = 'unfair')
    ),
    'my_verdict', (
      select verdict from public.lineup_verdicts
      where event_id = p_event_id and user_id = v_uid
    )
  );
end;
$$;

-- Shared guard for every write: allowed in, and the conversation still open.
create or replace function public.require_lineup_talk(p_event_id uuid, p_uid uuid)
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_uid is null then raise exception 'Not authenticated'; end if;
  if not public.can_join_lineup_talk(p_event_id, p_uid) then
    raise exception 'Only players in this exercise can join the lineup talk';
  end if;
  if not public.lineup_talk_is_open(p_event_id) then
    raise exception 'The lineup talk has closed';
  end if;
end;
$$;

revoke execute on function public.require_lineup_talk(uuid, uuid) from public, anon, authenticated;

-- A burst of reactions is one notification, not ten: one per kind per
-- thought every ten minutes.
create or replace function public.notify_lineup_thought_author(
  p_event_id uuid, p_author_id uuid, p_actor_id uuid, p_type text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_author_id = p_actor_id then return; end if;
  if exists (
    select 1 from public.push_outbox
    where user_id = p_author_id and event_id = p_event_id and type = p_type
      and created_at > now() - interval '10 minutes'
  ) then
    return;
  end if;
  insert into public.push_outbox (user_id, type, event_id)
  values (p_author_id, p_type, p_event_id);
end;
$$;

revoke execute on function public.notify_lineup_thought_author(uuid, uuid, uuid, text)
  from public, anon, authenticated;

-- --------------------------------------------------------------------------
-- Writing.
-- --------------------------------------------------------------------------

-- Empty or null takes the thought down. A new text is a new thought: the
-- reactions and replies were to the old one, so they go with it.
create or replace function public.set_lineup_thought(p_event_id uuid, p_body text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
  v_previous text;
begin
  perform public.require_lineup_talk(p_event_id, v_uid);

  if v_body = '' then
    delete from public.lineup_thoughts where event_id = p_event_id and user_id = v_uid;
    return public.get_lineup_talk(p_event_id);
  end if;
  if char_length(v_body) > 60 then
    raise exception 'A thought is at most 60 characters';
  end if;

  select body into v_previous
  from public.lineup_thoughts
  where event_id = p_event_id and user_id = v_uid;

  if v_previous is null then
    insert into public.lineup_thoughts (event_id, user_id, body)
    values (p_event_id, v_uid, v_body);
  elsif v_previous is distinct from v_body then
    delete from public.lineup_thought_reactions where event_id = p_event_id and author_id = v_uid;
    delete from public.lineup_thought_replies where event_id = p_event_id and author_id = v_uid;
    update public.lineup_thoughts
    set body = v_body, updated_at = now()
    where event_id = p_event_id and user_id = v_uid;
  end if;

  return public.get_lineup_talk(p_event_id);
end;
$$;

-- One reaction per person per thought; null takes it back.
create or replace function public.react_to_lineup_thought(
  p_event_id uuid, p_author_id uuid, p_emoji text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  perform public.require_lineup_talk(p_event_id, v_uid);

  if not exists (
    select 1 from public.lineup_thoughts where event_id = p_event_id and user_id = p_author_id
  ) then
    raise exception 'That thought is no longer there';
  end if;

  if p_emoji is null or btrim(p_emoji) = '' then
    delete from public.lineup_thought_reactions
    where event_id = p_event_id and author_id = p_author_id and reactor_id = v_uid;
  else
    insert into public.lineup_thought_reactions (event_id, author_id, reactor_id, emoji)
    values (p_event_id, p_author_id, v_uid, p_emoji)
    on conflict (event_id, author_id, reactor_id)
      do update set emoji = excluded.emoji, created_at = now();
    perform public.notify_lineup_thought_author(
      p_event_id, p_author_id, v_uid, 'lineup_thought_reacted');
  end if;

  return public.get_lineup_talk(p_event_id);
end;
$$;

create or replace function public.reply_to_lineup_thought(
  p_event_id uuid, p_author_id uuid, p_body text
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_body text := btrim(coalesce(p_body, ''));
begin
  perform public.require_lineup_talk(p_event_id, v_uid);

  if v_body = '' then raise exception 'A reply cannot be empty'; end if;
  if char_length(v_body) > 60 then raise exception 'A reply is at most 60 characters'; end if;
  if not exists (
    select 1 from public.lineup_thoughts where event_id = p_event_id and user_id = p_author_id
  ) then
    raise exception 'That thought is no longer there';
  end if;

  insert into public.lineup_thought_replies (event_id, author_id, replier_id, body)
  values (p_event_id, p_author_id, v_uid, v_body);
  perform public.notify_lineup_thought_author(
    p_event_id, p_author_id, v_uid, 'lineup_thought_replied');

  return public.get_lineup_talk(p_event_id);
end;
$$;

-- Your own reply, or any reply under your own thought.
create or replace function public.delete_lineup_thought_reply(p_reply_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_reply public.lineup_thought_replies;
begin
  if v_uid is null then raise exception 'Not authenticated'; end if;
  select * into v_reply from public.lineup_thought_replies where id = p_reply_id;
  if v_reply.id is null then raise exception 'That reply is no longer there'; end if;
  if v_reply.replier_id <> v_uid and v_reply.author_id <> v_uid then
    raise exception 'Only the writer or the thought''s author can remove a reply';
  end if;
  delete from public.lineup_thought_replies where id = p_reply_id;
  return public.get_lineup_talk(v_reply.event_id);
end;
$$;

-- What you make of the split as a whole; null takes it back.
create or replace function public.set_lineup_verdict(p_event_id uuid, p_verdict text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
begin
  perform public.require_lineup_talk(p_event_id, v_uid);

  if p_verdict is null or btrim(p_verdict) = '' then
    delete from public.lineup_verdicts where event_id = p_event_id and user_id = v_uid;
  else
    insert into public.lineup_verdicts (event_id, user_id, verdict)
    values (p_event_id, v_uid, p_verdict)
    on conflict (event_id, user_id)
      do update set verdict = excluded.verdict, updated_at = now();
  end if;

  return public.get_lineup_talk(p_event_id);
end;
$$;

revoke execute on function public.get_lineup_talk(uuid) from public, anon;
grant execute on function public.get_lineup_talk(uuid) to authenticated;
revoke execute on function public.set_lineup_thought(uuid, text) from public, anon;
grant execute on function public.set_lineup_thought(uuid, text) to authenticated;
revoke execute on function public.react_to_lineup_thought(uuid, uuid, text) from public, anon;
grant execute on function public.react_to_lineup_thought(uuid, uuid, text) to authenticated;
revoke execute on function public.reply_to_lineup_thought(uuid, uuid, text) from public, anon;
grant execute on function public.reply_to_lineup_thought(uuid, uuid, text) to authenticated;
revoke execute on function public.delete_lineup_thought_reply(uuid) from public, anon;
grant execute on function public.delete_lineup_thought_reply(uuid) to authenticated;
revoke execute on function public.set_lineup_verdict(uuid, text) from public, anon;
grant execute on function public.set_lineup_verdict(uuid, text) to authenticated;

notify pgrst, 'reload schema';
