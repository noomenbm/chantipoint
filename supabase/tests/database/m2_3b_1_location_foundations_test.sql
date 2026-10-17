begin;

create extension if not exists pgtap with schema extensions;
select no_plan();

-- Fictional, rollback-only fixtures. Coordinates/radii below test constraints;
-- they are not JMService configuration or classification policy.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at, created_at, updated_at)
values
  ('71000000-0000-0000-0000-000000000001', 'authenticated', 'authenticated', 'foundation.employee@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('71000000-0000-0000-0000-000000000002', 'authenticated', 'authenticated', 'foundation.colleague@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('71000000-0000-0000-0000-000000000003', 'authenticated', 'authenticated', 'foundation.other@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp()),
  ('71000000-0000-0000-0000-000000000004', 'authenticated', 'authenticated', 'foundation.admin@example.test', 'not-a-real-password', statement_timestamp(), statement_timestamp(), statement_timestamp());

insert into public.companies (id, name)
values
  ('72000000-0000-0000-0000-000000000001', 'Foundation Test Company'),
  ('72000000-0000-0000-0000-000000000002', 'Other Foundation Test Company');

insert into public.user_profiles (id, auth_user_id, company_id, display_name, email)
values
  ('73000000-0000-0000-0000-000000000001', '71000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'Foundation Employee', 'foundation.employee@example.test'),
  ('73000000-0000-0000-0000-000000000002', '71000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', 'Foundation Colleague', 'foundation.colleague@example.test'),
  ('73000000-0000-0000-0000-000000000003', '71000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'Other Foundation Employee', 'foundation.other@example.test'),
  ('73000000-0000-0000-0000-000000000004', '71000000-0000-0000-0000-000000000004', '72000000-0000-0000-0000-000000000001', 'Foundation Administrator', 'foundation.admin@example.test');

insert into public.role_assignments (user_profile_id, company_id, role)
values
  ('73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'employee'),
  ('73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', 'employee'),
  ('73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'employee'),
  ('73000000-0000-0000-0000-000000000004', '72000000-0000-0000-0000-000000000001', 'administrator');

-- Optional, all-or-none factory configuration, with no seeded defaults.
select is(
  (select jsonb_build_array(factory_latitude, factory_longitude, factory_radius_meters)
     from public.companies where id = '72000000-0000-0000-0000-000000000001'),
  '[null, null, null]'::jsonb,
  'new company factory configuration defaults to all NULL'
);

select lives_ok(
  $$update public.companies set factory_latitude = 0, factory_longitude = 0, factory_radius_meters = 1
     where id = '72000000-0000-0000-0000-000000000001'$$,
  'complete synthetic factory configuration is accepted'
);

select lives_ok(
  $$update public.companies set factory_latitude = 90, factory_longitude = 180
     where id = '72000000-0000-0000-0000-000000000001'$$,
  'positive coordinate boundaries are accepted'
);

select lives_ok(
  $$update public.companies set factory_latitude = -90, factory_longitude = -180
     where id = '72000000-0000-0000-0000-000000000001'$$,
  'negative coordinate boundaries are accepted'
);

select throws_ok(
  format(
    'update public.companies set factory_latitude = %s, factory_longitude = %s, factory_radius_meters = %s where id = %L',
    coalesce(latitude::text, 'null'), coalesce(longitude::text, 'null'), coalesce(radius::text, 'null'),
    '72000000-0000-0000-0000-000000000001'
  ),
  '23514',
  'new row for relation "companies" violates check constraint "companies_factory_configuration_complete_check"',
  description
)
from (values
  (0::numeric, null::numeric, null::integer, 'latitude alone is rejected'),
  (null, 0, null, 'longitude alone is rejected'),
  (null, null, 1, 'radius alone is rejected'),
  (0, 0, null, 'coordinates without radius are rejected'),
  (0, null, 1, 'latitude/radius without longitude are rejected'),
  (null, 0, 1, 'longitude/radius without latitude are rejected')
) as cases(latitude, longitude, radius, description);

select throws_ok(
  format(
    'update public.companies set factory_latitude = %s, factory_longitude = %s, factory_radius_meters = %s where id = %L',
    latitude, longitude, radius, '72000000-0000-0000-0000-000000000001'
  ),
  '23514',
  format('new row for relation "companies" violates check constraint "%s"', constraint_name),
  description
)
from (values
  (90.000001::numeric, 0::numeric, 1, 'companies_factory_latitude_range_check', 'latitude above 90 is rejected'),
  (-90.000001, 0, 1, 'companies_factory_latitude_range_check', 'latitude below -90 is rejected'),
  (0, 180.000001, 1, 'companies_factory_longitude_range_check', 'longitude above 180 is rejected'),
  (0, -180.000001, 1, 'companies_factory_longitude_range_check', 'longitude below -180 is rejected'),
  (0, 0, 0, 'companies_factory_radius_positive_check', 'zero radius is rejected'),
  (0, 0, -1, 'companies_factory_radius_positive_check', 'negative radius is rejected')
) as cases(latitude, longitude, radius, constraint_name, description);

select lives_ok(
  $$update public.companies set factory_latitude = null, factory_longitude = null, factory_radius_meters = null
     where id = '72000000-0000-0000-0000-000000000001'$$,
  'factory configuration can be cleared as a complete nullable group'
);

-- Existing RPC behavior and response shape are intentionally retained.
set local role authenticated;
select set_config('request.jwt.claim.sub', '71000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);

select is(
  public.check_in('factory', null, null, 'foundation-legacy-in-001')->>'status',
  'created',
  'legacy factory check-in still works without configured factory coordinates'
);

select is(
  (select array_agg(key order by key) from jsonb_object_keys(
    public.check_in('factory', null, null, 'foundation-legacy-in-001')
  ) as response(key)),
  array['ended_at', 'lifecycle_status', 'location_context', 'session_id', 'started_at', 'status']::text[],
  'legacy RPC replay retains exactly the six M2.3a acknowledgement fields'
);

select is((select count(*)::int from public.session_events), 1, 'legacy replay does not duplicate its attendance event');
select is((select count(*)::int from public.location_observations), 0, 'legacy factory RPC still creates no GPS observations');
select is((select employee_note from public.work_sessions), null::text, 'legacy check-in leaves the new employee note NULL');

select throws_ok(
  $$select public.check_in('location_unverified', null, null, 'foundation-new-context-001')$$,
  '22023', 'invalid_location_context',
  'schema expansion does not enable client-selected location_unverified in the legacy RPC'
);
select throws_ok(
  $$select public.check_in('factory', null, null, 'foundation-factory-gps-001', 0, 0, 1, 'emulator')$$,
  '22023', 'factory_location_not_allowed',
  'legacy factory RPC location restriction remains until its coordinated replacement'
);

reset role;

select lives_ok(
  format('update public.work_sessions set location_context = %L where check_in_idempotency_key = %L',
    context, 'foundation-legacy-in-001'),
  format('trusted schema writes accept %s context', context)
)
from (values ('factory'), ('external_worksite'), ('location_unverified')) as cases(context);

select throws_ok(
  $$update public.work_sessions set location_context = 'unsupported' where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '23514',
  'new row for relation "work_sessions" violates check constraint "work_sessions_location_context_check"',
  'unsupported location context remains rejected'
);
update public.work_sessions set location_context = 'factory' where check_in_idempotency_key = 'foundation-legacy-in-001';

select lives_ok(
  $$update public.work_sessions set employee_note = null where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  'employee note accepts NULL'
);
select lives_ok(
  $$update public.work_sessions set employee_note = 'Observation générale sur le travail.' where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  'employee note accepts general-purpose employee text'
);
select lives_ok(
  $$update public.work_sessions set employee_note = repeat('é', 1000) where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  'employee note accepts 1000 Unicode characters'
);
select throws_ok(
  $$update public.work_sessions set employee_note = repeat('é', 1001) where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '23514',
  'new row for relation "work_sessions" violates check constraint "work_sessions_employee_note_length_check"',
  'employee note rejects more than 1000 characters'
);
select is(
  (select site_description from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'),
  null::text, 'employee note does not repurpose site_description'
);
select is(
  (select se.notes from public.session_events se join public.work_sessions ws on ws.id = se.work_session_id
    where ws.employee_profile_id = '73000000-0000-0000-0000-000000000001' and ws.check_in_idempotency_key = 'foundation-legacy-in-001'),
  null::text, 'employee note does not overwrite existing event notes'
);

-- Trusted fixtures exercise all contexts and cross-event identity checks.
insert into public.work_sessions (id, employee_profile_id, company_id, location_context, check_in_idempotency_key, check_in_request_hash)
values
  ('74000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', 'external_worksite', 'foundation-colleague-in-001', repeat('0', 64)),
  ('74000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'location_unverified', 'foundation-other-in-001', repeat('0', 64));

insert into public.work_sessions (id, employee_profile_id, company_id, location_context, lifecycle_status, started_at, ended_at, checkout_source, check_in_idempotency_key, check_in_request_hash)
values ('74000000-0000-0000-0000-000000000004', '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'factory', 'closed_manual', statement_timestamp() - interval '2 hours', statement_timestamp() - interval '1 hour', 'manual', 'foundation-closed-in-001', repeat('0', 64));

insert into public.session_events (id, work_session_id, employee_profile_id, company_id, event_type, source)
values
  ('75000000-0000-0000-0000-000000000002', '74000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', 'check_in', 'employee_app'),
  ('75000000-0000-0000-0000-000000000003', '74000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'check_in', 'employee_app'),
  ('75000000-0000-0000-0000-000000000004', '74000000-0000-0000-0000-000000000004', '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'manual_checkout', 'employee_app');

select lives_ok(
  $$insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id, observation_type, latitude, longitude, accuracy_meters, provider)
    select ws.id, se.id, ws.employee_profile_id, ws.company_id, 'check_in_location', 0, 0, 1, 'emulator'
    from public.work_sessions ws join public.session_events se on se.work_session_id = ws.id and se.event_type = 'check_in'
    where ws.check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  'active factory observations retain their same-session evidence relationship'
);
select lives_ok(
  $$insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id, observation_type, latitude, longitude, accuracy_meters, provider)
    values ('74000000-0000-0000-0000-000000000002', '75000000-0000-0000-0000-000000000002', '73000000-0000-0000-0000-000000000002', '72000000-0000-0000-0000-000000000001', 'check_in_location', 0, 0, 1, 'emulator')$$,
  'active external-worksite observations remain accepted'
);
select lives_ok(
  $$insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id, observation_type)
    values ('74000000-0000-0000-0000-000000000003', '75000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'unavailable')$$,
  'active location_unverified session accepts linked unavailable evidence without fabricated coordinates'
);
select lives_ok(
  $$insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id, observation_type, latitude, longitude, accuracy_meters, provider)
    values ('74000000-0000-0000-0000-000000000003', '75000000-0000-0000-0000-000000000003', '73000000-0000-0000-0000-000000000003', '72000000-0000-0000-0000-000000000002', 'check_in_location', 0, 0, 1000, 'emulator')$$,
  'location_unverified can retain a real-shaped but imprecise fix as evidence'
);
select ok(
  not has_function_privilege('authenticated', 'private.validate_location_observation_session()', 'execute'),
  'replacing the private trigger function preserves its restricted execute privileges'
);

select throws_ok(
  $$insert into public.location_observations (work_session_id, employee_profile_id, company_id, observation_type)
    select id, '73000000-0000-0000-0000-000000000002', company_id, 'unavailable' from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '23503', 'location_observation_session_not_found', 'observation cannot use a different employee identity'
);
select throws_ok(
  $$insert into public.location_observations (work_session_id, employee_profile_id, company_id, observation_type)
    select id, employee_profile_id, '72000000-0000-0000-0000-000000000002', 'unavailable' from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '23503', 'location_observation_session_not_found', 'observation cannot use a different company identity'
);
select throws_ok(
  $$insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id, observation_type)
    select id, '75000000-0000-0000-0000-000000000004', employee_profile_id, company_id, 'unavailable' from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '23503',
  'insert or update on table "location_observations" violates foreign key constraint "location_observations_event_identity_fk"',
  'observation cannot link an event from another session even for the same employee/company'
);

select throws_ok(
  format(
    'insert into public.location_observations (work_session_id, employee_profile_id, company_id, observation_type, latitude, longitude, accuracy_meters) select id, employee_profile_id, company_id, %L, %s, %s, %s from public.work_sessions where check_in_idempotency_key = %L',
    observation_type, coalesce(latitude::text, 'null'), coalesce(longitude::text, 'null'), coalesce(accuracy::text, 'null'),
    'foundation-legacy-in-001'
  ),
  '23514', null::text, description
)
from (values
  ('unavailable', 0::numeric, null::numeric, null::numeric, 'partial coordinate pairs remain rejected'),
  ('check_in_location', 90.000001, 0, 1, 'invalid observation latitude remains rejected'),
  ('check_in_location', 0, -180.000001, 1, 'invalid observation longitude remains rejected'),
  ('check_in_location', 0, 0, -1, 'negative observation accuracy remains rejected'),
  ('checkout_location', null, null, null, 'coordinate-bearing observation type still requires coordinates')
) as cases(observation_type, latitude, longitude, accuracy, description);

select throws_ok(
  $$insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id, observation_type)
    values ('74000000-0000-0000-0000-000000000004', '75000000-0000-0000-0000-000000000004', '73000000-0000-0000-0000-000000000001', '72000000-0000-0000-0000-000000000001', 'unavailable')$$,
  '23514', 'location_observation_requires_active_session', 'closed sessions still reject new observations'
);
select throws_ok(
  $$update public.location_observations set work_session_id = '74000000-0000-0000-0000-000000000004', session_event_id = '75000000-0000-0000-0000-000000000004'
    where work_session_id = (select id from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001')$$,
  '23514', 'location_observation_requires_active_session', 'active-session validation also remains effective on observation updates'
);

-- New columns do not widen existing table-write privileges or RLS scope.
set local role authenticated;
select set_config('request.jwt.claim.sub', '71000000-0000-0000-0000-000000000001', true);
select is((select count(*)::int from public.work_sessions where employee_profile_id = '73000000-0000-0000-0000-000000000002'), 0, 'employee cannot read a colleague session or its note');
select is((select count(*)::int from public.work_sessions where company_id = '72000000-0000-0000-0000-000000000002'), 0, 'employee cannot read another company session or its note');
select is((select count(*)::int from public.location_observations), 1, 'employee sees only their own factory evidence');
select is((select count(*)::int from public.companies), 1, 'factory configuration remains company-scoped on reads');

select throws_ok(
  $$update public.companies set factory_latitude = 0, factory_longitude = 0, factory_radius_meters = 1 where id = '72000000-0000-0000-0000-000000000001'$$,
  '42501', 'permission denied for table companies', 'employee cannot modify trusted factory configuration'
);
select throws_ok(
  $$update public.work_sessions set employee_note = 'direct edit' where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '42501', 'permission denied for table work_sessions', 'note column does not grant direct employee writes before the future note RPC'
);
select throws_ok(
  $$update public.work_sessions set location_context = 'location_unverified' where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '42501', 'permission denied for table work_sessions', 'employee cannot directly choose the expanded classification'
);
select throws_ok(
  $$insert into public.location_observations (work_session_id, employee_profile_id, company_id, observation_type)
    select id, employee_profile_id, company_id, 'unavailable' from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '42501', 'permission denied for table location_observations', 'factory observation support does not grant direct client evidence writes'
);

select is(
  public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'), 'foundation-legacy-out-001')->>'status',
  'closed', 'legacy manual checkout still succeeds after the additive migration'
);
select is(
  public.check_out((select id from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'), 'foundation-legacy-out-001')->>'status',
  'idempotent_replay', 'legacy checkout replay remains idempotent'
);
select is(
  (select checkout_reason_code from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'),
  'manual_checkout', 'checkout_reason_code and its legacy RPC writer are retained pending the historical audit'
);
select is(
  (select employee_note from public.work_sessions where check_in_idempotency_key = 'foundation-legacy-in-001'),
  repeat('é', 1000), 'legacy checkout preserves the new employee note'
);
select is((select count(*)::int from public.location_observations), 1, 'legacy factory checkout does not acquire or add GPS evidence');
select throws_ok(
  $$update public.work_sessions set employee_note = 'closed edit' where check_in_idempotency_key = 'foundation-legacy-in-001'$$,
  '42501', 'permission denied for table work_sessions', 'employee direct writes remain denied after checkout'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '71000000-0000-0000-0000-000000000004', true);
select is((select count(*)::int from public.work_sessions), 3, 'administrator can read company sessions including notes');
select is((select count(*)::int from public.location_observations), 2, 'administrator can read company factory and external evidence');
select is((select count(*)::int from public.work_sessions where company_id = '72000000-0000-0000-0000-000000000002'), 0, 'administrator cannot read another company sessions');
select throws_ok(
  $$update public.companies set factory_latitude = 0, factory_longitude = 0, factory_radius_meters = 1 where id = '72000000-0000-0000-0000-000000000001'$$,
  '42501', 'permission denied for table companies', 'administrator client still has no direct configuration write grant'
);

reset role;
update public.user_profiles set status = 'disabled' where id = '73000000-0000-0000-0000-000000000001';
update public.role_assignments set status = 'revoked', revoked_at = statement_timestamp() where user_profile_id = '73000000-0000-0000-0000-000000000002';

set local role authenticated;
select set_config('request.jwt.claim.sub', '71000000-0000-0000-0000-000000000001', true);
select is((select count(*)::int from public.work_sessions), 0, 'disabled employee loses session/note access');
select is((select count(*)::int from public.location_observations), 0, 'disabled employee loses location evidence access');
select set_config('request.jwt.claim.sub', '71000000-0000-0000-0000-000000000002', true);
select is((select count(*)::int from public.work_sessions), 0, 'revoked employee loses session/note access');
select is((select count(*)::int from public.location_observations), 0, 'revoked employee loses location evidence access');

reset role;
select * from finish();
rollback;
