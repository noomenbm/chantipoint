begin;
create extension if not exists pgtap with schema extensions;
select no_plan();
-- All identities and text below are fictional, rollback-only fixtures.
update private.attendance_deployment set write_contract=1;
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
select ('a6320000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'authenticated','authenticated','note-v2.'||n||'@example.test','not-a-password',statement_timestamp()
from generate_series(1,3) n;
insert into public.companies(id,name) values ('b6320000-0000-4000-8000-000000000001','Fictional notes v2');
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
select ('c6320000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('a6320000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'b6320000-0000-4000-8000-000000000001','Fictional employee','note-v2.'||n||'@example.test'
from generate_series(1,3) n;
insert into public.role_assignments(user_profile_id,company_id,role)
select id,company_id,case when email='note-v2.3@example.test' then 'administrator' else 'employee' end
from public.user_profiles where id::text like 'c6320000-%';
create temporary table note_v2_results(label text primary key,r jsonb);
grant select,insert on note_v2_results to authenticated;
create function pg_temp.n_session() returns uuid language sql as $$
 select (r->>'session_id')::uuid from note_v2_results where label='session'
$$;
create function pg_temp.n_save(k text,t text,replay boolean default false,a text default 'replace')
returns jsonb language sql as $$
 select public.save_employee_note_v2(pg_temp.n_session(),k,a,t,replay)
$$;
select ok(has_function_privilege('authenticated','public.save_employee_note_v2(uuid,text,text,text,boolean)','execute')
 and not has_function_privilege('anon','public.save_employee_note_v2(uuid,text,text,text,boolean)','execute'), 'v2 authenticated only');
select ok(not has_function_privilege('authenticated','private.save_employee_note_legacy_impl(uuid,text,text,text,boolean)','execute'), 'private helper remains inaccessible');
select set_config('request.headers',jsonb_build_object('x-chantipoint-attendance-epoch',deployment_epoch)::text,true)
from private.attendance_deployment;
set local role authenticated;
select set_config('request.jwt.claim.sub','a6320000-0000-4000-8000-000000000001',true);
insert into note_v2_results values('session',public.check_in('factory',null,null,'note-v2-legacy-start'));
insert into note_v2_results values('legacy',public.save_employee_note(pg_temp.n_session(),'legacy-note-key','replace','legacy',false));
select is((select r->>'outcome' from note_v2_results where label='legacy'),'applied','gate 1 legacy behavior preserved');
select throws_ok($$select pg_temp.n_save('gate-one-new-key','blocked')$$,'P0001','standalone_notes_not_enabled','v2 denies gate 1');
reset role;
update private.attendance_deployment set write_contract=2;
set local role authenticated;
select throws_ok($$select public.save_employee_note(pg_temp.n_session(),'retired-key','replace','blocked',false)$$,'P0001','standalone_notes_not_enabled','old keyed endpoint remains retired at gate 2');
select throws_ok($$select public.update_employee_note(pg_temp.n_session(),'blocked')$$,'P0001','standalone_notes_not_enabled','unkeyed endpoint remains retired at gate 2');
select throws_ok($$select public.check_out(pg_temp.n_session(),'legacy-checkout-key')$$,'P0001','attendance_client_update_required','legacy checkout stays retired');
select throws_ok($$select pg_temp.n_save('legacy-note-key','legacy',true)$$,'23505','note_operation_conflict','legacy key cannot be adopted into v2 on replay');
select throws_ok($$select pg_temp.n_save('legacy-note-key','legacy')$$,'23505','note_operation_conflict','legacy key cannot become a new v2 initial write');
select set_config('request.headers','{}',true);
select throws_ok($$select pg_temp.n_save('epoch-missing-key','blocked')$$,'P0001','attendance_epoch_required','missing epoch denied');
select set_config('request.headers','{"x-chantipoint-attendance-epoch":"00000000-0000-4000-8000-000000000099"}',true);
select throws_ok($$select pg_temp.n_save('epoch-wrong-key','blocked')$$,'P0001','attendance_epoch_mismatch','incorrect epoch denied');
reset role;
select set_config('request.headers',jsonb_build_object('x-chantipoint-attendance-epoch',deployment_epoch)::text,true) from private.attendance_deployment;
set local role authenticated;
insert into note_v2_results values('first',pg_temp.n_save('v2-note-first','  é 😀  '));
select is((select r->>'note_contract_version' from note_v2_results where label='first'),'2','receipt separates v2 protocol');
select is((select count(*)::int from jsonb_object_keys((select r from note_v2_results where label='first'))),10,'receipt has exact v2 field set without note contents');
select is((select employee_note from public.work_sessions where id=pg_temp.n_session()),'  é 😀  ','exact whitespace and decomposed Unicode retained');
select is(pg_temp.n_save('v2-note-first','  é 😀  ',true),(select r from note_v2_results where label='first'),'lost acknowledgement replays identical proof');
select throws_ok($$select pg_temp.n_save('v2-note-first','changed')$$,'23505','note_operation_conflict','changed payload conflicts');
select is(pg_temp.n_save('v2-note-edit','edit')->>'outcome','applied','second key edits note');
select is(pg_temp.n_save('v2-note-first','  é 😀  ',true),(select r from note_v2_results where label='first'),'old proof retained after later edit');
select is((select employee_note from public.work_sessions where id=pg_temp.n_session()),'edit','old replay cannot reapply old note');
select is(pg_temp.n_save('v2-note-empty','')->>'outcome','applied','empty text accepted');
select is((select employee_note from public.work_sessions where id=pg_temp.n_session()),'','empty remains distinct from null');
select is(pg_temp.n_save('v2-note-clear',null,false,'clear')->>'outcome','applied','explicit clear accepted');
select ok((select employee_note is null from public.work_sessions where id=pg_temp.n_session()),'clear stores null');
select throws_ok($$select pg_temp.n_save('v2-note-invalid',null)$$,'22023','invalid_employee_note_operation','replace null rejected');
select throws_ok($$select pg_temp.n_save('v2-note-long',repeat('😀',1001))$$,'22023','employee_note_too_long','Unicode code point limit enforced');
select is(pg_temp.n_save('v2-note-limit',repeat('😀',1000))->>'outcome','applied','1000 astral code points accepted');
select is(pg_temp.n_save('v2-note-fence','never',true)->>'reason','replay_fenced','replay miss installs terminal fence');
select is(pg_temp.n_save('v2-note-fence','never')->>'reason','replay_fenced','later original cannot bypass fence');
select set_config('request.jwt.claim.sub','a6320000-0000-4000-8000-000000000002',true);
select throws_ok($$select pg_temp.n_save('v2-note-other','blocked')$$,'42501','active_session_not_found_for_employee','foreign owner denied');
select set_config('request.jwt.claim.sub','a6320000-0000-4000-8000-000000000003',true);
select throws_ok($$select pg_temp.n_save('v2-note-admin','blocked')$$,'42501','employee_role_required','admin-only role denied');
select set_config('request.jwt.claim.sub','a6320000-0000-4000-8000-000000000001',true);
select pg_temp.n_save('v2-before-preserve','saved');
select public.check_out_v2(pg_temp.n_session(),'v2-close-preserve',p_note_action=>'preserve');
select is((select employee_note from public.work_sessions where id=pg_temp.n_session()),'saved','checkout preserve keeps saved note');
select is(pg_temp.n_save('v2-after-close','never')->>'reason','session_closed','closed session settles without mutation');
select is((select employee_note from public.work_sessions where id=pg_temp.n_session()),'saved','Save after checkout cannot change closed note');
reset role;
select ok((select bool_and(protocol_version=2 and deployment_epoch=(select deployment_epoch from private.attendance_deployment))
 from private.employee_note_operations where operation_key like 'v2-%'),'v2 evidence pinned to transaction epoch');
update private.attendance_deployment set deployment_epoch=gen_random_uuid();
select set_config('request.headers',jsonb_build_object('x-chantipoint-attendance-epoch',deployment_epoch)::text,true) from private.attendance_deployment;
set local role authenticated;
select throws_ok($$select pg_temp.n_save('v2-note-first','  é 😀  ',true)$$,'23505','note_operation_conflict','old epoch key cannot be adopted after rotation');
reset role;
update private.attendance_deployment set write_contract=1;
set local role authenticated;
select throws_ok($$select public.save_employee_note(pg_temp.n_session(),'v2-note-first','replace','  é 😀  ',true)$$,'23505','note_operation_conflict','gate rollback cannot adopt v2 key into legacy');
select is(public.save_employee_note(pg_temp.n_session(),'legacy-note-key','replace','legacy',true),(select r from note_v2_results where label='legacy'),'legacy proof still replays exactly at gate 1');
select * from finish();
rollback;
