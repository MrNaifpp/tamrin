-- Lineup thoughts suite. LOCAL stack only:
--   psql "postgresql://postgres:postgres@127.0.0.1:54322/postgres" -v ON_ERROR_STOP=1 -f supabase/tests/lineup_thoughts_test.sql

begin;

create or replace function pg_temp.set_auth(uid uuid) returns void
language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-0000000000a1', 'owner@talk.local'),
  ('00000000-0000-0000-0000-0000000000a2', 'player@talk.local'),
  ('00000000-0000-0000-0000-0000000000a3', 'second@talk.local'),
  ('00000000-0000-0000-0000-0000000000a4', 'outsider@talk.local');
insert into public.users (user_id, name) values
  ('00000000-0000-0000-0000-0000000000a1', 'المالك'),
  ('00000000-0000-0000-0000-0000000000a2', 'فهد'),
  ('00000000-0000-0000-0000-0000000000a3', 'خالد'),
  ('00000000-0000-0000-0000-0000000000a4', 'غريب');

-- One workspace, one exercise tomorrow, three seats, a lineup saved but not
-- yet published.
create or replace function pg_temp.fixture(out w_id uuid, out e_id uuid)
language plpgsql as $$
declare
  p1 uuid; p2 uuid; p3 uuid;
begin
  insert into public.workspaces (name, owner_id)
  values ('نادي', '00000000-0000-0000-0000-0000000000a1')
  returning id into w_id;
  insert into public.workspace_members (workspace_id, user_id) values
    (w_id, '00000000-0000-0000-0000-0000000000a1'),
    (w_id, '00000000-0000-0000-0000-0000000000a2'),
    (w_id, '00000000-0000-0000-0000-0000000000a3');
  insert into public.events (workspace_id, creator_id, name, start_date, published_at)
  values (w_id, '00000000-0000-0000-0000-0000000000a1', 'تمرين', now() + interval '1 day', now())
  returning id into e_id;
  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-0000000000a1') returning id into p1;
  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-0000000000a2') returning id into p2;
  insert into public.event_participants (event_id, user_id)
  values (e_id, '00000000-0000-0000-0000-0000000000a3') returning id into p3;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.save_event_lineup(e_id, array[p1, p2], array[p3], '{}'::jsonb);
end;
$$;

-- ============================================================
-- Section 1: nothing before publishing, and never for an outsider.
-- ============================================================
do $$
declare
  f record;
  denied boolean := false;
begin
  select * from pg_temp.fixture() into f;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  if public.get_lineup_talk(f.e_id) is not null then
    raise exception 'FAIL: a draft lineup has a conversation';
  end if;
  begin
    perform public.set_lineup_thought(f.e_id, 'قبل النشر');
  exception when others then denied := true;
  end;
  if not denied then raise exception 'FAIL: a thought was written on a draft'; end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a4');
  if public.get_lineup_talk(f.e_id) is not null then
    raise exception 'FAIL: an outsider reads the lineup talk';
  end if;
  denied := false;
  begin
    perform public.set_lineup_verdict(f.e_id, 'fire');
  exception when others then denied := true;
  end;
  if not denied then raise exception 'FAIL: an outsider gave a verdict'; end if;
end $$;

-- ============================================================
-- Section 2: one thought per player, 60 characters, editing it
-- clears what answered the old text.
-- ============================================================
do $$
declare
  f record;
  talk json;
  denied boolean := false;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  talk := public.set_lineup_thought(f.e_id, '  فريقنا أقوى  ');
  if json_array_length(talk->'thoughts') <> 1
     or talk->'thoughts'->0->>'body' <> 'فريقنا أقوى'
     or talk->'thoughts'->0->>'name' <> 'فهد' then
    raise exception 'FAIL: the thought was not stored trimmed and named: %', talk;
  end if;

  begin
    perform public.set_lineup_thought(f.e_id, repeat('ا', 61));
  exception when others then denied := true;
  end;
  if not denied then raise exception 'FAIL: a 61 character thought was accepted'; end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a3');
  perform public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', '🔥');
  talk := public.reply_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', 'نشوف');
  if json_array_length(talk->'thoughts'->0->'reactions') <> 1
     or json_array_length(talk->'thoughts'->0->'replies') <> 1 then
    raise exception 'FAIL: the reaction or the reply did not land: %', talk;
  end if;

  -- The same text again changes nothing.
  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  talk := public.set_lineup_thought(f.e_id, 'فريقنا أقوى');
  if json_array_length(talk->'thoughts'->0->'reactions') <> 1 then
    raise exception 'FAIL: saving the same text cleared its reactions';
  end if;

  -- A new text is a new thought.
  talk := public.set_lineup_thought(f.e_id, 'جاهز');
  if json_array_length(talk->'thoughts') <> 1
     or json_array_length(talk->'thoughts'->0->'reactions') <> 0
     or json_array_length(talk->'thoughts'->0->'replies') <> 0 then
    raise exception 'FAIL: editing kept what answered the old text: %', talk;
  end if;

  talk := public.set_lineup_thought(f.e_id, '');
  if json_array_length(talk->'thoughts') <> 0 then
    raise exception 'FAIL: an empty thought did not take it down';
  end if;
end $$;

-- ============================================================
-- Section 3: one reaction per person, changeable and removable;
-- pushes to the author only, one per ten minutes.
-- ============================================================
do $$
declare
  f record;
  talk json;
  pushes int;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.publish_event_lineup(f.e_id);
  delete from public.push_outbox where event_id = f.e_id;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  perform public.set_lineup_thought(f.e_id, 'أبي أكون حارس');

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a3');
  perform public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', '😂');
  talk := public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', '💪');
  if json_array_length(talk->'thoughts'->0->'reactions') <> 1
     or talk->'thoughts'->0->'reactions'->0->>'emoji' <> '💪' then
    raise exception 'FAIL: a second reaction did not replace the first: %', talk;
  end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', '🔥');

  select count(*) into pushes from public.push_outbox
  where event_id = f.e_id and type = 'lineup_thought_reacted';
  if pushes <> 1 then
    raise exception 'FAIL: three reactions in a minute made % pushes, expected 1', pushes;
  end if;
  if exists (
    select 1 from public.push_outbox
    where event_id = f.e_id and type = 'lineup_thought_reacted'
      and user_id <> '00000000-0000-0000-0000-0000000000a2'
  ) then
    raise exception 'FAIL: a reaction push went to someone other than the author';
  end if;

  -- Reacting to your own thought tells nobody.
  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  delete from public.push_outbox where event_id = f.e_id;
  perform public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', '❤️');
  if exists (select 1 from public.push_outbox where event_id = f.e_id) then
    raise exception 'FAIL: reacting to your own thought sent a push';
  end if;

  -- An emoji outside the set is refused by the table.
  begin
    perform public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', '🍕');
    raise exception 'FAIL: an unknown emoji was accepted';
  exception when check_violation then null;
  end;

  talk := public.react_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', null);
  if json_array_length(talk->'thoughts'->0->'reactions') <> 2 then
    raise exception 'FAIL: taking back a reaction left % reactions, expected 2',
      json_array_length(talk->'thoughts'->0->'reactions');
  end if;
end $$;

-- ============================================================
-- Section 4: replies are removed by their writer or the author.
-- ============================================================
do $$
declare
  f record;
  talk json;
  reply_id uuid;
  denied boolean := false;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.publish_event_lineup(f.e_id);

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  perform public.set_lineup_thought(f.e_id, 'الدفاع جدار');

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a3');
  talk := public.reply_to_lineup_thought(f.e_id, '00000000-0000-0000-0000-0000000000a2', 'نشوف في الملعب');
  reply_id := (talk->'thoughts'->0->'replies'->0->>'id')::uuid;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  begin
    perform public.delete_lineup_thought_reply(reply_id);
  exception when others then denied := true;
  end;
  if not denied then raise exception 'FAIL: a third person removed a reply'; end if;

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  talk := public.delete_lineup_thought_reply(reply_id);
  if json_array_length(talk->'thoughts'->0->'replies') <> 0 then
    raise exception 'FAIL: the author could not remove a reply under his thought';
  end if;
end $$;

-- ============================================================
-- Section 5: verdicts count once per person; thoughts close a
-- day after the exercise ends, verdict counts stay.
-- ============================================================
do $$
declare
  f record;
  talk json;
  denied boolean := false;
begin
  select * from pg_temp.fixture() into f;
  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a1');
  perform public.publish_event_lineup(f.e_id);
  perform public.set_lineup_verdict(f.e_id, 'balanced');

  perform pg_temp.set_auth('00000000-0000-0000-0000-0000000000a2');
  perform public.set_lineup_thought(f.e_id, 'جاهز');
  perform public.set_lineup_verdict(f.e_id, 'unfair');
  talk := public.set_lineup_verdict(f.e_id, 'balanced');
  if (talk->'verdicts'->>'balanced')::int <> 2
     or (talk->'verdicts'->>'unfair')::int <> 0
     or talk->>'my_verdict' <> 'balanced' then
    raise exception 'FAIL: a changed verdict was counted twice: %', talk->'verdicts';
  end if;

  update public.events
  set start_date = now() - interval '3 days', end_date = now() - interval '2 days'
  where id = f.e_id;

  talk := public.get_lineup_talk(f.e_id);
  if (talk->>'is_open')::boolean or json_array_length(talk->'thoughts') <> 0 then
    raise exception 'FAIL: thoughts are still showing two days after the exercise';
  end if;
  if (talk->'verdicts'->>'balanced')::int <> 2 then
    raise exception 'FAIL: verdict counts disappeared with the thoughts';
  end if;
  begin
    perform public.set_lineup_thought(f.e_id, 'متأخر');
  exception when others then denied := true;
  end;
  if not denied then raise exception 'FAIL: a thought was written after the talk closed'; end if;
end $$;

select 'lineup_thoughts: all sections passed' as result;

rollback;
