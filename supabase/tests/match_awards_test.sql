-- Run against a local migrated database only. Rolls back every fixture.
begin;
create or replace function pg_temp.mvp_auth(uid uuid) returns void language plpgsql as $$
begin perform set_config('request.jwt.claims',json_build_object('sub',uid,'role','authenticated')::text,true); end $$;
create or replace function pg_temp.mvp_assert(ok boolean, message text) returns void language plpgsql as $$
begin if ok is distinct from true then raise exception 'FAIL: %',message; end if; end $$;
create or replace function pg_temp.mvp_denied(statement text) returns void language plpgsql as $$
begin
  begin execute statement;
  exception when others then return;
  end;
  raise exception 'FAIL: accepted forbidden operation: %',statement;
end $$;
insert into auth.users(id,email) select ('74000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'mvp'||i||'@test.local' from generate_series(1,5) i;
insert into public.users(user_id,name) select id,'لاعب '||right(id::text,1) from auth.users where email like 'mvp%@test.local';
insert into public.workspaces(id,name,owner_id) values ('74000000-0000-0000-0001-000000000001','رجل المباراة','74000000-0000-0000-0000-000000000001');
insert into public.workspace_members(workspace_id,user_id)
select '74000000-0000-0000-0001-000000000001',('74000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid from generate_series(1,4) i;
update public.match_award_settings set enabled_at=now()-interval '1 day';
insert into public.events(id,workspace_id,creator_id,name,start_date,end_date,published_at)
values ('74000000-0000-0000-0002-000000000001','74000000-0000-0000-0001-000000000001','74000000-0000-0000-0000-000000000001','اختبار النجم',now()-interval '2 hours',now()-interval '6 minutes',now()-interval '1 day');
insert into public.event_participants(id,event_id,user_id,payment_status) values
('74000000-0000-0000-0003-000000000001','74000000-0000-0000-0002-000000000001','74000000-0000-0000-0000-000000000002','pending'),
('74000000-0000-0000-0003-000000000002','74000000-0000-0000-0002-000000000001','74000000-0000-0000-0000-000000000003','confirmed');
insert into public.event_participants(id,event_id,guest_name,added_by,payment_status) values
('74000000-0000-0000-0003-000000000003','74000000-0000-0000-0002-000000000001','ضيف','74000000-0000-0000-0000-000000000002','pending');

do $$
declare
 e uuid := '74000000-0000-0000-0002-000000000001';
 owner uuid := '74000000-0000-0000-0000-000000000001';
 player uuid := '74000000-0000-0000-0000-000000000002';
 p1 uuid := '74000000-0000-0000-0003-000000000001';
 p2 uuid := '74000000-0000-0000-0003-000000000002';
 p3 uuid := '74000000-0000-0000-0003-000000000003';
 a jsonb;
begin
 perform pg_temp.mvp_auth(owner);
 perform public.enqueue_match_award_notifications();
 perform public.enqueue_match_award_notifications();
 perform pg_temp.mvp_assert((select count(*)=1 from public.push_outbox where event_id=e and type='match_award_nominate'),'one reminder only');
 a := public.get_match_award(e);
 perform pg_temp.mvp_assert((a->>'canNominate')::boolean and jsonb_array_length(a->'players')=3,'unpaid seats and guests can be nominated');
 update public.events set end_date=now()-interval '4 minutes' where id=e;
 perform pg_temp.mvp_assert(public.get_match_award(e)->>'status'='unavailable','five minute guard');
 perform pg_temp.mvp_denied(format('select public.nominate_match_award(%L,ARRAY[%L,%L,%L]::uuid[])',e,p1,p2,p3));
 update public.events set end_date=now()-interval '6 minutes' where id=e;
 perform pg_temp.mvp_denied(format('select public.nominate_match_award(%L,ARRAY[%L,%L,%L]::uuid[])',e,p1,p1,p2));
 perform pg_temp.mvp_denied(format('select public.nominate_match_award(%L,ARRAY[%L,%L,%L]::uuid[])',e,p1,p2,gen_random_uuid()));
 perform pg_temp.mvp_auth(player);
 perform pg_temp.mvp_denied(format('select public.nominate_match_award(%L,ARRAY[%L,%L,%L]::uuid[])',e,p1,p2,p3));
 perform pg_temp.mvp_auth(owner);
 a := public.nominate_match_award(e,array[p1,p2,p3]);
 perform public.nominate_match_award(e,array[p3,p2,p1]);
 perform pg_temp.mvp_assert(a->>'status'='open','published state');
 perform pg_temp.mvp_assert((select count(*)=2 from public.push_outbox where event_id=e and type='match_award_vote'),'only account seats receive the vote push, retries do not duplicate');
 perform pg_temp.mvp_assert((select count(*)=2 from public.match_award_voters where event_id=e),'guests and non-playing organizer do not receive extra ballots');
 perform pg_temp.mvp_denied(format('select public.vote_match_award(%L,%L)',e,p1));
 perform pg_temp.mvp_auth('74000000-0000-0000-0000-000000000004');
 perform pg_temp.mvp_denied(format('select public.vote_match_award(%L,%L)',e,p1));
 perform pg_temp.mvp_auth('74000000-0000-0000-0000-000000000005');
 perform pg_temp.mvp_denied(format('select public.get_match_award(%L)',e));
 perform pg_temp.mvp_auth(player);
 perform pg_temp.mvp_denied(format('select public.vote_match_award(%L,%L)',e,gen_random_uuid()));
 a := public.vote_match_award(e,p1);
 a := public.vote_match_award(e,p2);
 perform pg_temp.mvp_assert(a->>'myVoteId'=p2::text,'changed vote survives');
 perform pg_temp.mvp_assert((select count(*)=1 from public.match_award_votes where event_id=e),'one account one ballot');
 perform pg_temp.mvp_assert(a->'totalVotes'='null'::jsonb and a->'players'->0->'votes'='null'::jsonb,'voter cannot see counts');
 perform pg_temp.mvp_auth(owner);
 a := public.get_match_award(e);
 perform pg_temp.mvp_assert(a->'totalVotes'='null'::jsonb and a->'players'->1->'votes'='null'::jsonb,'organizer cannot see counts either');
 perform pg_temp.mvp_auth('74000000-0000-0000-0000-000000000003');
 perform public.vote_match_award(e,p1);
 update public.match_award_polls set closes_at=now()-interval '1 second' where event_id=e;
 perform pg_temp.mvp_denied(format('select public.vote_match_award(%L,%L)',e,p3));
 a := public.get_match_award(e);
 perform pg_temp.mvp_assert(a->>'status'='closed' and (a->>'totalVotes')::int=2,'final counts visible at deadline');
 perform pg_temp.mvp_assert((a->'players'->0->>'votes')::int=1 and (a->'players'->1->>'votes')::int=1,'tie is preserved, not arbitrarily broken');
 perform public.enqueue_match_award_notifications();
 perform public.enqueue_match_award_notifications();
 perform pg_temp.mvp_assert((select count(*)=2 from public.push_outbox where event_id=e and type='match_award_result'),'results sent once to each voter');
 update public.events set cancelled_at=now() where id=e;
 perform pg_temp.mvp_assert(public.get_match_award(e)->>'status'='unavailable','cancelled games hide awards');
 perform pg_temp.mvp_auth(null);
 perform pg_temp.mvp_denied(format('select public.get_match_award(%L)',e));
end $$;
-- Enforce API-only access even for authenticated clients.
set local role authenticated;
do $$ begin
 perform pg_temp.mvp_denied('select * from public.match_award_votes');
 perform pg_temp.mvp_denied('select public.enqueue_match_award_notifications()');
end $$;
reset role;
rollback;
