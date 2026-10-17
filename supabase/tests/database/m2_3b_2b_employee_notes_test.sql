begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- Fictional identities and factory configuration exist only in this transaction.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
select ('91000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
  'authenticated','authenticated','notes.' || n || '@example.test','not-a-password',statement_timestamp()
from generate_series(1,4) n;
insert into public.companies (id,name) values
  ('92000000-0000-0000-0000-000000000001','Fictional Note Company'),
  ('92000000-0000-0000-0000-000000000002','Other Fictional Note Company');
insert into public.user_profiles (id,auth_user_id,company_id,display_name,email)
select ('93000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
  ('91000000-0000-0000-0000-' || lpad(n::text,12,'0'))::uuid,
  case when n=2 then '92000000-0000-0000-0000-000000000002'::uuid else '92000000-0000-0000-0000-000000000001'::uuid end,
  'Fictional Note Employee ' || n,'notes.' || n || '@example.test'
from generate_series(1,4) n;
insert into public.role_assignments (user_profile_id,company_id,role)
select id,company_id,case when email='notes.4@example.test' then 'administrator' else 'employee' end
from public.user_profiles where id::text like '93000000-%';

create temporary table note_clock as select statement_timestamp() as observed;
create temporary table note_results (label text primary key,result jsonb);
create temporary table note_gate as select pg_get_functiondef('private.attendance_write_contract()'::regprocedure) as definition;
grant select on note_clock to authenticated;
grant select,insert on note_results to authenticated;
create function pg_temp.note_id(p_label text) returns uuid language sql as $$
  select (result->>'session_id')::uuid from note_results where label=p_label
$$;
create function pg_temp.note_start(p_key text) returns jsonb language sql as $$
  select public.check_in_v2(p_idempotency_key=>p_key,p_device_observed_at=>observed,
    p_latitude=>0,p_longitude=>0.0001,p_accuracy_meters=>10,p_location_observed_at=>observed,
    p_permission=>'precise',p_services_enabled=>true,p_location_result=>'fix',p_provider=>'fused')
  from note_clock
$$;
create function pg_temp.note_finish(p_id uuid,p_key text,p_action text default 'preserve',
  p_note text default null,p_replay boolean default false,p_patch jsonb default '{}')
returns jsonb language sql as $$
  select public.check_out_v2(p_work_session_id=>p_id,p_idempotency_key=>p_key,
    p_device_observed_at=>observed,p_latitude=>(p->>'latitude')::numeric,
    p_longitude=>(p->>'longitude')::numeric,p_accuracy_meters=>(p->>'accuracy')::numeric,
    p_location_observed_at=>(p->>'fix_at')::timestamptz,p_permission=>p->>'permission',
    p_services_enabled=>(p->>'services')::boolean,p_location_result=>p->>'result',p_provider=>p->>'provider',
    p_replay_only=>p_replay,p_note_action=>p_action,p_employee_note=>p_note)
  from note_clock,lateral (select jsonb_build_object('latitude',0,'longitude',0.002,'accuracy',10,
    'fix_at',observed,'permission','precise','services',true,'result','fix','provider','fused') || p_patch p) b
$$;

select is(private.attendance_write_contract(),1,'notes migration preserves legacy gate');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='update_employee_note'),1,'one note update signature');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='check_out_v2'),1,'one checkout signature; no overload bypass');
select ok(to_regprocedure('public.check_out_v2(uuid,text,timestamp with time zone,numeric,numeric,numeric,timestamp with time zone,text,boolean,text,text,boolean)') is null,
  'old checkout signature removed');
select ok(to_regprocedure('private.submit_attendance(integer,text,uuid,text,timestamp with time zone,text,numeric,numeric,numeric,timestamp with time zone,text,boolean,text,text,boolean)') is null,
  'old implementation signature removed');
select ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='private' and p.proname='submit_attendance'
    and (has_function_privilege('authenticated',p.oid,'execute') or has_function_privilege('anon',p.oid,'execute'))),
  'note-aware private implementation denies client execution');
select ok((select p.prosecdef and 'search_path=""'=any(p.proconfig) and p.pronargdefaults=0
    and has_function_privilege('authenticated',p.oid,'execute') and not has_function_privilege('anon',p.oid,'execute')
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='update_employee_note'),
  'note RPC is security definer, fixed search path, authenticated only, both inputs required');
select is((select count(*)::int from information_schema.columns where table_schema='public'
  and table_name='work_sessions' and column_name like 'employee_note%'),1,'only existing note column; no note versions');
select is((select count(*)::int from pg_tables where schemaname='public' and tablename like '%note%'),0,'no note-history table');

set local role authenticated;
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
insert into note_results values ('legacy',public.check_in('factory',null,(select observed from note_clock),'notes-legacy-in-001'));
select is(public.update_employee_note(pg_temp.note_id('legacy'),'Le client ne s’est pas présenté aujourd’hui.'),
  jsonb_build_object('status','updated','session_id',pg_temp.note_id('legacy'),
    'employee_note','Le client ne s’est pas présenté aujourd’hui.'),'owner can add a general business note in legacy mode');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('legacy')),
  'Le client ne s’est pas présenté aujourd’hui.','note stored exactly in existing column');
insert into note_results values ('before_edits',(select to_jsonb(s)-'employee_note'-'updated_at' from public.work_sessions s where id=pg_temp.note_id('legacy')));
select is(public.update_employee_note(pg_temp.note_id('legacy'),'Remplacement')->>'employee_note','Remplacement','replace overwrites previous note');
select is(public.update_employee_note(pg_temp.note_id('legacy'),null)->'employee_note','null'::jsonb,'explicit NULL clears note');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('legacy')),null::text,'cleared note is SQL NULL');
select is(public.update_employee_note(pg_temp.note_id('legacy'),'')->>'employee_note','','empty replacement remains empty text');
select is(public.update_employee_note(pg_temp.note_id('legacy'),'  espaces conservés  ')->>'employee_note','  espaces conservés  ','whitespace is not silently trimmed');
select is(char_length(public.update_employee_note(pg_temp.note_id('legacy'),repeat('é',999)||'🚧')->>'employee_note'),1000,
  '1000 Unicode characters accepted despite larger UTF-8 byte count');
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),repeat('é',1000)||'🚧')$$,
  '22023','employee_note_too_long','1001 Unicode characters rejected');
select is(char_length((select employee_note from public.work_sessions where id=pg_temp.note_id('legacy'))),1000,'oversize edit preserves existing value');
select is(public.update_employee_note(pg_temp.note_id('legacy'),E'e\u0301')->>'employee_note',E'e\u0301','combining sequence preserved without Unicode normalization');
select is(public.update_employee_note(pg_temp.note_id('legacy'),'Last active note')->>'status','updated','subsequent save succeeds');
select is((select to_jsonb(s)-'employee_note'-'updated_at' from public.work_sessions s where id=pg_temp.note_id('legacy')),
  (select result from note_results where label='before_edits'),'ordinary edits change no attendance/review/evidence fields');
select is((select count(*)::int from public.session_events),1,'ordinary edits add no session events');
select is((select count(*)::int from public.location_observations),0,'ordinary edits add no location evidence');
select throws_ok($$update public.work_sessions set employee_note='bypass' where id=pg_temp.note_id('legacy')$$,
  '42501',null::text,'direct table writes remain forbidden');
select throws_ok($$select public.update_employee_note(null,'x')$$,'22023','work_session_id_required','NULL session is invalid');
select throws_ok($$select public.update_employee_note('94000000-0000-0000-0000-000000000001','x')$$,
  '42501','active_session_not_found_for_employee','unknown session does not reveal a record');
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000003',true);
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'colleague')$$,
  '42501','active_session_not_found_for_employee','same-company colleague cannot edit note');
select is((select count(*)::int from public.work_sessions),0,'colleague cannot read another employee note');
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000002',true);
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'tenant')$$,
  '42501','active_session_not_found_for_employee','other tenant cannot edit note');
select is((select count(*)::int from public.work_sessions),0,'other tenant cannot read note');
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000004',true);
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('legacy')),'Last active note','company admin keeps existing company-scoped read access');
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'administrator')$$,
  '42501','employee_role_required','administrator-only role cannot edit employee notes');
reset role;
select is((select count(*)::int from public.admin_audit_events),0,'ordinary note saves create no audit events');
update public.user_profiles set status='disabled' where id='93000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000001',true);
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'disabled')$$,
  '42501','employee_role_required','disabled employee cannot edit note');
reset role;
update public.user_profiles set status='active' where id='93000000-0000-0000-0000-000000000001';
update public.role_assignments set status='revoked',revoked_at=statement_timestamp()
  where user_profile_id='93000000-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'revoked')$$,
  '42501','employee_role_required','revoked employee cannot edit note');
reset role;
update public.role_assignments set status='active',revoked_at=null where user_profile_id='93000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub','',true);
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'unauthenticated')$$,
  '42501','authentication_required','missing Auth identity is rejected');
set local role anon;
select throws_ok($$select public.update_employee_note('94000000-0000-0000-0000-000000000001','anonymous')$$,
  '42501',null::text,'anonymous cannot execute note RPC');
reset role;
update public.companies set status='suspended' where id='92000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub','91000000-0000-0000-0000-000000000001',true);
select is(public.update_employee_note(pg_temp.note_id('legacy'),'Suspended-company active note')->>'status','updated',
  'suspension does not prevent owner annotation of existing active session');
reset role;
update public.companies set status='active' where id='92000000-0000-0000-0000-000000000001';
set local role authenticated;
select is(public.check_out(pg_temp.note_id('legacy'),'notes-legacy-out-001')->>'status','closed','legacy checkout remains functional');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('legacy')),'Suspended-company active note','legacy checkout preserves note');
select throws_ok($$select public.update_employee_note(pg_temp.note_id('legacy'),'closed')$$,
  'P0001','session_not_active','manual closure makes note read-only');
reset role;
-- Verify every other already-supported closure shape, without implementing closure workflows.
create function pg_temp.test_closed_notes() returns setof text language plpgsql as $$
declare v_status text;
begin
  foreach v_status in array array['closed_automatic','closed_admin','voided'] loop
    update public.work_sessions set lifecycle_status=v_status where id=pg_temp.note_id('legacy');
    set local role authenticated;
    return next throws_ok($q$select public.update_employee_note(pg_temp.note_id('legacy'),'closed')$q$,
      'P0001','session_not_active',v_status || ' makes note read-only');
    reset role;
  end loop;
end;
$$;
select * from pg_temp.test_closed_notes();

-- Rollback-only v2 activation and fictional configuration.
select pg_advisory_xact_lock(174811,2);
create or replace function private.attendance_write_contract() returns integer language sql volatile set search_path='' as $$ select 2 $$;
update public.companies set factory_latitude=0,factory_longitude=0,factory_radius_meters=100
  where id='92000000-0000-0000-0000-000000000001';
set local role authenticated;
insert into note_results values ('preserve',pg_temp.note_start('notes-preserve-in-001'));
select public.update_employee_note(pg_temp.note_id('preserve'),'Keep this note');
insert into note_results values ('preserve_out',public.check_out_v2(pg_temp.note_id('preserve'),'notes-preserve-out-001'));
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('preserve')),'Keep this note','omitted note arguments preserve current note');
select is(public.check_out_v2(pg_temp.note_id('preserve'),'notes-preserve-out-001',p_replay_only=>true,p_note_action=>'preserve')->>'status',
  'idempotent_replay','explicit preserve and omitted preserve have the same command hash');
insert into note_results values ('replace',pg_temp.note_start('notes-replace-in-001'));
select public.update_employee_note(pg_temp.note_id('replace'),'Draft not retained');
insert into note_results values ('replace_out',pg_temp.note_finish(pg_temp.note_id('replace'),'notes-replace-out-001','replace','Final business note 🚧'));
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('replace')),'Final business note 🚧','final replacement saved');
select is((select lifecycle_status from public.work_sessions where id=pg_temp.note_id('replace')),'closed_manual','replacement and closure accepted together');
select is((select result->>'location_context' from note_results where label='replace_out'),'factory','arrival classification preserved');
select is((select result#>>'{location_outcome,classification}' from note_results where label='replace_out'),'external_worksite','independent departure classification preserved');
select is((select result->>'review_status' from note_results where label='replace_out'),'normal','successful evidence preserves review status');
select is((select count(*)::int from public.session_events where work_session_id=pg_temp.note_id('replace')),2,'only arrival and checkout events');
select is((select count(*)::int from public.location_observations where work_session_id=pg_temp.note_id('replace')),2,'both evidence records retained');
select ok((select s.ended_at=e.server_accepted_at and e.device_observed_at=c.observed and o.device_observed_at=c.observed
  and o.session_event_id=e.id and o.observation_type='checkout_location'
  from public.work_sessions s join public.session_events e on e.work_session_id=s.id and e.event_type='manual_checkout'
  join public.location_observations o on o.session_event_id=e.id cross join note_clock c
  where s.id=pg_temp.note_id('replace')),'checkout timestamps and evidence links unchanged');
insert into note_results values ('replace_snapshot',(select to_jsonb(s) from public.work_sessions s where id=pg_temp.note_id('replace')));
select is(pg_temp.note_finish(pg_temp.note_id('replace'),'notes-replace-out-001','replace','Final business note 🚧',true)->>'status',
  'idempotent_replay','successful final-note replay acknowledged');
select is(pg_temp.note_finish(pg_temp.note_id('replace'),'notes-replace-out-001','replace','Final business note 🚧')->>'event_id',
  (select result->>'event_id' from note_results where label='replace_out'),'ordinary retry returns original event');
select is((select to_jsonb(s) from public.work_sessions s where id=pg_temp.note_id('replace')),
  (select result from note_results where label='replace_snapshot'),'replay changes no session field, note or updated_at');
select is((select count(*)::int from public.session_events where work_session_id=pg_temp.note_id('replace')),2,'replay adds no event');
select is((select count(*)::int from public.location_observations where work_session_id=pg_temp.note_id('replace')),2,'replay adds no observation');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('replace'),'notes-replace-out-001','replace','Changed final note',true)$$,
  '23505','idempotency_key_conflict','changed final-note text conflicts');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('replace'),'notes-replace-out-001','clear',null,true)$$,
  '23505','idempotency_key_conflict','changed final-note operation conflicts');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('replace'),'notes-replace-out-001','preserve',null,true)$$,
  '23505','idempotency_key_conflict','omitting original replacement intent conflicts');
select throws_ok($$select public.update_employee_note(pg_temp.note_id('replace'),'late edit')$$,
  'P0001','session_not_active','final note cannot be edited after v2 checkout');
select ok(not exists(select 1 from public.session_events where work_session_id=pg_temp.note_id('replace')
  and (notes is not null or metadata::text like '%business note%' or metadata::text like '%Draft not retained%')),
  'neither final nor prior note copied into events');
select ok(not exists(select 1 from public.location_observations where work_session_id=pg_temp.note_id('replace')
  and (raw_metadata::text like '%business note%' or raw_metadata::text like '%Draft not retained%')),
  'note text not copied into location diagnostics');
insert into note_results values ('clear',pg_temp.note_start('notes-clear-in-001'));
select public.update_employee_note(pg_temp.note_id('clear'),'Clear at checkout');
select is(pg_temp.note_finish(pg_temp.note_id('clear'),'notes-clear-out-001','clear')->>'status','closed','final clear and checkout accepted');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('clear')),null::text,'final clear stores NULL');
select is(pg_temp.note_finish(pg_temp.note_id('clear'),'notes-clear-out-001','clear',null,true)->>'status','idempotent_replay','clear replay succeeds without another mutation');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('clear'),'notes-clear-out-001','replace','',true)$$,
  '23505','idempotency_key_conflict','clear differs from empty-string replacement');

insert into note_results values ('invalid',pg_temp.note_start('notes-invalid-in-001'));
select public.update_employee_note(pg_temp.note_id('invalid'),'Unchanged draft');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001','replace',null)$$,
  '22023','invalid_employee_note_operation','replace requires supplied text');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001','preserve','text')$$,
  '22023','invalid_employee_note_operation','text without explicit replacement is rejected');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001','clear','text')$$,
  '22023','invalid_employee_note_operation','clear cannot silently discard supplied text');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001',null)$$,
  '22023','invalid_employee_note_operation','NULL action rejected');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001','edit')$$,
  '22023','invalid_employee_note_operation','unknown action rejected');
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001','replace',repeat('🚧',1001))$$,
  '22023','employee_note_too_long','oversize final Unicode note rejected');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('invalid')),'Unchanged draft','invalid checkout leaves note unchanged');
select is((select lifecycle_status from public.work_sessions where id=pg_temp.note_id('invalid')),'active','invalid checkout leaves session active');
select is((select count(*)::int from public.session_events where idempotency_key='notes-invalid-out-001'),0,'invalid checkout creates no event');
select is(pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-replay-miss-001','replace','Never saved',true)->>'status','not_found','replay-only miss acknowledges no write');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('invalid')),'Unchanged draft','replay-only miss never applies note intent');
select is(pg_temp.note_finish(pg_temp.note_id('invalid'),'notes-invalid-out-001','replace',repeat('🚧',1000))->>'status','closed','1000 Unicode characters accepted at checkout');
select is(char_length((select employee_note from public.work_sessions where id=pg_temp.note_id('invalid'))),1000,'final Unicode note retained in full');

insert into note_results values ('atomic',pg_temp.note_start('notes-atomic-in-001'));
select public.update_employee_note(pg_temp.note_id('atomic'),'Atomic draft');
reset role;
create function pg_temp.reject_final_note() returns trigger language plpgsql as $$
begin
  if new.employee_note='Final atomic fixture' and new.lifecycle_status='closed_manual' then
    raise exception 'fixture_note_failure' using errcode='P0001';
  end if;
  return new;
end;
$$;
create trigger notes_atomic_failure after update on public.work_sessions for each row execute function pg_temp.reject_final_note();
set local role authenticated;
select throws_ok($$select pg_temp.note_finish(pg_temp.note_id('atomic'),'notes-atomic-out-001','replace','Final atomic fixture')$$,
  'P0001','fixture_note_failure','failure after final update aborts whole checkout');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('atomic')),'Atomic draft','failed transaction restores prior note');
select ok((select lifecycle_status='active' and ended_at is null and check_out_idempotency_key is null and check_out_request_hash is null
  from public.work_sessions where id=pg_temp.note_id('atomic')),'failed transaction rolls back closure and command receipt');
select is((select count(*)::int from public.session_events where idempotency_key='notes-atomic-out-001'),0,'failed final update rolls back checkout event');
select is((select count(*)::int from public.location_observations where work_session_id=pg_temp.note_id('atomic')),1,'failed final update rolls back departure evidence');
reset role;
drop trigger notes_atomic_failure on public.work_sessions;
set local role authenticated;
select is(pg_temp.note_finish(pg_temp.note_id('atomic'),'notes-atomic-out-001','replace','Final atomic fixture')->>'status','closed','exact retry succeeds after transient failure removed');
insert into note_results values ('no_gps',pg_temp.note_start('notes-no-gps-in-001'));
select is(pg_temp.note_finish(pg_temp.note_id('no_gps'),'notes-no-gps-out-001','replace','Location-independent business note',false,
  '{"latitude":null,"longitude":null,"accuracy":null,"fix_at":null,"permission":"denied","services":false,"result":"permission_denied"}')->>'status',
  'closed','missing GPS does not block final note and authorized manual checkout');
select is((select employee_note from public.work_sessions where id=pg_temp.note_id('no_gps')),'Location-independent business note','general note independent of technical location reason');
select is((select review_status from public.work_sessions where id=pg_temp.note_id('no_gps')),'anomaly_open','insufficient departure evidence still opens review');
select is((select reason_code from public.session_events where idempotency_key='notes-no-gps-out-001'),'permission_denied','technical reason remains separate from employee note');
reset role;
select is((select count(*)::int from public.admin_audit_events),0,'no note-edit audit records accumulated');
select is((select count(*)::int from public.session_events where event_type not in ('check_in','manual_checkout')),0,'no note-edit or correction events accumulated');
do $$ begin execute (select definition from note_gate); end $$;
select is(private.attendance_write_contract(),1,'suite restores legacy gate before rollback');
select * from finish();
rollback;
