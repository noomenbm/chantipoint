-- Local pgTAP only. Fictional fixtures, original legacy bodies and wrappers;
-- nothing is committed, no gate replacement, no hosted RPCs or data cleanup.
begin;
set local statement_timeout = '30s';
set local lock_timeout = '5s';
create extension if not exists pgtap with schema extensions;
select no_plan();

select is(private.attendance_write_contract(), 1, 'schema deployment retains legacy mode');

create temporary table compatibility_fixture as
select n, gen_random_uuid() as auth_id, gen_random_uuid() as profile_id,
  case when n < 3 then c.first_company else c.other_company end as company_id
from generate_series(1, 3) n
cross join (select gen_random_uuid() first_company, gen_random_uuid() other_company) c;
insert into auth.users(id, aud, role, email, encrypted_password, email_confirmed_at)
select auth_id, 'authenticated', 'authenticated', 'compatibility.' || n || '@example.test',
  'not-a-password', statement_timestamp() from compatibility_fixture;
insert into public.companies(id, name)
select distinct company_id, 'Fictional schema compatibility company' from compatibility_fixture;
insert into public.user_profiles(id, auth_user_id, company_id, display_name, email)
select profile_id, auth_id, company_id, 'Fictional compatibility employee',
  'compatibility.' || n || '@example.test' from compatibility_fixture;
insert into public.role_assignments(user_profile_id, company_id, role)
select profile_id, company_id, 'employee' from compatibility_fixture;
create temporary table compatibility_results(label text primary key, receipt jsonb not null);
create temporary table compatibility_snapshots(label text primary key, session_row jsonb not null);
grant select on compatibility_fixture, compatibility_snapshots to authenticated;
grant select, insert on compatibility_results to authenticated;

-- Seed through the preserved initial bodies, representing accepted old-client
-- commands. This is an end-state compatibility test, not a DDL upgrade rehearsal.
select set_config('request.jwt.claim.sub', (select auth_id::text from compatibility_fixture where n=1), true);
select set_config('request.jwt.claim.role', 'authenticated', true);
insert into compatibility_results values ('old_closed_in',
  private.check_in_legacy_impl('factory', 'Ancien atelier', null, 'compat-old-closed-in'));
insert into compatibility_results values ('old_closed_out', private.check_out_legacy_impl(
  (select (receipt->>'session_id')::uuid from compatibility_results where label='old_closed_in'),
  'compat-old-closed-out', null));
insert into compatibility_results values ('old_active_in',
  private.check_in_legacy_impl('factory', 'Atelier déjà actif', null, 'compat-old-active-in'));
insert into compatibility_snapshots
select case lifecycle_status when 'active' then 'active' else 'closed' end, to_jsonb(s)
from public.work_sessions s where employee_profile_id=(select profile_id from compatibility_fixture where n=1);

set local role authenticated;
select throws_ok($$select private.check_in_legacy_impl('factory',null,null,'compat-private-denied')$$,
  '42501', null::text, 'clients cannot bypass the compatibility wrappers');
select is(public.check_in('factory','Atelier déjà actif',null,'compat-old-active-in'),
  (select receipt || '{"status":"idempotent_replay"}'::jsonb from compatibility_results where label='old_active_in'),
  'pending original active check-in replays with the complete original receipt');
select is(public.check_out(
  (select (receipt->>'session_id')::uuid from compatibility_results where label='old_closed_in'),
  'compat-old-closed-out',null),
  (select receipt || '{"status":"idempotent_replay"}'::jsonb from compatibility_results where label='old_closed_out'),
  'pending original checkout replays with the complete original receipt');
select is(public.check_in('factory','Ancien atelier',null,'compat-old-closed-in'),
  (select receipt || '{"status":"idempotent_replay"}'::jsonb from compatibility_results where label='old_closed_out'),
  'original check-in replay on a closed session returns its current authoritative state');
select ok(not exists(
  select 1 from compatibility_snapshots b
  join public.work_sessions s on s.id=(b.session_row->>'id')::uuid
  where to_jsonb(s) is distinct from b.session_row),
  'replays leave complete rows, timestamps, hashes, notes and review state unchanged');
select throws_ok($$select public.check_in('factory','Changed',null,'compat-old-active-in')$$,
  '23505','idempotency_key_conflict','original keys do not authorize a changed payload');
select throws_ok($$select public.check_in_v2(p_idempotency_key=>'compat-v2-blocked-in')$$,
  'P0001','attendance_contract_not_enabled','new v2 check-in stays disabled at gate 1');
select throws_ok($$select public.check_out_v2(
  p_work_session_id=>(select (receipt->>'session_id')::uuid from compatibility_results where label='old_active_in'),
  p_idempotency_key=>'compat-v2-blocked-out')$$,
  'P0001','attendance_contract_not_enabled','new v2 checkout stays disabled at gate 1');
select is((select count(*)::integer from public.work_sessions),2,'denied v2 attempts add no sessions');

-- The normal History projection, owner/role join and ordering remain valid.
select is((select count(*)::integer from public.user_profiles p
  join public.role_assignments r on r.user_profile_id=p.id and r.company_id=p.company_id
  join public.work_sessions s on s.employee_profile_id=p.id and s.company_id=p.company_id
  where p.auth_user_id=auth.uid() and p.status='active' and r.role='employee' and r.status='active'),
  2,'authorized History joins still include both active and closed legacy sessions');
select lives_ok($$select s.id,s.employee_profile_id,s.company_id,s.location_context,
  s.lifecycle_status,s.started_at,s.ended_at,s.site_description
  from public.work_sessions s where s.company_id=(select company_id from compatibility_fixture where n=1)
  and s.employee_profile_id=(select profile_id from compatibility_fixture where n=1)
  and s.started_at >= statement_timestamp()-interval '6 months'
  and s.started_at < statement_timestamp()+interval '1 day'
  order by s.started_at desc,s.id desc limit 21$$,
  'baseline History columns, bounded ordering and timestamp predicates remain queryable');
select ok((select bool_and(employee_note is null and review_status='normal') from public.work_sessions),
  'legacy records have no invented note or v2 review/classification evidence');
select throws_ok($$update public.work_sessions set employee_note='bypass'$$,
  '42501',null::text,'schema additions do not enable direct client writes');

insert into compatibility_results values ('old_active_out',public.check_out(
  (select (receipt->>'session_id')::uuid from compatibility_results where label='old_active_in'),
  'compat-old-active-out',null));
select is((select receipt->>'status' from compatibility_results where label='old_active_out'),
  'closed','an existing active legacy session still closes through the wrapper');
select is((select array_agg(k order by k) from compatibility_results,
  lateral jsonb_object_keys(receipt) k where label='old_active_out'),
  array['ended_at','lifecycle_status','location_context','session_id','started_at','status']::text[],
  'legacy acknowledgements retain exactly the original six fields');
select is((select s.check_in_request_hash from public.work_sessions s
  where s.id=(select (receipt->>'session_id')::uuid from compatibility_results where label='old_active_in')),
  (select session_row->>'check_in_request_hash' from compatibility_snapshots where label='active'),
  'checkout preserves the original check-in request hash');
select is((select s.started_at from public.work_sessions s
  where s.id=(select (receipt->>'session_id')::uuid from compatibility_results where label='old_active_in')),
  (select (session_row->>'started_at')::timestamptz from compatibility_snapshots where label='active'),
  'checkout preserves the original UTC start instant');
insert into compatibility_results values ('new_in',public.check_in('factory','Nouvel atelier',null,'compat-new-in'));
select is((select receipt->>'status' from compatibility_results where label='new_in'),
  'created','new legacy check-in is still accepted');
insert into compatibility_results values ('new_out',public.check_out(
  (select (receipt->>'session_id')::uuid from compatibility_results where label='new_in'),'compat-new-out',null));
select is((select receipt->>'status' from compatibility_results where label='new_out'),
  'closed','new legacy checkout is still accepted');
select is((select count(*)::integer from public.location_observations),0,'legacy factory attendance remains GPS-free');

-- Keep the external-worksite legacy semantics, without any real location.
select throws_ok($$select public.check_in('external_worksite','Fictional site',null,'compat-external-no-fix')$$,
  'P0001','external_worksite_location_required_pending_policy','legacy external check-in still requires location');
insert into compatibility_results values ('external_in',public.check_in(
  'external_worksite','Fictional site',null,'compat-external-in',0,0,10,'emulator'));
insert into compatibility_results values ('external_out',public.check_out(
  (select (receipt->>'session_id')::uuid from compatibility_results where label='external_in'),
  'compat-external-out',null,0,0,10,'emulator'));
select is((select receipt->>'location_context' from compatibility_results where label='external_out'),
  'external_worksite','legacy external classification is not rewritten by v2');
select is((select count(*)::integer from public.location_observations),2,'legacy external evidence still works');

select set_config('request.jwt.claim.sub',(select auth_id::text from compatibility_fixture where n=2),true);
select is((select count(*)::integer from public.work_sessions),0,'same-company colleague cannot see owner History');
select set_config('request.jwt.claim.sub',(select auth_id::text from compatibility_fixture where n=3),true);
select is((select count(*)::integer from public.work_sessions),0,'other-company employee cannot see owner History');
select throws_ok($$select public.check_out(
  (select (receipt->>'session_id')::uuid from compatibility_results where label='external_in'),
  'compat-foreign-out',null)$$,'42501','active_session_not_found_for_employee','foreign checkout remains denied');
reset role;
select is((select count(*)::integer from private.employee_note_operations
  where employee_profile_id in (select profile_id from compatibility_fixture)),
  0,'attendance compatibility creates no note operations');
select is(private.attendance_write_contract(),1,'test never changes the deployment gate');
select * from finish();
rollback;
