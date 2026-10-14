begin;

create extension if not exists pgtap with schema extensions;

select no_plan();

select has_table('public', 'companies', 'companies table exists');
select has_table('public', 'user_profiles', 'user_profiles table exists');
select has_table('public', 'role_assignments', 'role_assignments table exists');
select has_table('public', 'work_sessions', 'work_sessions table exists');
select has_table('public', 'session_events', 'session_events table exists');
select has_table('public', 'location_observations', 'location_observations table exists');
select has_table('public', 'admin_audit_events', 'admin_audit_events table exists');

select ok(
  (select relrowsecurity from pg_class where oid = 'public.work_sessions'::regclass),
  'work_sessions has RLS enabled'
);

select ok(
  (select relrowsecurity from pg_class where oid = 'public.admin_audit_events'::regclass),
  'admin_audit_events has RLS enabled'
);

select ok(
  exists (
    select 1
    from pg_indexes
    where schemaname = 'public'
      and tablename = 'work_sessions'
      and indexname = 'work_sessions_one_active_per_employee'
  ),
  'database has one-active-session protection'
);

insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('10000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'employee.a@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('10000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'employee.b@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('10000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'admin.a@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('10000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'employee.other@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('10000000-0000-0000-0000-000000000005', 'authenticated', 'authenticated', 'admin.b@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp());

insert into public.companies (id, name)
values
  ('20000000-0000-0000-0000-000000000001', 'JMService'),
  ('20000000-0000-0000-0000-000000000002', 'Other Test Company');

insert into public.user_profiles (id, auth_user_id, company_id, employee_number, display_name, email)
values
  ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'A-001', 'Employee A', 'employee.a@example.test'),
  ('30000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'B-001', 'Employee B', 'employee.b@example.test'),
  ('30000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'ADM-001', 'Admin A', 'admin.a@example.test'),
  ('30000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'O-001', 'Other Employee', 'employee.other@example.test'),
  ('30000000-0000-0000-0000-000000000005', '10000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001', 'ADM-002', 'Admin B', 'admin.b@example.test');

insert into public.role_assignments (user_profile_id, company_id, role)
values
  ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'employee'),
  ('30000000-0000-0000-0000-000000000002', '20000000-0000-0000-0000-000000000001', 'employee'),
  ('30000000-0000-0000-0000-000000000003', '20000000-0000-0000-0000-000000000001', 'administrator'),
  ('30000000-0000-0000-0000-000000000004', '20000000-0000-0000-0000-000000000002', 'employee'),
  ('30000000-0000-0000-0000-000000000005', '20000000-0000-0000-0000-000000000001', 'administrator');

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$select public.check_in('factory', 'Factory floor', null, 'employee-a-factory-in-001')$$,
  'factory employee can check in without GPS'
);

select is(
  (select count(*)::int from public.work_sessions where lifecycle_status = 'active'),
  1,
  'factory check-in creates one visible active session'
);

select is(
  (select count(*)::int from public.location_observations),
  0,
  'factory check-in creates no location observation rows'
);

select is(
  (select public.check_in('factory', 'Factory floor', null, 'employee-a-factory-in-001')->>'status'),
  'idempotent_replay',
  'duplicate check-in with the same idempotency key is replayed'
);

select throws_ok(
  $$select public.check_in('factory', 'Different factory floor', null, 'employee-a-factory-in-001')$$,
  '23505',
  'idempotency_key_conflict',
  'conflicting check-in idempotency-key reuse is rejected'
);

select throws_ok(
  $$select public.check_in('factory', 'Second active session', null, 'employee-a-factory-in-002')$$,
  '23505',
  'active_session_exists',
  'simultaneous active check-in is rejected'
);

select lives_ok(
  $$select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-a-factory-in-001'), 'employee-a-factory-out-001', null)$$,
  'factory employee can check out without GPS'
);

select is(
  (select count(*)::int from public.work_sessions where lifecycle_status = 'active'),
  0,
  'factory checkout closes the active session'
);

select is(
  (select count(*)::int from public.session_events where event_type = 'manual_checkout'),
  1,
  'manual checkout creates an auditable event'
);

select is(
  (select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-a-factory-in-001'), 'employee-a-factory-out-001', null)->>'status'),
  'idempotent_replay',
  'duplicate checkout with the same idempotency key is replayed'
);

select throws_ok(
  $$select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-a-factory-in-001'), 'employee-a-factory-out-001', '2026-10-12 12:00:00+00'::timestamptz)$$,
  '23505',
  'idempotency_key_conflict',
  'conflicting checkout idempotency-key reuse is rejected'
);

select lives_ok(
  $$select public.check_in('factory', 'Afternoon factory floor', null, 'employee-a-factory-in-003')$$,
  'employee can start a second non-overlapping session in the same day'
);

select throws_ok(
  $$select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-a-factory-in-003'), 'employee-a-factory-out-001', null)$$,
  '23505',
  'idempotency_key_conflict',
  'checkout idempotency key cannot be reused for a different session'
);

reset role;

select throws_ok(
  $$insert into public.work_sessions (
      employee_profile_id,
      company_id,
      location_context,
      lifecycle_status,
      review_status,
      current_monitoring_status,
      check_in_idempotency_key,
      check_in_request_hash
    )
    values (
      '30000000-0000-0000-0000-000000000001',
      '20000000-0000-0000-0000-000000000001',
      'factory',
      'active',
      'normal',
      'not_applicable',
      'employee-a-direct-in-001',
      repeat('0', 64)
    )$$,
  '23505',
  'duplicate key value violates unique constraint "work_sessions_one_active_per_employee"',
  'database-level unique index rejects a concurrent second active session'
);

select throws_ok(
  $$insert into public.location_observations (
      work_session_id,
      employee_profile_id,
      company_id,
      observation_type,
      latitude,
      longitude,
      accuracy_meters,
      provider
    )
    select id,
           employee_profile_id,
           company_id,
           'check_in_location',
           45.501700,
           -73.567300,
           12.0,
           'gps'
      from public.work_sessions
     where check_in_idempotency_key = 'employee-a-factory-in-003'$$,
  '23514',
  'location_observation_requires_external_worksite',
  'factory sessions cannot receive location observations'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$select public.check_in('external_worksite', 'Fictional jobsite', null, 'employee-b-external-in-001', 45.501700, -73.567300, 9.5, 'gps')$$,
  'external-worksite employee can check in with coordinates'
);

select is(
  (select count(*)::int from public.location_observations where observation_type = 'check_in_location'),
  1,
  'external-worksite check-in records one location observation'
);

select lives_ok(
  $$select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-b-external-in-001'), 'employee-b-external-out-001', null, 45.501800, -73.567400, 10.0, 'gps')$$,
  'external-worksite employee can check out with coordinates'
);

select is(
  (select count(*)::int from public.location_observations where observation_type = 'checkout_location'),
  1,
  'external-worksite checkout can record one location observation'
);

select throws_ok(
  $$select public.check_in('external_worksite', 'Missing GPS', null, 'employee-b-external-in-002')$$,
  'P0001',
  'external_worksite_location_required_pending_policy',
  'external-worksite check-in without coordinates is explicitly blocked pending policy'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000004', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$select public.check_in('factory', 'Other company factory', null, 'other-company-in-001')$$,
  'other company employee can create isolated test data'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.work_sessions where employee_profile_id = '30000000-0000-0000-0000-000000000002'),
  0,
  'employee A cannot read employee B sessions'
);

select throws_ok(
  $$update public.work_sessions
       set site_description = 'unauthorized change'
     where employee_profile_id = '30000000-0000-0000-0000-000000000002'$$,
  '42501',
  'permission denied for table work_sessions',
  'employee A cannot modify employee B sessions'
);

select throws_ok(
  $$insert into public.role_assignments (user_profile_id, company_id, role)
    values ('30000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'administrator')$$,
  '42501',
  'permission denied for table role_assignments',
  'employee cannot assign themself administrator'
);

select throws_ok(
  $$select public.check_out('00000000-0000-0000-0000-000000000000'::uuid, 'employee-a-invalid-out-001', null)$$,
  '42501',
  'active_session_not_found_for_employee',
  'employee cannot check out a missing or unowned session'
);

select throws_ok(
  $$insert into public.session_events (
      work_session_id,
      employee_profile_id,
      company_id,
      event_type,
      source
    )
    select id,
           employee_profile_id,
           company_id,
           'manual_checkout',
           'employee_app'
      from public.work_sessions
     where check_in_idempotency_key = 'employee-a-factory-in-003'$$,
  '42501',
  'permission denied for table session_events',
  'employee cannot forge historical attendance events through direct table writes'
);

select is(
  (select count(*)::int from public.admin_audit_events),
  0,
  'employee cannot read administrative audit records'
);

select throws_ok(
  $$insert into public.admin_audit_events (
      company_id,
      actor_profile_id,
      action,
      target_profile_id
    )
    values (
      '20000000-0000-0000-0000-000000000001',
      '30000000-0000-0000-0000-000000000001',
      'user_profile_disabled',
      '30000000-0000-0000-0000-000000000002'
    )$$,
  '42501',
  'permission denied for table admin_audit_events',
  'employee cannot forge administrative audit records'
);

select throws_ok(
  $$update public.admin_audit_events
       set action_details = '{"tampered": true}'::jsonb$$,
  '42501',
  'permission denied for table admin_audit_events',
  'employee cannot modify administrative audit records'
);

select throws_ok(
  $$delete from public.admin_audit_events$$,
  '42501',
  'permission denied for table admin_audit_events',
  'employee cannot delete administrative audit records'
);

reset role;

update public.companies
   set status = 'suspended'
 where id = '20000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$select public.check_in('factory', 'Suspended company factory', null, 'employee-b-suspended-in-001')$$,
  'P0001',
  'company_not_active',
  'suspended company cannot start new sessions'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select lives_ok(
  $$select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-a-factory-in-003'), 'employee-a-factory-out-003', null)$$,
  'authorized employee can check out an existing active session after company suspension'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select public.revoke_role_assignment(
    (select id
       from public.role_assignments
      where user_profile_id = '30000000-0000-0000-0000-000000000005'
        and role = 'administrator')
  )->>'status'),
  'revoked',
  'with two administrators, one administrator may be revoked while one remains active'
);

select is(
  (select count(*)::int from public.admin_audit_events),
  1,
  'successful administrator role revocation records one audit event'
);

select is(
  (
    select action
      from public.admin_audit_events
     where target_profile_id = '30000000-0000-0000-0000-000000000005'
  ),
  'role_assignment_revoked',
  'role-revocation audit event records the action'
);

select is(
  (
    select actor_profile_id::text
      from public.admin_audit_events
     where target_profile_id = '30000000-0000-0000-0000-000000000005'
  ),
  '30000000-0000-0000-0000-000000000003',
  'role-revocation audit event records the acting administrator'
);

select is(
  (
    select target_role_assignment_id::text
      from public.admin_audit_events
     where target_profile_id = '30000000-0000-0000-0000-000000000005'
  ),
  (
    select id::text
      from public.role_assignments
     where user_profile_id = '30000000-0000-0000-0000-000000000005'
       and role = 'administrator'
  ),
  'role-revocation audit event records the target role assignment'
);

select is(
  (
    select action_details->>'role'
      from public.admin_audit_events
     where target_profile_id = '30000000-0000-0000-0000-000000000005'
  ),
  'administrator',
  'role-revocation audit event records minimal role detail'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000005', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.work_sessions where employee_profile_id = '30000000-0000-0000-0000-000000000001'),
  0,
  'revoked administrator cannot read colleagues records'
);

select is(
  (select count(*)::int from public.admin_audit_events),
  0,
  'revoked administrator cannot read company audit records'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select throws_ok(
  $$select public.revoke_role_assignment(
      (select id
         from public.role_assignments
        where user_profile_id = '30000000-0000-0000-0000-000000000003'
          and role = 'administrator')
    )$$,
  '23514',
  'last_active_administrator_required',
  'last active administrator cannot revoke their own administrator role'
);

select throws_ok(
  $$select public.disable_user_profile('30000000-0000-0000-0000-000000000003')$$,
  '23514',
  'last_active_administrator_required',
  'last active administrator cannot be disabled through normal administrative operation'
);

select is(
  (select count(*)::int from public.admin_audit_events),
  1,
  'failed last-active-administrator operations do not create successful-action audit entries'
);

select is(
  (select public.revoke_role_assignment(
    (select id
       from public.role_assignments
      where user_profile_id = '30000000-0000-0000-0000-000000000001'
        and role = 'employee')
  )->>'status'),
  'revoked',
  'administrator can revoke an employee role without deleting historical sessions'
);

select is(
  (select count(*)::int from public.admin_audit_events where action = 'role_assignment_revoked'),
  2,
  'second successful role revocation appends a new audit event'
);

select is(
  (
    select count(*)::int
      from public.admin_audit_events
     where action = 'role_assignment_revoked'
       and target_profile_id = '30000000-0000-0000-0000-000000000001'
       and action_details->>'role' = 'employee'
  ),
  1,
  'employee role-revocation audit event preserves the target and role detail'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.work_sessions),
  0,
  'revoked employee role cannot read historical attendance'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select public.disable_user_profile('30000000-0000-0000-0000-000000000002')->>'status'),
  'disabled',
  'administrator can disable an employee profile without deleting historical sessions'
);

select is(
  (select count(*)::int from public.admin_audit_events where action = 'user_profile_disabled'),
  1,
  'successful profile disable records one audit event'
);

select is(
  (
    select count(*)::int
      from public.admin_audit_events
     where action = 'user_profile_disabled'
       and target_profile_id = '30000000-0000-0000-0000-000000000002'
       and action_details->>'previous_status' = 'active'
  ),
  1,
  'profile-disable audit event records the target profile and minimal status detail'
);

select is(
  (select count(*)::int from public.admin_audit_events),
  3,
  'profile disable preserves prior administrative audit records'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000002', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  (select count(*)::int from public.work_sessions),
  0,
  'disabled profile loses protected attendance access'
);

select is(
  (select count(*)::int from public.admin_audit_events),
  0,
  'disabled profile cannot read administrative audit records'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select ok(
  (select count(*) from public.work_sessions where employee_profile_id in (
    '30000000-0000-0000-0000-000000000001',
    '30000000-0000-0000-0000-000000000002'
  )) >= 3,
  'active administrator can still review historical records of former employees'
);

reset role;

select throws_ok(
  $$update public.admin_audit_events
       set action_details = '{"tampered": true}'::jsonb
     where id = (select id from public.admin_audit_events limit 1)$$,
  '23514',
  'admin_audit_events_append_only',
  'administrative audit events cannot be updated after creation'
);

select throws_ok(
  $$delete from public.admin_audit_events
     where id = (select id from public.admin_audit_events limit 1)$$,
  '23514',
  'admin_audit_events_append_only',
  'administrative audit events cannot be deleted after creation'
);

reset role;
set local role anon;
select set_config('request.jwt.claim.sub', '', true);
select set_config('request.jwt.claim.role', 'anon', true);

select throws_ok(
  $$select count(*) from public.work_sessions$$,
  '42501',
  'permission denied for table work_sessions',
  'anonymous users cannot read employee attendance records'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '10000000-0000-0000-0000-000000000003', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select ok(
  (select count(*) from public.work_sessions where company_id = '20000000-0000-0000-0000-000000000001') >= 2,
  'administrator can read sessions for their company'
);

select is(
  (select count(*)::int from public.work_sessions where company_id = '20000000-0000-0000-0000-000000000002'),
  0,
  'administrator cannot read sessions for another company'
);

select throws_ok(
  $$select public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'employee-b-external-in-001'), 'admin-invalid-out-001', null)$$,
  '42501',
  'employee_role_required',
  'administrator role alone cannot perform employee checkout RPC'
);

select * from finish();

rollback;
