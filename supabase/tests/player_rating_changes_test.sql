-- Run after all migrations. No lasting users, ratings or workspaces.
begin;
create or replace function pg_temp.trend_auth(uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
end;
$$;
insert into auth.users(id, email) values
 ('39170000-0000-0000-0000-000000000001', 'trend-owner@test.local'),
 ('39170000-0000-0000-0000-000000000002', 'trend-player@test.local'),
 ('39170000-0000-0000-0000-000000000003', 'trend-member@test.local'),
 ('39170000-0000-0000-0000-000000000004', 'trend-outsider@test.local');
insert into public.users(user_id, name, postion)
select id, 'لاعب تجربة', 'وسط' from auth.users where id::text like '39170000-%';

do $$
declare
 owner_id uuid := '39170000-0000-0000-0000-000000000001';
 player_id uuid := '39170000-0000-0000-0000-000000000002';
 member_id uuid := '39170000-0000-0000-0000-000000000003';
 outsider_id uuid := '39170000-0000-0000-0000-000000000004';
 ws uuid;
 other_ws uuid;
 result json;
 before jsonb;
 stamp timestamptz;
 failed boolean;
begin
 perform pg_temp.trend_auth(owner_id);
 ws := (public.create_workspace('اختبار تغيّر التقييم')->>'id')::uuid;
 insert into public.workspace_members(workspace_id,user_id) values (ws,player_id),(ws,member_id);
 other_ws := (public.create_workspace('مجموعة مستقلة')->>'id')::uuid;
 insert into public.workspace_members(workspace_id,user_id) values(other_ws,player_id);

 result := public.submit_player_rating(ws,player_id,60::smallint,60::smallint,60::smallint,60::smallint,60::smallint,60::smallint);
 assert result#>>'{rating,trend}' is null, 'First rating must not be improvement from zero';
 result := public.submit_player_rating(ws,player_id,80::smallint,80::smallint,80::smallint,80::smallint,80::smallint,80::smallint);
 assert (result#>>'{rating,trend,delta}')::int = 20, 'Editing up must move aggregate +20';
 assert (result#>>'{rating,trend,previous_overall}')::int = 60, 'Correct previous total';
 before := (result#>'{rating,trend}')::jsonb;
 select updated_at into stamp from public.player_ratings where workspace_id=ws and ratee_id=player_id;
 result := public.submit_player_rating(ws,player_id,80::smallint,80::smallint,80::smallint,80::smallint,80::smallint,80::smallint);
 assert (result#>'{rating,trend}')::jsonb = before, 'No-op must keep meaningful trend/date';
 assert (select updated_at=stamp from public.player_ratings where workspace_id=ws and ratee_id=player_id), 'No-op must not rewrite rating';

 perform pg_temp.trend_auth(member_id);
 result := public.get_player_rating(ws,player_id);
 assert (result->'trend')::jsonb = before, 'A different member sees the same trend without rating first';
 assert result->>'mine' is null, 'Trend cannot expose another rater score';
 assert (select count(*) from jsonb_object_keys(before)) = 4, 'Trend payload exposes no rater identity';
 result := public.submit_player_rating(ws,player_id,40::smallint,40::smallint,40::smallint,40::smallint,40::smallint,40::smallint);
 assert (result#>>'{rating,average,overall}')::int = 60, 'Average of 80 and 40 is 60';
 assert (result#>>'{rating,trend,delta}')::int = -20, 'Movement is aggregate change, not individual score';
 result := public.submit_player_rating(ws,player_id,50::smallint,50::smallint,50::smallint,50::smallint,50::smallint,50::smallint);
 assert (result#>>'{rating,trend,delta}')::int = 5, 'Editing 40 to 50 moves two-person average by 5';
 before := (result#>'{rating,trend}')::jsonb;
 result := public.submit_player_rating(ws,player_id,51::smallint,50::smallint,50::smallint,50::smallint,50::smallint,50::smallint);
 assert (result#>'{rating,trend}')::jsonb = before, 'Sub-point change is not a displayed-total change';

 perform pg_temp.trend_auth(player_id);
 result := public.get_player_rating(ws,player_id);
 assert (result->'trend')::jsonb = before, 'Player sees the same anonymous change';
 result := public.submit_player_rating(ws,player_id,1::smallint,1::smallint,1::smallint,1::smallint,1::smallint,1::smallint);
 assert result->>'status' = 'is_self', 'Self-rating still rejected';

 perform pg_temp.trend_auth(owner_id);
 result := public.get_player_rating(other_ws,player_id);
 assert result->>'trend' is null, 'Changes must not leak across workspaces';
 update public.users set postion='هجوم' where user_id=player_id;
 result := public.get_player_rating(ws,player_id);
 assert result->>'trend' is null, 'Changed position cannot reuse an old weighting comparison';
 update public.users set postion='وسط' where user_id=player_id;

 perform pg_temp.trend_auth(outsider_id);
 failed := false;
 begin perform public.get_player_rating(ws,player_id); exception when others then failed := true; end;
 assert failed, 'Outsider cannot read trend';
 failed := false;
 begin perform public.submit_player_rating(ws,player_id,90::smallint,90::smallint,90::smallint,90::smallint,90::smallint,90::smallint);
 exception when others then failed := true; end;
 assert failed, 'Outsider cannot write trend';
 assert not has_table_privilege('authenticated','public.player_rating_changes','SELECT'), 'No direct trend-table access';
 assert not has_table_privilege('authenticated','public.player_rating_changes','INSERT'), 'No direct trend mutation';
 raise notice 'PASS: player rating changes — first, up/down, aggregate, no-op, rounding, viewers, scope, position, privacy';
end $$;
rollback;
