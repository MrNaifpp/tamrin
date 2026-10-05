-- Run against a local test database with current migrations. Never production.
-- All fixtures and notifications roll back.
begin;
insert into auth.users (id,email) values
 ('99090000-0000-0000-0000-000000000001','payment-owner@test.local'),
 ('99090000-0000-0000-0000-000000000002','payment-payer@test.local'),
 ('99090000-0000-0000-0000-000000000003','payment-waiter@test.local');

do $$
declare
 owner_id constant uuid := '99090000-0000-0000-0000-000000000001';
 payer_id constant uuid := '99090000-0000-0000-0000-000000000002';
 waiter_id constant uuid := '99090000-0000-0000-0000-000000000003';
 ws uuid;
 ev uuid;
 method uuid;
 result json;
 seats_before jsonb;
 notices int;
 historical boolean;
begin
 insert into public.workspaces (name,owner_id) values ('Payment regression',owner_id) returning id into ws;
 insert into public.workspace_members (workspace_id,user_id) values (ws,owner_id),(ws,payer_id),(ws,waiter_id);
 insert into public.workspace_payment_methods (workspace_id,provider,mobile_number)
 values (ws,'stc_bank','+966500000099') returning id into method;

 foreach historical in array array[false,true] loop
  insert into public.events (creator_id,workspace_id,name,start_date,end_date,max_participants,total_price,price_per_person,published_at,payment_method_id,payment_method_ids)
  values (owner_id,ws,'Payment reset',now() + case when historical then interval '-4 hours' else interval '1 day' end,
   now() + case when historical then interval '-2 hours' else interval '1 day 2 hours' end,4,40,10,now(),method,array[method]) returning id into ev;
  insert into public.event_participants (event_id,user_id,payment_status,payment_declared_at)
  values (ev,payer_id,'pending',now());
  insert into public.event_participants (event_id,guest_name,added_by,payment_status,payment_declared_at)
  values (ev,'Pending guest',payer_id,'pending',now()),(ev,'Confirmed guest',payer_id,'confirmed',now()),
   (ev,'Undeclared guest',payer_id,'pending',null);
  insert into public.event_waitlist (event_id,user_id) values (ev,waiter_id);
  select jsonb_agg(to_jsonb(ep) - 'payment_declared_at' order by ep.id) into seats_before from public.event_participants ep where event_id=ev;
  select count(*) into notices from public.push_outbox where event_id=ev and type='payment_rejected';

  -- Members cannot reject their own or anyone else's payment, even by spoofing the creator parameter.
  perform set_config('request.jwt.claims',json_build_object('sub',payer_id,'role','authenticated')::text,true);
  begin
   perform public.reset_payment_declaration(ev,payer_id,owner_id);
   raise exception 'FAIL: unauthorized reset accepted';
  exception when others then
   if SQLERRM not like 'Not authorized%' then raise; end if;
  end;
  perform set_config('request.jwt.claims',json_build_object('sub',owner_id,'role','authenticated')::text,true);
  result := public.reset_payment_declaration(ev,payer_id,owner_id);
  if result->>'status' <> 'rejected' then raise exception 'FAIL: reset result %',result; end if;
  if (select jsonb_agg(to_jsonb(ep) - 'payment_declared_at' order by ep.id) from public.event_participants ep where event_id=ev) is distinct from seats_before then
   raise exception 'FAIL: reset changed seats or payment snapshots';
  end if;
  if exists(select 1 from public.event_participants where event_id=ev and payment_status='pending' and payment_declared_at is not null) then
   raise exception 'FAIL: payment is still declared';
  end if;
  if not exists(select 1 from public.event_waitlist where event_id=ev and user_id=waiter_id) then raise exception 'FAIL: waitlist changed'; end if;
  if (select count(*) from public.push_outbox where event_id=ev and type='payment_rejected' and user_id=payer_id) <> notices+1 then
   raise exception 'FAIL: expected one reset notification';
  end if;
  -- Legacy clients also preserve seats, and a duplicate action sends no duplicate push.
  result := public.reject_payment(ev,payer_id,owner_id);
  if result->>'status' <> 'no_pending_row' then raise exception 'FAIL: repeated reset mutated state'; end if;
  if (select count(*) from public.push_outbox where event_id=ev and type='payment_rejected') <> notices+1 then raise exception 'FAIL: duplicate push'; end if;

  -- The same participant can declare payment again, even after the exercise ended.
  perform set_config('request.jwt.claims',json_build_object('sub',payer_id,'role','authenticated')::text,true);
  result := public.declare_event_payment(ev,method);
  if result->>'status' <> 'declared' then raise exception 'FAIL: redeclaration %',result; end if;
  perform set_config('request.jwt.claims',json_build_object('sub',owner_id,'role','authenticated')::text,true);
  result := public.confirm_payment(ev,payer_id,owner_id);
  if result->>'status' <> 'confirmed' then raise exception 'FAIL: confirmation %',result; end if;
  if (select count(*) from public.event_participants where event_id=ev and payment_status='confirmed') <> 4 then raise exception 'FAIL: confirmation lost seats'; end if;
  result := public.reset_payment_declaration(ev,payer_id,owner_id);
  if result->>'status' <> 'no_pending_row' then raise exception 'FAIL: reset reversed confirmed payment'; end if;
  raise notice 'PASS: payment reset, permissions, guests, waitlist, idempotency, redeclaration and confirmation (historical=%)',historical;
 end loop;
end;
$$;
rollback;
