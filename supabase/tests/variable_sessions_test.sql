-- A large permanent community with independently bookable, simultaneous dates.
begin;
create or replace function pg_temp.community_auth(uid uuid) returns void language plpgsql as $$
begin
 perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end $$;
insert into auth.users(id,email)
select ('49170000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
       'community-' || n || '@test.local' from generate_series(1,300) n;
insert into public.users(user_id,name)
select id,'عضو المجتمع' from auth.users where id::text like '49170000-%';
do $$
declare
 owner_id uuid := '49170000-0000-0000-0000-000000000001';
 player_id uuid := '49170000-0000-0000-0000-000000000002';
 another_id uuid := '49170000-0000-0000-0000-000000000003';
 ws uuid;
 first_id uuid;
 second_id uuid;
 third_id uuid;
 result json;
 feed json;
 code text;
 failed boolean;
begin
 perform pg_temp.community_auth(owner_id);
 result := public.create_workspace('مجتمع البادل'); ws := (result->>'id')::uuid;
 select invite_code into code from public.workspaces where id=ws;
 insert into public.workspace_members(workspace_id,user_id)
 select ws,id from auth.users where id::text like '49170000-%' and id<>owner_id;
 result := public.create_event(p_creator_id=>owner_id,p_workspace_id=>ws,p_name=>'مجتمع البادل',
   p_location=>'ملعب 1',p_start_date=>now()+interval '3 hours',p_end_date=>now()+interval '4 hours',p_max_participants=>8);
 first_id := (result->>'id')::uuid;
 result := public.create_event(p_creator_id=>owner_id,p_workspace_id=>ws,p_name=>'مجتمع البادل',
   p_location=>'ملعب 2',p_start_date=>now()+interval '3 hours',p_end_date=>now()+interval '4 hours',p_max_participants=>4);
 second_id := (result->>'id')::uuid;
 assert first_id <> second_id, 'Same start must allow separate dates';
 assert (select count(*)=300 from public.workspace_members where workspace_id=ws), 'One shared 300-member group';
 assert (select count(*)=299 from public.push_outbox where event_id=first_id and type='event_invited'), 'First date notifies every other member';
 assert (select count(*)=299 from public.push_outbox where event_id=second_id and type='event_invited'), 'Second date notifies every other member';
 assert (select count(*)=1 from public.event_participants where event_id=second_id), 'Members are invited, not auto-enrolled';

 perform pg_temp.community_auth(player_id);
 perform public.register_event_seat(p_event_id=>first_id);
 perform pg_temp.community_auth(another_id);
 perform public.register_event_seat(p_event_id=>second_id);
 assert (select count(*)=2 from public.event_participants where event_id=first_id), 'First roster stays independent';
 assert not exists(select 1 from public.event_participants where event_id=second_id and user_id=player_id), 'No participant copied to other date';
 assert json_array_length(public.get_workspace_events(ws))=2, 'Members see both simultaneous dates';
 failed := false;
 begin
   perform public.create_event(p_creator_id=>another_id,p_workspace_id=>ws,p_name=>'غير مسموح');
 exception when others then failed := true; end;
 assert failed, 'Only owner creates dates';

 update public.events set start_date=now()-interval '3 days',end_date=now()-interval '3 days'+interval '1 hour'
 where id in(first_id,second_id);
 assert json_array_length(public.get_workspace_events(ws))=0, 'Schedule becomes empty after all dates end';
 feed := public.get_my_feed();
 assert exists(select 1 from json_array_elements(feed->'workspaces') w where (w->>'id')::uuid=ws), 'Empty group remains in feed';
 assert (select count(*)=300 from public.workspace_members where workspace_id=ws), 'Expiry preserves every member';
 assert (select count(*)=4 from public.event_participants where event_id in(first_id,second_id)), 'Historical rosters remain';
 assert (select invite_code=code from public.workspaces where id=ws), 'Invite link survives expiry';

 perform pg_temp.community_auth(owner_id);
 result := public.create_event(p_creator_id=>owner_id,p_workspace_id=>ws,p_name=>'مجتمع البادل',
   p_start_date=>now()+interval '2 hours',p_end_date=>now()+interval '3 hours',p_max_participants=>6);
 third_id := (result->>'id')::uuid;
 assert json_array_length(public.get_workspace_events(ws))=1, 'A new date reactivates the same group';
 assert (select count(*)=300 from public.workspace_members where workspace_id=ws), 'Creating again does not copy members';
 assert (select count(*)=1 from public.event_participants where event_id=third_id), 'A fresh date has a fresh roster';
 raise notice 'PASS: simultaneous dates, 300 members, distinct rosters, notifications, ownership, expiry, reuse';
end $$;
rollback;
