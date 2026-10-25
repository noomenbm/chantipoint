-- Fictional, rollback-only activation tests. No production/client approval.
begin;
set local statement_timeout='30s';
set local lock_timeout='5s';
create extension if not exists pgtap with schema extensions;
select no_plan();

create temporary table activation_state as select * from private.attendance_deployment;
create temporary table activation_people as
select n,gen_random_uuid() a,gen_random_uuid() p,
 case when n=4 then c.other_company else c.first_company end c
from generate_series(1,4) n cross join
 (select gen_random_uuid() first_company,gen_random_uuid() other_company) c;
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
select a,'authenticated','authenticated','activation.'||n||'@example.test','not-a-password',statement_timestamp()
from activation_people;
insert into public.companies(id,name) select distinct c,'Fictional activation company' from activation_people;
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
select p,a,c,'Fictional activation employee','activation.'||n||'@example.test' from activation_people;
insert into public.role_assignments(user_profile_id,company_id,role)
select p,c,case when n=3 then 'administrator' else 'employee' end from activation_people;
create temporary table activation_results(label text primary key,r jsonb);
grant select on activation_state,activation_people to authenticated;
grant select,insert on activation_results to authenticated;

create function pg_temp.activation_user(p_n integer) returns void language plpgsql as $$
begin perform set_config('request.jwt.claim.sub',(select a::text from activation_people where n=p_n),true); end $$;
create function pg_temp.activation_headers(p_text text) returns void language plpgsql as $$
begin perform set_config('request.headers',p_text,true); end $$;
create function pg_temp.activation_id(p_label text) returns uuid language sql as $$
 select (r->>'session_id')::uuid from activation_results where label=p_label
$$;
create function pg_temp.activation_in(p_key text,p_replay boolean default false,p_description text default null)
returns jsonb language sql as $$
 select public.check_in_v2(p_idempotency_key=>p_key,p_site_description=>p_description,p_replay_only=>p_replay)
$$;

select is(private.attendance_write_contract(),1,'migration leaves gate 1');
select is((select count(*)::int from private.attendance_deployment),1,'exactly one server-owned deployment');
select ok((select deployment_epoch is not null from private.attendance_deployment),'server generated an epoch');
select ok((select relrowsecurity from pg_class where oid='private.attendance_deployment'::regclass),'deployment has RLS');
select ok(not has_table_privilege('authenticated','private.attendance_deployment','select,insert,update,delete')
 and not has_table_privilege('anon','private.attendance_deployment','select,insert,update,delete'),'no client deployment grants');
select ok((select provolatile='s' and prosecdef and 'search_path=""'=any(proconfig)
 from pg_proc where oid='public.attendance_capability()'::regprocedure),'capability is stable/security-definer with fixed search path');
select ok(has_function_privilege('authenticated','public.attendance_capability()','execute')
 and not has_function_privilege('anon','public.attendance_capability()','execute'),'capability authenticated-only');
select ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='private' and p.proname in ('locked_attendance_deployment','require_attendance_epoch',
 'attendance_write_contract','lock_attendance_deployment_change','update_employee_note_legacy_impl','save_employee_note_legacy_impl')
 and (has_function_privilege('authenticated',p.oid,'execute') or has_function_privilege('anon',p.oid,'execute'))),
 'all new/relocated private entry points deny API callers');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
 where n.nspname='public' and p.proname in ('check_in','check_out','check_in_v2','check_out_v2',
 'update_employee_note','save_employee_note','attendance_capability')),7,'no overload bypass');
select throws_ok($$insert into private.attendance_deployment(singleton) values(false)$$,
 '23514',null::text,'deployment singleton is constrained');
select throws_ok($$update private.attendance_deployment set write_contract=3$$,
 '23514',null::text,'invalid gate cannot be stored');

set local role authenticated;
select pg_temp.activation_user(1);
select is(public.attendance_capability(),(select jsonb_build_object('capability_version',1,
 'deployment_epoch',deployment_epoch,'write_contract',1,'v2_available',false) from activation_state),
 'capability reports real gate 1 with only four versioned fields');
select throws_ok($$select * from private.attendance_deployment$$,'42501',null::text,'employee cannot read raw deployment state');
select throws_ok($$update private.attendance_deployment set write_contract=2$$,'42501',null::text,'employee cannot change gate');
select pg_temp.activation_headers('');
select throws_ok($$select pg_temp.activation_in('activation-no-header')$$,'P0001','attendance_epoch_required','absent request metadata rejected');
select pg_temp.activation_headers('{}');
select throws_ok($$select pg_temp.activation_in('activation-no-field')$$,'P0001','attendance_epoch_required','missing epoch rejected');
select pg_temp.activation_headers('{');
select throws_ok($$select pg_temp.activation_in('activation-bad-json')$$,'P0001','attendance_epoch_invalid','malformed metadata gets safe error');
select pg_temp.activation_headers('[]');
select throws_ok($$select pg_temp.activation_in('activation-bad-object')$$,'P0001','attendance_epoch_invalid','non-object metadata rejected');
select pg_temp.activation_headers('{"x-chantipoint-attendance-epoch":null}');
select throws_ok($$select pg_temp.activation_in('activation-null-epoch')$$,'P0001','attendance_epoch_invalid','null epoch rejected');
select pg_temp.activation_headers('{"x-chantipoint-attendance-epoch":"invalid"}');
select throws_ok($$select pg_temp.activation_in('activation-invalid-epoch')$$,'P0001','attendance_epoch_invalid','noncanonical epoch rejected');
select pg_temp.activation_headers('{"x-chantipoint-attendance-epoch":17}');
select throws_ok($$select pg_temp.activation_in('activation-number-epoch')$$,'P0001','attendance_epoch_invalid','numeric epoch rejected');
select pg_temp.activation_headers('{"x-chantipoint-attendance-epoch":""}');
select throws_ok($$select pg_temp.activation_in('activation-empty-epoch')$$,'P0001','attendance_epoch_invalid','empty epoch rejected');
select pg_temp.activation_headers(repeat(' ',65537)||'{}');
select throws_ok($$select pg_temp.activation_in('activation-huge-headers')$$,'P0001','attendance_epoch_invalid','oversized metadata rejected before JSON parsing');
select pg_temp.activation_headers(jsonb_build_object('x-chantipoint-attendance-epoch',gen_random_uuid())::text);
select throws_ok($$select pg_temp.activation_in('activation-wrong-epoch')$$,'P0001','attendance_epoch_mismatch','foreign environment epoch rejected');
select pg_temp.activation_headers(jsonb_build_object('x-chantipoint-attendance-epoch',
 (select deployment_epoch from activation_state),'write_contract',2)::text);
select is(public.attendance_capability()->>'v2_available','false','client claim does not change capability');
select throws_ok($$select pg_temp.activation_in('activation-client-cannot-enable')$$,'P0001',
 'attendance_contract_not_enabled','correct epoch and forged gate do not authorize writes');
select is(pg_temp.activation_in('activation-replay-miss',true),'{"contract_version":2,"status":"not_found"}'::jsonb,
 'matching-epoch replay-only miss preserves exact inconclusive contract at gate 1');
select is((select count(*)::int from public.work_sessions),0,'failed/miss requests created no attendance');

-- Legacy and both note writers retain their complete gate-1 behavior, no epoch.
select pg_temp.activation_headers('');
insert into activation_results values('legacy',public.check_in('factory','Fictional workshop',null,'activation-legacy-in'));
select is(public.update_employee_note(pg_temp.activation_id('legacy'),'First fictional note')->>'status','updated','unkeyed notes work at gate 1');
insert into activation_results values('note',public.save_employee_note(pg_temp.activation_id('legacy'),
 'activation-note-key','replace','Settled fictional note',false));
select is((select r->>'outcome' from activation_results where label='note'),'applied','keyed notes work at gate 1');
select is(public.save_employee_note(pg_temp.activation_id('legacy'),'activation-note-key','replace','Settled fictional note',true),
 (select r from activation_results where label='note'),'terminal note evidence replays unchanged at gate 1');
select throws_ok($$select public.check_in('factory','Changed',null,'activation-legacy-in')$$,
 '23505','idempotency_key_conflict','original legacy payload binding remains enforced');
insert into activation_results values('legacy_out',public.check_out(pg_temp.activation_id('legacy'),'activation-legacy-out',null));
select is((select r->>'status' from activation_results where label='legacy_out'),'closed','legacy checkout works at gate 1');
select is(public.check_out(pg_temp.activation_id('legacy'),'activation-legacy-out',null),
 (select r||'{"status":"idempotent_replay"}'::jsonb from activation_results where label='legacy_out'),'legacy receipt replay is exact at gate 1');
insert into activation_results values('legacy_active',public.check_in('factory',null,null,'activation-still-active'));
reset role;
create temporary table activation_before as select jsonb_build_array(
 (select jsonb_agg(to_jsonb(s) order by id) from public.work_sessions s),
 (select jsonb_agg(to_jsonb(e) order by id) from public.session_events e),
 (select jsonb_agg(to_jsonb(l) order by id) from public.location_observations l),
 (select jsonb_agg(to_jsonb(o) order by operation_key) from private.employee_note_operations o)) value;

update private.attendance_deployment set write_contract=2 where singleton;
set local role authenticated;
select is(public.attendance_capability()->>'v2_available','true','gate 2 advertises v2');
select throws_ok($$select public.check_in('factory',null,null,'activation-new-legacy')$$,
 'P0001','attendance_client_update_required','new legacy check-in retired');
select throws_ok($$select public.check_in('factory',null,null,'activation-still-active')$$,
 'P0001','attendance_client_update_required','legacy replay cannot bypass retired endpoint');
select throws_ok($$select public.check_out(pg_temp.activation_id('legacy_active'),'activation-retired-out',null)$$,
 'P0001','attendance_client_update_required','legacy checkout cannot close an active session');
select throws_ok($$select public.check_out(pg_temp.activation_id('legacy'),'activation-legacy-out',null)$$,
 'P0001','attendance_client_update_required','accepted legacy checkout remains retained, not redispatched');
select throws_ok($$select public.update_employee_note(pg_temp.activation_id('legacy_active'),'Late unkeyed')$$,
 'P0001','standalone_notes_not_enabled','unkeyed note mutations retired');
select throws_ok($$select public.save_employee_note(pg_temp.activation_id('legacy_active'),'activation-late-note','replace','Late keyed',false)$$,
 'P0001','standalone_notes_not_enabled','keyed note mutations retired');
select throws_ok($$select public.save_employee_note(pg_temp.activation_id('legacy_active'),'activation-late-fence','replace','Late fence',true)$$,
 'P0001','standalone_notes_not_enabled','replay-only miss cannot insert a note fence at gate 2');
select throws_ok($$select public.save_employee_note(pg_temp.activation_id('legacy'),'activation-note-key','replace','Settled fictional note',true)$$,
 'P0001','standalone_notes_not_enabled','retired note endpoint does not reinterpret retained terminal proof');
reset role;
select is(jsonb_build_array(
 (select jsonb_agg(to_jsonb(s) order by id) from public.work_sessions s),
 (select jsonb_agg(to_jsonb(e) order by id) from public.session_events e),
 (select jsonb_agg(to_jsonb(l) order by id) from public.location_observations l),
 (select jsonb_agg(to_jsonb(o) order by operation_key) from private.employee_note_operations o)),
 (select value from activation_before),'gate change and all retired calls leave complete existing evidence unchanged');

set local role authenticated;
select pg_temp.activation_headers(jsonb_build_object('x-chantipoint-attendance-epoch',
 (select deployment_epoch from activation_state))::text);
insert into activation_results values('v2_out',public.check_out_v2(pg_temp.activation_id('legacy_active'),
 'activation-v2-out',p_note_action=>'replace',p_employee_note=>'Final fictional note'));
select is((select r->>'status' from activation_results where label='v2_out'),'closed','matching-epoch authorized v2 closes original active session');
select is((select employee_note from public.work_sessions where id=pg_temp.activation_id('legacy_active')),
 'Final fictional note','immutable final note remains part of atomic checkout');
insert into activation_results values('v2',pg_temp.activation_in('activation-v2-in',false,'Fictional worksite'));
select is((select r->>'status' from activation_results where label='v2'),'created','gate 2 permits authorized matching-epoch v2');
select is((select array_agg(k order by k) from activation_results,lateral jsonb_object_keys(r) k where label='v2'),
 array['contract_version','ended_at','event_id','lifecycle_status','location_context','location_outcome','review_status','session_id','started_at','status']::text[],
 'receipt retains exactly ten original fields; epoch is not added');
select is(pg_temp.activation_in('activation-v2-in',true,'Fictional worksite'),
 (select r||'{"status":"idempotent_replay"}'::jsonb from activation_results where label='v2'),'matching replay returns exact receipt and original event/time');
select throws_ok($$select pg_temp.activation_in('activation-v2-in',true,'Changed')$$,
 '23505','idempotency_key_conflict','frozen command payload remains hash-bound');

-- Capability-before-rotation is stale: neither old original nor replay may send.
reset role;
update private.attendance_deployment set deployment_epoch=gen_random_uuid() where singleton;
set local role authenticated;
select throws_ok($$select pg_temp.activation_in('activation-v2-in',true,'Fictional worksite')$$,
 'P0001','attendance_epoch_mismatch','rotation rejects stale replay even for an accepted key');
select throws_ok($$select pg_temp.activation_in('activation-late-original')$$,
 'P0001','attendance_epoch_mismatch','rotation rejects an old capability then delayed original');
select pg_temp.activation_headers(jsonb_build_object('x-chantipoint-attendance-epoch',
 public.attendance_capability()->>'deployment_epoch')::text);
select is(pg_temp.activation_in('activation-v2-in',true,'Fictional worksite'),
 (select r||'{"status":"idempotent_replay"}'::jsonb from activation_results where label='v2'),
 'server receipt/hash are unchanged by epoch rotation; client rebinding is NOT authorized by this test');

-- Rollback to gate 1 stops new v2 writes but preserves matching-epoch replay.
reset role;
update private.attendance_deployment set write_contract=1 where singleton;
set local role authenticated;
select is(public.attendance_capability()->>'v2_available','false','capability observes gate withdrawal');
select throws_ok($$select pg_temp.activation_in('activation-after-withdrawal')$$,
 'P0001','attendance_contract_not_enabled','gate withdrawal blocks delayed new v2 submission');
select is(pg_temp.activation_in('activation-v2-in',true,'Fictional worksite')->>'event_id',
 (select r->>'event_id' from activation_results where label='v2'),'accepted v2 proof still replays at gate 1');
select is(pg_temp.activation_in('activation-still-missing',true),'{"contract_version":2,"status":"not_found"}'::jsonb,
 'replay miss remains inconclusive and does not consume a key');
select pg_temp.activation_user(2);
select is(pg_temp.activation_in('activation-v2-in',true,'Fictional worksite'),'{"contract_version":2,"status":"not_found"}'::jsonb,
 'same-company colleague cannot obtain original owner receipt');
select pg_temp.activation_user(4);
select is(pg_temp.activation_in('activation-v2-in',true,'Fictional worksite'),'{"contract_version":2,"status":"not_found"}'::jsonb,
 'other-company replay cannot obtain original owner receipt');
select pg_temp.activation_user(3);
select throws_ok($$select public.attendance_capability()$$,'42501','employee_role_required','admin-only profile has no employee capability');
select pg_temp.activation_user(1);
reset role;
update public.user_profiles set status='disabled' where id=(select p from activation_people where n=1);
set local role authenticated;
select throws_ok($$select public.attendance_capability()$$,'42501','employee_role_required','disabled employee denied capability');
reset role;
update public.user_profiles set status='active' where id=(select p from activation_people where n=1);
update public.role_assignments set status='revoked',revoked_at=statement_timestamp()
 where user_profile_id=(select p from activation_people where n=1);
set local role authenticated;
select throws_ok($$select public.attendance_capability()$$,'42501','employee_role_required','revoked employee denied capability');
select pg_temp.activation_user(null);
select throws_ok($$select public.attendance_capability()$$,'42501','authentication_required','no auth identity denied capability');
set local role anon;
select throws_ok($$select public.attendance_capability()$$,'42501',null::text,'anonymous cannot invoke capability');
reset role;
update public.role_assignments set status='active',revoked_at=null
 where user_profile_id=(select p from activation_people where n=1);
select pg_temp.activation_user(1);
delete from private.attendance_deployment;
set local role authenticated;
select is(public.attendance_capability(),'{"capability_version":1,"deployment_epoch":null,"write_contract":null,"v2_available":false}'::jsonb,
 'missing server identity cannot advertise availability');
select throws_ok($$select pg_temp.activation_in('activation-no-state')$$,'P0001','attendance_deployment_unavailable','missing identity fails closed');
reset role;
insert into private.attendance_deployment select * from activation_state;
select is(private.attendance_write_contract(),1,'original gate 1 restored before rollback');
select is((select deployment_epoch from private.attendance_deployment),(select deployment_epoch from activation_state),
 'original epoch restored by rollback-only fixture');
set local transaction_read_only=on;
set local role authenticated;
select is(public.attendance_capability()->>'v2_available','false','authorized capability executes in a real READ ONLY transaction');
reset role;
select * from finish();
rollback;
