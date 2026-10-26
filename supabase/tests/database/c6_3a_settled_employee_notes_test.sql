begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Fictional fixtures, receipts and injected failures are rollback-only.
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
select ('a6310000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  'authenticated','authenticated','settled.'||n||'@example.test','not-a-password',statement_timestamp()
from generate_series(1,4) n;
insert into public.companies(id,name) values
  ('b6310000-0000-4000-8000-000000000001','Fictional settled notes'),
  ('b6310000-0000-4000-8000-000000000002','Other fictional settled notes');
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
select ('c6310000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  ('a6310000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  case when n=3 then 'b6310000-0000-4000-8000-000000000002'::uuid
    else 'b6310000-0000-4000-8000-000000000001'::uuid end,
  'Fictional employee '||n,'settled.'||n||'@example.test'
from generate_series(1,4) n;
insert into public.role_assignments(user_profile_id,company_id,role)
select id,company_id,case when email='settled.4@example.test' then 'administrator' else 'employee' end
from public.user_profiles where id::text like 'c6310000-%';

create temporary table settled_results(label text primary key,result jsonb);
grant select,insert on settled_results to authenticated;
create function pg_temp.s_id(p_label text) returns uuid language sql as $$
  select (result->>'session_id')::uuid from settled_results where label=p_label
$$;
create function pg_temp.s_save(p_key text,p_text text,p_replay boolean default false,
  p_action text default 'replace',p_session uuid default null)
returns jsonb language sql as $$
  select public.save_employee_note(coalesce(p_session,pg_temp.s_id('active')),
    p_key,p_action,p_text,p_replay)
$$;

select is(private.attendance_write_contract(),1,'new contract does not activate attendance v2');
select ok(to_regprocedure('public.update_employee_note(uuid,text)') is not null,'unkeyed RPC retained');
select ok((select prosecdef and 'search_path=""'=any(proconfig) and 'TimeZone=UTC'=any(proconfig)
  and pronargdefaults=1 from pg_proc where oid='public.save_employee_note(uuid,text,text,text,boolean)'::regprocedure),
  'new RPC security definer, empty search path, UTC, only replay argument optional');
select ok(has_function_privilege('authenticated','public.save_employee_note(uuid,text,text,text,boolean)','execute')
  and not has_function_privilege('anon','public.save_employee_note(uuid,text,text,text,boolean)','execute'),
  'authenticated-only RPC grant');
select ok((select relrowsecurity from pg_class where oid='private.employee_note_operations'::regclass),
  'operation evidence has RLS enabled');
select is((select count(*)::int from pg_policy where polrelid='private.employee_note_operations'::regclass),0,
  'no client metadata policies');
select ok(not has_table_privilege('authenticated','private.employee_note_operations','select,insert,update,delete')
  and not has_table_privilege('anon','private.employee_note_operations','select,insert,update,delete'),
  'no direct metadata grants');
select is((select count(*)::int from information_schema.columns where table_schema='private'
  and table_name='employee_note_operations'),11,'metadata includes protocol and epoch separation; no note text/action history');
select is((select count(*)::int from pg_constraint where conrelid='private.employee_note_operations'::regclass
  and contype='f'),2,'auth and full session/owner foreign keys');

set local role authenticated;
select set_config('request.jwt.claim.sub','a6310000-0000-4000-8000-000000000001',true);
insert into settled_results values ('active',public.check_in('factory',null,null,'settled-start-001'));
insert into settled_results values ('before',(select to_jsonb(s)-'employee_note'-'updated_at'
  from public.work_sessions s where id=pg_temp.s_id('active')));
insert into settled_results values ('first',pg_temp.s_save('settled-first-001','  Réparation é terminée.  '));
select is((select result->>'outcome' from settled_results where label='first'),'applied','initial write applied');
select is((select result->>'note_contract_version' from settled_results where label='first'),'1','separate note contract version');
select is((select result->>'session_id' from settled_results where label='first'),pg_temp.s_id('active')::text,'receipt binds original session');
select is((select result->>'employee_profile_id' from settled_results where label='first'),'c6310000-0000-4000-8000-000000000001','receipt binds employee');
select is((select result->>'company_id' from settled_results where label='first'),'b6310000-0000-4000-8000-000000000001','receipt binds company');
select is((select result->>'operation_key' from settled_results where label='first'),'settled-first-001','receipt binds exact key');
select is((select result->'reason' from settled_results where label='first'),'null'::jsonb,'applied reason is null');
select ok((select (result->>'request_fingerprint') ~ '^[0-9a-f]{64}$'
  and (result->>'settled_at')::timestamptz is not null from settled_results where label='first'),'fingerprint and timestamp present');
select is((select count(*)::int from jsonb_object_keys((select result from settled_results where label='first'))),9,'receipt exact bounded field set, no note text');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),'  Réparation é terminée.  ','spaces/decomposed Unicode unchanged');
select is((select to_jsonb(s)-'employee_note'-'updated_at' from public.work_sessions s where id=pg_temp.s_id('active')),
  (select result from settled_results where label='before'),'no other session fields mutated');
select is(pg_temp.s_save('settled-first-001','  Réparation é terminée.  ',true),
  (select result from settled_results where label='first'),'lost response recovered as identical terminal receipt');
select is(pg_temp.s_save('settled-first-001','  Réparation é terminée.  '),
  (select result from settled_results where label='first'),'duplicate original returns same receipt');
select throws_ok($$select pg_temp.s_save('settled-first-001','changed')$$,'23505','note_operation_conflict','changed text conflicts');
select throws_ok($$select pg_temp.s_save('settled-first-001','  Réparation é terminée.  ',true)$$,
  '23505','note_operation_conflict','equivalent-looking composed text does not replace original combining sequence');
select throws_ok($$select pg_temp.s_save('settled-first-001',null,true,'clear')$$,'23505','note_operation_conflict','changed intent conflicts on replay');
select is(pg_temp.s_save('settled-next-001','New current note')->>'outcome','applied','new key can edit');
select is(pg_temp.s_save('settled-first-001','  Réparation é terminée.  ',true),
  (select result from settled_results where label='first'),'replay is historical operation proof, not current note');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),'New current note','old replay never reapplies overwritten text');

insert into settled_results values ('fence',pg_temp.s_save('settled-fence-001','Never apply',true));
select is((select result->>'outcome' from settled_results where label='fence'),'not_applied','replay miss is terminal non-applied');
select is((select result->>'reason' from settled_results where label='fence'),'replay_fenced','miss installs durable fence');
select is(pg_temp.s_save('settled-fence-001','Never apply'),
  (select result from settled_results where label='fence'),'late original returns fence rather than writing');
select is(pg_temp.s_save('settled-fence-001','Never apply',true),
  (select result from settled_results where label='fence'),'repeated replay returns same fence');
select throws_ok($$select pg_temp.s_save('settled-fence-001','different',true)$$,'23505','note_operation_conflict','fenced key cannot be retargeted');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),'New current note','fencing does not update note');

select is(pg_temp.s_save('settled-clear-001',null,false,'clear')->>'outcome','applied','explicit clear accepted');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),null::text,'clear stores null');
insert into settled_results values ('empty',pg_temp.s_save('settled-empty-001',''));
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),'','empty replacement is text');
select throws_ok($$select pg_temp.s_save('settled-empty-001',null,false,'clear')$$,'23505','note_operation_conflict','empty and clear have different fingerprints');
select is(pg_temp.s_save('settled-unchanged-001','')->>'outcome','applied','unchanged value is a separate identified applied operation');
select is(pg_temp.s_save('settled-unicode-001',repeat(E'e\u0301',500))->>'outcome','applied','1000 combining code points accepted');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),repeat(E'e\u0301',500),'no normalization');
select throws_ok($$select pg_temp.s_save('settled-unicode-over',repeat(E'e\u0301',500)||'x')$$,
  '22023','employee_note_too_long','1001 code points rejected');
select is(pg_temp.s_save('settled-astral-001',repeat('🚧',1000))->>'outcome','applied','1000 astral code points accepted');
select throws_ok($$select pg_temp.s_save('settled-astral-over',repeat('🚧',1001))$$,
  '22023','employee_note_too_long','1001 astral code points rejected');
select is(pg_temp.s_save('12345678','Eight-character key')->>'outcome','applied','minimum key length accepted');
select is(pg_temp.s_save(repeat('k',160),'Maximum key length')->>'outcome','applied','maximum key length accepted');
-- Restore the known text for the later atomic-rollback assertion.
select pg_temp.s_save('settled-before-atomic',repeat('🚧',1000));
select throws_ok($$select pg_temp.s_save('short','text')$$,'22023','invalid_note_operation_key','short key rejected');
select throws_ok($$select pg_temp.s_save(repeat('k',161),'text')$$,'22023','invalid_note_operation_key','oversized key rejected');
select throws_ok($$select pg_temp.s_save(' padded-key','text')$$,'22023','invalid_note_operation_key','key not silently trimmed');
select throws_ok($$select pg_temp.s_save(null,'text')$$,'22023','invalid_note_operation_key','null key rejected');
select throws_ok($$select pg_temp.s_save('invalid-note-null',null)$$,'22023','invalid_employee_note_operation','replace requires nonnull text');
select throws_ok($$select pg_temp.s_save('invalid-note-clear','text',false,'clear')$$,'22023','invalid_employee_note_operation','clear cannot discard text');
select throws_ok($$select pg_temp.s_save('invalid-note-action','text',false,'preserve')$$,'22023','invalid_employee_note_operation','standalone preserve is not a mutation intent');
select throws_ok($$select pg_temp.s_save('invalid-note-action','text',false,null)$$,'22023','invalid_employee_note_operation','null action rejected');
select throws_ok($$select pg_temp.s_save('invalid-replay-flag','text',null)$$,'22023','invalid_employee_note_operation','null replay flag rejected');
select throws_ok($$select public.save_employee_note(null,'invalid-session-id','replace','text')$$,'22023','work_session_id_required','null session rejected');
select throws_ok($$select public.save_employee_note('d6310000-0000-4000-8000-000000000099','missing-session-id','replace','text',true)$$,
  '42501','active_session_not_found_for_employee','missing session does not create a fence');
select throws_ok($$select * from private.employee_note_operations$$,'42501',null::text,'even owner cannot read metadata directly');
select throws_ok($$delete from private.employee_note_operations$$,'42501',null::text,'owner cannot remove fences');
select throws_ok($$update private.employee_note_operations set outcome='applied'$$,'42501',null::text,'owner cannot forge evidence');

-- Same company and other company employees have independent key namespaces.
select set_config('request.jwt.claim.sub','a6310000-0000-4000-8000-000000000002',true);
insert into settled_results values ('peer',public.check_in('factory',null,null,'settled-peer-start'));
select throws_ok($$select pg_temp.s_save('settled-first-001','  Réparation é terminée.  ',true)$$,
  '42501','active_session_not_found_for_employee','peer cannot replay owner session');
select is(pg_temp.s_save('settled-first-001','Peer note',false,'replace',pg_temp.s_id('peer'))->>'outcome','applied','same key can be used independently by peer');
select set_config('request.jwt.claim.sub','a6310000-0000-4000-8000-000000000003',true);
insert into settled_results values ('foreign',public.check_in('factory',null,null,'settled-foreign-start'));
select throws_ok($$select pg_temp.s_save('settled-fence-001','Never apply',true)$$,
  '42501','active_session_not_found_for_employee','foreign employee cannot observe owner fence');
select is(pg_temp.s_save('settled-first-001','Other company note',false,'replace',pg_temp.s_id('foreign'))->>'outcome','applied','same key independent across company');
select set_config('request.jwt.claim.sub','a6310000-0000-4000-8000-000000000004',true);
select throws_ok($$select pg_temp.s_save('admin-note-key','Admin note')$$,'42501','employee_role_required','administrator-only cannot save or replay');
select throws_ok($$select * from private.employee_note_operations$$,'42501',null::text,'administrator cannot enumerate evidence');
select set_config('request.jwt.claim.sub','a6310000-0000-4000-8000-000000000001',true);
select throws_ok($$select pg_temp.s_save('cross-owner-key','bad',false,'replace',pg_temp.s_id('peer'))$$,
  '42501','active_session_not_found_for_employee','same-company session write denied');
select throws_ok($$select pg_temp.s_save('cross-tenant-key','bad',false,'replace',pg_temp.s_id('foreign'))$$,
  '42501','active_session_not_found_for_employee','cross-company session write denied');
reset role;
select is((select count(*)::int from private.employee_note_operations where operation_key in
  ('cross-owner-key','cross-tenant-key','missing-session-id','invalid-note-null','settled-unicode-over')),0,'invalid/foreign requests leave no evidence');
update public.user_profiles set status='disabled' where id='c6310000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select pg_temp.s_save('settled-first-001','  Réparation é terminée.  ',true)$$,'42501','employee_role_required','disabled owner cannot retrieve existing proof');
reset role;
update public.user_profiles set status='active' where id='c6310000-0000-4000-8000-000000000001';
update public.role_assignments set status='revoked',revoked_at=statement_timestamp() where user_profile_id='c6310000-0000-4000-8000-000000000001';
set local role authenticated;
select throws_ok($$select pg_temp.s_save('revoked-note-key','bad')$$,'42501','employee_role_required','revoked employee cannot save');
reset role;
update public.role_assignments set status='active',revoked_at=null where user_profile_id='c6310000-0000-4000-8000-000000000001';
select set_config('request.jwt.claim.sub','',true);
select throws_ok($$select pg_temp.s_save('no-auth-note-key','bad')$$,'42501','authentication_required','absent identity denied');
set local role anon;
select throws_ok($$select public.save_employee_note('d6310000-0000-4000-8000-000000000099','anonymous-note-key','replace','bad')$$,'42501',null::text,'anonymous cannot execute');
reset role;

-- Inject failure in evidence persistence AFTER the note update. Both must roll back.
create function pg_temp.fail_note_evidence() returns trigger language plpgsql as $$
begin
  if new.operation_key='atomic-failure-key' then raise exception 'fixture_evidence_failure'; end if;
  return new;
end;
$$;
create trigger settled_atomic_fixture before insert on private.employee_note_operations
  for each row execute function pg_temp.fail_note_evidence();
set local role authenticated;
select set_config('request.jwt.claim.sub','a6310000-0000-4000-8000-000000000001',true);
select throws_ok($$select pg_temp.s_save('atomic-failure-key','Must roll back')$$,'P0001','fixture_evidence_failure','evidence failure aborts note mutation');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),repeat('🚧',1000),'note rolled back with missing evidence');
reset role;
select is((select count(*)::int from private.employee_note_operations where operation_key='atomic-failure-key'),0,'failed transaction has no terminal evidence');
drop trigger settled_atomic_fixture on private.employee_note_operations;
set local role authenticated;
select is(pg_temp.s_save('atomic-failure-key','Must roll back')->>'outcome','applied','exact original may retry after actual rollback');

-- A later unkeyed edit is still allowed: proof identifies an operation, not current note.
select is(public.update_employee_note(pg_temp.s_id('active'),'Unkeyed later value')->>'status','updated','unkeyed API compatibility retained');
select is(pg_temp.s_save('atomic-failure-key','Must roll back',true)->>'outcome','applied','keyed replay remains stable after unkeyed edit');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),'Unkeyed later value','keyed replay cannot undo unkeyed edit');
insert into settled_results values ('closed',public.check_out(pg_temp.s_id('active'),'settled-checkout-key'));
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('active')),'Unkeyed later value','checkout preserves latest serialized note');
select is(pg_temp.s_save('atomic-failure-key','Must roll back',true)->>'outcome','applied','lost applied reply recoverable after closure');
insert into settled_results values ('closed_reject',pg_temp.s_save('closed-note-key','Too late'));
select is((select result->>'outcome' from settled_results where label='closed_reject'),'not_applied','closed session write terminally prevented');
select is((select result->>'reason' from settled_results where label='closed_reject'),'session_closed','closed outcome precise');
select is(pg_temp.s_save('closed-note-key','Too late',true),(select result from settled_results where label='closed_reject'),'closed failure replay stable');
reset role;
create function pg_temp.s_closed_shapes() returns setof text language plpgsql as $$
declare v_status text;
begin
  foreach v_status in array array['closed_automatic','closed_admin','voided'] loop
    update public.work_sessions set lifecycle_status=v_status where id=pg_temp.s_id('active');
    set local role authenticated;
    return next is(pg_temp.s_save('closed-shape-'||v_status,'Never written')->>'reason',
      'session_closed',v_status||' cannot receive a new note');
    return next is(pg_temp.s_save('closed-shape-'||v_status,'Never written',true)->>'reason',
      'session_closed',v_status||' terminal rejection is replayable');
    reset role;
  end loop;
end;
$$;
select * from pg_temp.s_closed_shapes();
set local role authenticated;
insert into settled_results values ('replacement',public.check_in('factory',null,null,'settled-replacement-in'));
select throws_ok($$select pg_temp.s_save('settled-first-001','  Réparation é terminée.  ',false,'replace',pg_temp.s_id('replacement'))$$,
  '23505','note_operation_conflict','key cannot target replacement session');
select is((select employee_note from public.work_sessions where id=pg_temp.s_id('replacement')),null::text,'replacement session untouched');
select is(pg_temp.s_save('settled-fence-001','Never apply'),(select result from settled_results where label='fence'),'original fence survives checkout/replacement');
reset role;
select is((select count(*)::int from public.session_events where employee_profile_id='c6310000-0000-4000-8000-000000000001'),3,'only attendance events, no note history events');
select ok(not exists(select 1 from private.employee_note_operations where
  to_jsonb(employee_note_operations)::text like '%Réparation%' or
  to_jsonb(employee_note_operations)::text like '%Must roll back%'),'evidence never retains historical note text');
select is(private.attendance_write_contract(),1,'gate still legacy at suite end');
select * from finish();
rollback;
