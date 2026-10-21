begin;
create extension if not exists pgtap with schema extensions;
select no_plan();

-- All configuration and fixtures, including simulated cutover, roll back.
insert into auth.users (id, aud, role, email, encrypted_password, email_confirmed_at)
select ('81000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  'authenticated', 'authenticated', 'contract.' || n || '@example.test', 'not-a-password', statement_timestamp()
from generate_series(1, 4) n;
insert into public.companies (id, name) values
  ('82000000-0000-0000-0000-000000000001', 'Fictional Contract Factory'),
  ('82000000-0000-0000-0000-000000000002', 'Other Fictional Contract Company');
insert into public.user_profiles (id, auth_user_id, company_id, display_name, email)
select ('83000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  ('81000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
  case when n = 2 then '82000000-0000-0000-0000-000000000002'::uuid else '82000000-0000-0000-0000-000000000001'::uuid end,
  'Fictional Contract User ' || n, 'contract.' || n || '@example.test'
from generate_series(1, 4) n;
insert into public.role_assignments (user_profile_id, company_id, role)
select id, company_id, case when email = 'contract.4@example.test' then 'administrator' else 'employee' end
from public.user_profiles where id::text like '83000000-%';

create temporary table contract_base (payload jsonb not null);
insert into contract_base values (jsonb_build_object(
  'action_at', statement_timestamp(), 'fix_at', statement_timestamp() - interval '5 seconds',
  'latitude', 0, 'longitude', 0.0001, 'accuracy', 10,
  'permission', 'precise', 'services', true, 'result', 'fix', 'provider', 'fused', 'site_description', null));
create temporary table contract_results (label text primary key, result jsonb not null);
create temporary table contract_definitions (label text primary key, definition text not null);
insert into contract_definitions values
  ('policy', pg_get_functiondef('private.attendance_location_policy()'::regprocedure)),
  ('gate', pg_get_functiondef('private.attendance_write_contract()'::regprocedure));
grant select on contract_base to authenticated;
grant select, insert, update on contract_results to authenticated;

create function pg_temp.contract_in(p_key text, p_patch jsonb default '{}', p_replay boolean default false)
returns jsonb language sql as $$
  select public.check_in_v2(p_idempotency_key => p_key,
    p_device_observed_at => (p->>'action_at')::timestamptz,
    p_site_description => p->>'site_description', p_latitude => (p->>'latitude')::numeric,
    p_longitude => (p->>'longitude')::numeric, p_accuracy_meters => (p->>'accuracy')::numeric,
    p_location_observed_at => (p->>'fix_at')::timestamptz, p_permission => p->>'permission',
    p_services_enabled => (p->>'services')::boolean, p_location_result => p->>'result',
    p_provider => p->>'provider', p_replay_only => p_replay)
  from (select payload || p_patch p from contract_base) b
$$;
create function pg_temp.contract_out(p_id uuid, p_key text, p_patch jsonb default '{}', p_replay boolean default false)
returns jsonb language sql as $$
  select public.check_out_v2(p_work_session_id => p_id, p_idempotency_key => p_key,
    p_device_observed_at => (p->>'action_at')::timestamptz,
    p_latitude => (p->>'latitude')::numeric, p_longitude => (p->>'longitude')::numeric,
    p_accuracy_meters => (p->>'accuracy')::numeric, p_location_observed_at => (p->>'fix_at')::timestamptz,
    p_permission => p->>'permission', p_services_enabled => (p->>'services')::boolean,
    p_location_result => p->>'result', p_provider => p->>'provider', p_replay_only => p_replay)
  from (select payload || p_patch p from contract_base) b
$$;
create function pg_temp.contract_evaluate(p_patch jsonb default '{}')
returns jsonb language sql as $$
  select private.evaluate_attendance_location(c, (b.payload->>'action_at')::timestamptz,
    (p->>'action_at')::timestamptz, (p->>'fix_at')::timestamptz,
    (p->>'latitude')::numeric, (p->>'longitude')::numeric, (p->>'accuracy')::numeric,
    p->>'permission', (p->>'services')::boolean, p->>'result')
  from public.companies c, contract_base b,
    lateral (select b.payload || p_patch p) merged
  where c.id = '82000000-0000-0000-0000-000000000001'
$$;

select is(private.attendance_write_contract(), 1, 'deployment starts in legacy mode');
select is((select count(*)::int from information_schema.columns where table_schema = 'public'
  and table_name = 'work_sessions' and column_name = 'employee_note_version'), 0, 'no deferred note version added');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname like '%employee_note%'), 2,
  'only compatible unkeyed and settled employee-note RPCs; no extra overloads');
select is((select count(*)::int from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('check_in', 'check_out', 'check_in_v2', 'check_out_v2')), 4,
  'exactly one signature per exposed attendance RPC; no overload bypass');
select ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and (p.proname like 'attendance_%' or p.proname in
    ('submit_attendance', 'evaluate_attendance_location', 'check_in_legacy_impl', 'check_out_legacy_impl'))
    and (has_function_privilege('authenticated', p.oid, 'execute') or has_function_privilege('anon', p.oid, 'execute'))),
  'all new private helpers and relocated legacy writers deny client execution');
select ok(not exists(select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('check_in', 'check_out', 'check_in_v2', 'check_out_v2')
    and (not p.prosecdef or not ('search_path=""' = any(p.proconfig))
      or has_function_privilege('anon', p.oid, 'execute') or not has_function_privilege('authenticated', p.oid, 'execute'))),
  'public RPCs have fixed empty search paths, security-definer and authenticated-only access');

set local role authenticated;
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000001', true);
select set_config('request.jwt.claim.role', 'authenticated', true);
select throws_ok($$select pg_temp.contract_in('contract-disabled-001')$$, 'P0001',
  'attendance_contract_not_enabled', 'v2 cannot create attendance before approved cutover');
select is(pg_temp.contract_in('contract-missing-001', '{}', true),
  '{"contract_version":2,"status":"not_found"}'::jsonb, 'replay-only miss writes nothing even before cutover');
select is((select count(*)::int from public.work_sessions), 0, 'disabled and replay-only requests created no sessions');
insert into contract_results values ('legacy_closed_in', public.check_in('factory', null,
  (select (payload->>'action_at')::timestamptz from contract_base), 'contract-legacy-in-001'));
insert into contract_results values ('legacy_closed_out', public.check_out(
  (select (result->>'session_id')::uuid from contract_results where label = 'legacy_closed_in'),
  'contract-legacy-out-001', (select (payload->>'action_at')::timestamptz from contract_base)));
insert into contract_results values ('legacy_active', public.check_in('factory', null,
  (select (payload->>'action_at')::timestamptz from contract_base), 'contract-legacy-in-002'));
select is((select result->>'status' from contract_results where label = 'legacy_active'), 'created', 'legacy check-in stays functional before cutover');
select is((select count(*)::int from public.location_observations), 0, 'legacy factory path remains GPS-free before cutover');
select throws_ok($$select private.attendance_write_contract()$$, '42501', null::text, 'employee cannot read/execute the private gate');
select throws_ok($$create or replace function private.attendance_write_contract() returns integer language sql as 'select 2'$$,
  '42501', null::text, 'employee cannot replace the gate');
select set_config('chantipoint.attendance_contract', '2', true);
reset role;
select is(private.attendance_write_contract(), 1, 'client-settable settings do not change the gate');

create or replace function private.attendance_write_contract()
returns integer language sql volatile set search_path = '' as $$ select null::integer $$;
set local role authenticated;
select throws_ok($$select pg_temp.contract_in('contract-null-gate-001')$$, 'P0001',
  'attendance_contract_not_enabled', 'unexpected NULL gate fails closed');
reset role;

-- Trusted, rollback-only simulation; the same exclusive lock is required for cutover.
select pg_advisory_xact_lock(174811, 2);
create or replace function private.attendance_write_contract()
returns integer language sql volatile set search_path = '' as $$ select 2 $$;
set local role authenticated;
select is(public.check_in('factory', null, (select (payload->>'action_at')::timestamptz from contract_base),
  'contract-legacy-in-001')->>'status', 'idempotent_replay', 'accepted legacy check-in remains replayable after cutover');
select is(public.check_out((select (result->>'session_id')::uuid from contract_results where label = 'legacy_closed_in'),
  'contract-legacy-out-001', (select (payload->>'action_at')::timestamptz from contract_base))->>'status',
  'idempotent_replay', 'pre-cutover legacy checkout hash still replays exactly');
select throws_ok($$select public.check_in('factory', null, null, 'contract-new-legacy-001')$$,
  'P0001', 'attendance_client_update_required', 'new legacy factory claim cannot bypass v2 after activation');
select throws_ok($$select public.check_in('external_worksite', null, null, 'contract-new-legacy-002', 0, 0, 1, 'gps')$$,
  'P0001', 'attendance_client_update_required', 'new legacy external claim also cannot bypass v2');
select throws_ok($$select public.check_in('factory', 'changed', (select (payload->>'action_at')::timestamptz from contract_base), 'contract-legacy-in-001')$$,
  '23505', 'idempotency_key_conflict', 'legacy replay still checks its original semantic hash');
select throws_ok($$select private.check_in_legacy_impl('factory', null, null, 'contract-bypass-001')$$,
  '42501', null::text, 'old implementation cannot be invoked directly by employee');
insert into contract_results values ('legacy_adapter', public.check_out(
  (select (result->>'session_id')::uuid from contract_results where label = 'legacy_active'),
  'contract-adapter-out-001', (select (payload->>'action_at')::timestamptz from contract_base)));
select is((select result->>'status' from contract_results where label = 'legacy_adapter'), 'closed', 'legacy adapter permits authorized active-session checkout');
select is((select array_agg(k order by k) from contract_results, lateral jsonb_object_keys(result) k where label = 'legacy_adapter'),
  array['ended_at','lifecycle_status','location_context','session_id','started_at','status']::text[], 'legacy adapter keeps exactly six response fields');
select is((select metadata->>'location_classification' from public.session_events where idempotency_key = 'contract-adapter-out-001'),
  'location_unverified', 'legacy checkout does not claim verified GPS');
select is((select reason_code from public.session_events where idempotency_key = 'contract-adapter-out-001'),
  'legacy_location_evidence', 'legacy limitation has a structured reason');
select is(public.check_out((select (result->>'session_id')::uuid from contract_results where label = 'legacy_active'),
  'contract-adapter-out-001', (select (payload->>'action_at')::timestamptz from contract_base))->>'status',
  'idempotent_replay', 'adapter checkout uses and replays the original v1 hash');

-- Configuration absence permits attendance and never implies factory.
insert into contract_results values ('no_factory', pg_temp.contract_in('contract-no-factory-001'));
select is((select result->>'location_context' from contract_results where label = 'no_factory'), 'location_unverified', 'missing company factory configuration stays unverified');
select is((select result#>>'{location_outcome,reason_code}' from contract_results where label = 'no_factory'), 'factory_configuration_missing', 'missing configuration is explicit');
select is((select count(*)::int from public.location_observations where work_session_id =
  (select (result->>'session_id')::uuid from contract_results where label = 'no_factory') and latitude = 0 and longitude = 0.0001),
  1, 'real-shaped evidence retained when factory is unconfigured');
select is(pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'no_factory'), 'contract-no-factory-out')->>'status',
  'closed', 'unconfigured factory does not prevent checkout');
reset role;
update public.companies set factory_latitude = 0, factory_longitude = 0, factory_radius_meters = 100
  where id = '82000000-0000-0000-0000-000000000001';

-- Deterministic pure evaluation tests pin time exactly at policy boundaries.
select is(pg_temp.contract_evaluate()->>'classification', 'factory', 'precise evidence well inside factory qualifies');
select is(pg_temp.contract_evaluate('{"longitude":0.002}')->>'classification', 'external_worksite', 'evidence well outside factory qualifies as external');
select is(pg_temp.contract_evaluate('{"longitude":0.0009}')->>'reason_code', 'boundary_uncertain', 'overlapping uncertainty stays unverified');
select is(pg_temp.contract_evaluate('{"longitude":0,"accuracy":50}')->>'reason_code', 'boundary_uncertain', '50m accuracy is usable but 110m uncertainty does not fit 100m radius');
select is(pg_temp.contract_evaluate('{"longitude":0.002,"accuracy":50}')->>'classification', 'external_worksite', '50m accuracy is accepted when geometry is unambiguous');
select is(pg_temp.contract_evaluate('{"accuracy":50.0001}')->>'reason_code', 'accuracy_insufficient', 'rounding cannot improve accuracy past the threshold');
select is((pg_temp.contract_evaluate('{"accuracy":10.001}')->>'accuracy_meters')::numeric, 10.01::numeric, 'accuracy rounds upward, never optimistically downward');
select is(pg_temp.contract_evaluate(jsonb_build_object('fix_at', (select (payload->>'action_at')::timestamptz - interval '120 seconds' from contract_base)))->>'classification', 'factory', 'fix age exactly 120 seconds is usable');
select is(pg_temp.contract_evaluate(jsonb_build_object('fix_at', (select (payload->>'action_at')::timestamptz - interval '120.000001 seconds' from contract_base)))->>'reason_code', 'location_stale', 'fix beyond age limit is stale');
select is(pg_temp.contract_evaluate(jsonb_build_object('fix_at', (select (payload->>'action_at')::timestamptz + interval '30 seconds' from contract_base)))->>'classification', 'factory', '30 second future allowance is inclusive');
select is(pg_temp.contract_evaluate(jsonb_build_object('fix_at', (select (payload->>'action_at')::timestamptz + interval '30.000001 seconds' from contract_base)))->>'reason_code', 'location_time_invalid', 'future fix beyond allowance is invalid');
select is(pg_temp.contract_evaluate(jsonb_build_object('action_at', (select (payload->>'action_at')::timestamptz - interval '300 seconds' from contract_base)))->>'classification', 'factory', '300 second action allowance is inclusive');
select is(pg_temp.contract_evaluate(jsonb_build_object('action_at', (select (payload->>'action_at')::timestamptz - interval '300.000001 seconds' from contract_base)))->>'reason_code', 'device_time_invalid', 'older action time remains unverified, not backdated');
select ok(abs(private.attendance_distance_meters(0, 179.9999, 0, -179.9999) - 22.239) < 0.01, 'distance handles the antimeridian');
select is(private.attendance_distance_meters(90, 0, 90, 0), 0::double precision, 'coincident polar points are safe');

create temporary table unavailable_cases (number integer generated always as identity, patch jsonb, reason text, description text);
insert into unavailable_cases (patch, reason, description) values
  ('{"permission":"denied","latitude":null,"longitude":null,"accuracy":null,"fix_at":null}', 'permission_denied', 'permission denied'),
  ('{"result":"permission_denied"}', 'permission_denied', 'OS-reported denial with a cached fix'),
  ('{"services":false}', 'location_services_disabled', 'location services disabled'),
  ('{"result":"location_services_disabled"}', 'location_services_disabled', 'reported disabled service'),
  ('{"result":"timeout"}', 'location_timeout', 'acquisition timeout'),
  ('{"result":"provider_error"}', 'provider_error', 'provider failure'),
  ('{"permission":"approximate"}', 'approximate_only', 'approximate permission'),
  ('{"latitude":null}', 'coordinates_invalid', 'partial coordinates'),
  ('{"latitude":90.0000001}', 'coordinates_invalid', 'latitude invalid before quantization'),
  ('{"longitude":-180.000001}', 'coordinates_invalid', 'longitude outside range'),
  ('{"latitude":"NaN"}', 'coordinates_invalid', 'NaN coordinate'),
  ('{"longitude":"Infinity"}', 'coordinates_invalid', 'infinite coordinate'),
  ('{"action_at":null}', 'device_time_missing', 'missing action time'),
  ('{"action_at":"infinity"}', 'device_time_invalid', 'infinite action time'),
  (jsonb_build_object('action_at', statement_timestamp() + interval '1 day'), 'device_time_invalid', 'future action time'),
  (jsonb_build_object('action_at', statement_timestamp() - interval '1 day'), 'device_time_invalid', 'implausibly delayed action'),
  ('{"fix_at":"infinity"}', 'location_time_invalid', 'infinite fix time'),
  (jsonb_build_object('fix_at', statement_timestamp() + interval '1 day'), 'location_time_invalid', 'future fix'),
  (jsonb_build_object('fix_at', statement_timestamp() - interval '1 hour'), 'location_stale', 'stale fix'),
  ('{"accuracy":0}', 'accuracy_invalid', 'zero accuracy'),
  ('{"accuracy":-1}', 'accuracy_invalid', 'negative accuracy'),
  ('{"accuracy":"NaN"}', 'accuracy_invalid', 'NaN accuracy'),
  ('{"accuracy":"Infinity"}', 'accuracy_invalid', 'infinite accuracy'),
  ('{"accuracy":100000000}', 'accuracy_invalid', 'accuracy outside storage range'),
  ('{"accuracy":50.01}', 'accuracy_insufficient', 'insufficient accuracy'),
  ('{"accuracy":null}', 'accuracy_missing', 'missing accuracy'),
  ('{"fix_at":null}', 'location_time_missing', 'missing fix time'),
  ('{"latitude":null,"longitude":null,"accuracy":null,"fix_at":null}', 'coordinates_missing', 'no GPS'),
  ('{"result":"unavailable"}', 'location_unavailable', 'unavailable acquisition'),
  ('{"permission":"unknown"}', 'unknown', 'unknown permission'),
  ('{"services":null}', 'unknown', 'unknown service state'),
  ('{"result":"unknown"}', 'unknown', 'unknown acquisition cause'),
  ('{"longitude":0.0009}', 'boundary_uncertain', 'boundary uncertainty');
grant select on unavailable_cases to authenticated;

-- Exercise the actual writes for every failure, not only the pure helper.
create function pg_temp.test_unavailable_attendance()
returns setof text language plpgsql as $$
declare v_case record; v_response jsonb; v_observation public.location_observations%rowtype;
begin
  for v_case in select * from unavailable_cases order by number loop
    v_response := pg_temp.contract_in('contract-unavailable-in-' || v_case.number, v_case.patch);
    return next is(v_response->>'status', 'created', v_case.description || ': authorized attendance is accepted');
    return next ok(v_response->>'lifecycle_status' = 'active' and v_response->>'ended_at' is null,
      v_case.description || ': location failure never closes the session automatically');
    return next is(v_response->>'location_context', 'location_unverified', v_case.description || ': not falsely classified');
    return next is(v_response#>>'{location_outcome,reason_code}', v_case.reason, v_case.description || ': structured primary reason');
    return next is(v_response->>'review_status', 'anomaly_open', v_case.description || ': review required');
    select * into v_observation from public.location_observations where session_event_id = (v_response->>'event_id')::uuid;
    return next ok(found and v_observation.work_session_id = (v_response->>'session_id')::uuid
      and v_observation.employee_profile_id = '83000000-0000-0000-0000-000000000001'
      and v_observation.company_id = '82000000-0000-0000-0000-000000000001', v_case.description || ': evidence has full event/session identity');
    if v_case.reason = 'coordinates_invalid' or v_case.reason = 'coordinates_missing' then
      return next ok(v_observation.observation_type = 'unavailable' and v_observation.latitude is null
        and v_observation.longitude is null, v_case.description || ': invalid/missing pair is never fabricated');
    else
      if v_case.patch->>'latitude' is not null or not (v_case.patch ? 'latitude') then
        return next ok(v_observation.latitude is not null and v_observation.longitude is not null,
          v_case.description || ': genuine coordinate pair retained');
      end if;
    end if;
    return next is(pg_temp.contract_out((v_response->>'session_id')::uuid, 'contract-unavailable-out-' || v_case.number,
      '{"permission":"denied","latitude":null,"longitude":null,"accuracy":null,"fix_at":null}')->>'status',
      'closed', v_case.description || ': no-GPS manual checkout is accepted');
  end loop;
end;
$$;
set local role authenticated;
select * from pg_temp.test_unavailable_attendance();

insert into contract_results values ('factory', pg_temp.contract_in('contract-factory-in-001'));
select is((select result->>'location_context' from contract_results where label = 'factory'), 'factory', 'server derives factory classification');
select is((select site_description from public.work_sessions where id = (select (result->>'session_id')::uuid from contract_results where label = 'factory')),
  'Fictional Contract Factory', 'factory name comes from trusted company name');
select is((select reason_code from public.session_events where idempotency_key = 'contract-factory-in-001'), null::text, 'ordinary successful check-in has no repeated manual reason');
select is((select current_monitoring_status from public.work_sessions where id = (select (result->>'session_id')::uuid from contract_results where label = 'factory')),
  'not_applicable', 'foreground evidence does not start monitoring');
select ok((select ws.started_at = se.server_accepted_at and ws.started_at >= (b.payload->>'action_at')::timestamptz
  and se.device_observed_at = (b.payload->>'action_at')::timestamptz
  and lo.device_observed_at = (b.payload->>'fix_at')::timestamptz and lo.callback_received_at is null
  from public.work_sessions ws join public.session_events se on se.work_session_id = ws.id
  join public.location_observations lo on lo.session_event_id = se.id cross join contract_base b
  where ws.check_in_idempotency_key = 'contract-factory-in-001'), 'server attendance, action time and fix time remain distinct');
select ok((select not (metadata ? 'latitude') and not (metadata ? 'longitude') and notes is null
  from public.session_events where idempotency_key = 'contract-factory-in-001'), 'event metadata does not duplicate coordinates or employee text');
select ok((select octet_length(raw_metadata::text) <= 4096 and raw_metadata#>>'{client,permission}' = 'precise'
  and raw_metadata#>>'{evaluation,policy,version}' = 'dev-v1' from public.location_observations lo
  join public.session_events se on se.id = lo.session_event_id where se.idempotency_key = 'contract-factory-in-001'),
  'bounded evidence metadata separates client claims and server evaluation provenance');
select is(pg_temp.contract_in('contract-factory-in-001', '{}', true)->>'status', 'idempotent_replay', 'complete replay-only command is acknowledged');
select is((select count(*)::int from public.session_events where idempotency_key = 'contract-factory-in-001'), 1, 'replay-only creates no duplicate event');
select throws_ok($$select pg_temp.contract_in('contract-factory-in-001', '{"latitude":null,"longitude":null}', true)$$,
  '23505', 'idempotency_key_conflict', 'key-only reconciliation cannot omit original evidence');
select throws_ok($$select pg_temp.contract_in('contract-factory-in-001', '{"permission":"approximate"}', true)$$,
  '23505', 'idempotency_key_conflict', 'replay validates original diagnostics too');
select throws_ok(format('select pg_temp.contract_in(%L,%L::jsonb,true)', 'contract-factory-in-001', patch::text),
  '23505', 'idempotency_key_conflict', 'changed semantic replay field conflicts: ' || field)
from (values
  ('latitude', '{"latitude":0.00001}'::jsonb),
  ('longitude', '{"longitude":0.0002}'),
  ('accuracy', '{"accuracy":11}'),
  ('site_description', '{"site_description":"Different workplace"}'),
  ('services', '{"services":false}'),
  ('result', '{"result":"timeout"}'),
  ('provider', '{"provider":"gps"}'),
  ('action_time', jsonb_build_object('action_at', (select (payload->>'action_at')::timestamptz - interval '1 second' from contract_base))),
  ('fix_time', jsonb_build_object('fix_at', (select (payload->>'fix_at')::timestamptz - interval '1 second' from contract_base)))
) changed(field, patch);
select is(pg_temp.contract_in('contract-factory-in-001', '{"accuracy":10.00,"longitude":0.000100}', true)->>'status',
  'idempotent_replay', 'equivalent numeric scales use one v2 hash');
set local timezone = 'America/Vancouver';
select is(pg_temp.contract_in('contract-factory-in-001', '{}', true)->>'status', 'idempotent_replay', 'v2 hash is independent of SQL session timezone');
set local timezone = 'UTC';
select is(pg_temp.contract_in('contract-replay-missing-002', '{}', true)->>'status', 'not_found', 'missing replay does not create a second active session');
select throws_ok($$select pg_temp.contract_in('contract-second-active-001')$$, '23505', 'active_session_exists', 'second active check-in is rejected');
select throws_ok($$select pg_temp.contract_in('contract-invalid-enum-001', '{"provider":"raw vendor error"}')$$,
  '22023', 'invalid_attendance_request', 'unbounded/raw provider text is not accepted as metadata');
select throws_ok($$select pg_temp.contract_in('short')$$, '22023', 'invalid_idempotency_key', 'malformed key is an invalid request');
reset role;
update public.companies set factory_latitude = 1 where id = '82000000-0000-0000-0000-000000000001';
create or replace function private.attendance_location_policy()
returns jsonb language sql stable set search_path = '' as $$
  select '{"version":"test-changed","max_accuracy_meters":1,"max_fix_age_seconds":1,"future_allowance_seconds":1,"max_action_age_seconds":1,"accuracy_multiplier":2,"boundary_margin_meters":10}'::jsonb
$$;
set local role authenticated;
select is(pg_temp.contract_in('contract-factory-in-001', '{}', true)->'location_outcome',
  (select result->'location_outcome' from contract_results where label = 'factory'), 'replay retains original classification and policy after configuration/policy changes');
reset role;
do $$ begin execute (select definition from contract_definitions where label = 'policy'); end $$;
update public.companies set factory_latitude = 0 where id = '82000000-0000-0000-0000-000000000001';
set local role authenticated;
insert into contract_results values ('independent_out', pg_temp.contract_out(
  (select (result->>'session_id')::uuid from contract_results where label = 'factory'), 'contract-independent-out-001', '{"longitude":0.002}'));
select is((select result->>'location_context' from contract_results where label = 'independent_out'), 'factory', 'checkout keeps original arrival context');
select is((select result#>>'{location_outcome,classification}' from contract_results where label = 'independent_out'), 'external_worksite', 'checkout has independent external location outcome');
select is((select reason_code from public.session_events where idempotency_key = 'contract-independent-out-001'), null::text, 'ordinary successful checkout has NULL event reason');
select is(pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'factory'),
  'contract-independent-out-001', '{"longitude":0.002}', true)->'location_outcome',
  (select result->'location_outcome' from contract_results where label = 'independent_out'), 'checkout replay returns its original independent outcome');
select throws_ok($$select pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'factory'),
  'contract-independent-out-001', '{"longitude":0.003}', true)$$, '23505', 'idempotency_key_conflict', 'checkout replay rejects changed evidence');
select is(pg_temp.contract_in('contract-factory-in-001', '{}', true)->>'lifecycle_status', 'closed_manual', 'check-in replay can honestly return a subsequently closed session');
reset role;
create temporary table contract_original_hash as select check_out_request_hash from public.work_sessions
  where id = (select (result->>'session_id')::uuid from contract_results where label = 'factory');
update public.work_sessions set check_out_request_hash = null
  where id = (select (result->>'session_id')::uuid from contract_results where label = 'factory');
set local role authenticated;
select throws_ok($$select pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'factory'),
  'contract-independent-out-001', '{"longitude":0.002}', true)$$, '23505', 'idempotency_key_conflict', 'missing stored checkout hash never passes replay verification');
reset role;
update public.work_sessions set check_out_request_hash = (select check_out_request_hash from contract_original_hash)
  where id = (select (result->>'session_id')::uuid from contract_results where label = 'factory');
update public.session_events set metadata = metadata - 'location_classification'
  where idempotency_key = 'contract-independent-out-001';
set local role authenticated;
select throws_ok($$select pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'factory'),
  'contract-independent-out-001', '{"longitude":0.002}', true)$$, 'P0001', 'attendance_receipt_unavailable', 'missing original outcome is not reconstructed or falsely acknowledged');
reset role;
update public.session_events set metadata = metadata || '{"location_classification":"external_worksite"}'::jsonb
  where idempotency_key = 'contract-independent-out-001';

create function pg_temp.test_arrival_departure_matrix()
returns setof text language plpgsql as $$
declare v_in_context text; v_out_context text; v_in jsonb; v_out jsonb; v_i integer := 0;
begin
  foreach v_in_context in array array['factory','external_worksite','location_unverified'] loop
    foreach v_out_context in array array['factory','external_worksite','location_unverified'] loop
      v_i := v_i + 1;
      v_in := pg_temp.contract_in('contract-matrix-in-' || v_i, jsonb_build_object(
        'longitude', case v_in_context when 'factory' then 0.0001 when 'external_worksite' then 0.002 else 0.0009 end,
        'site_description', 'Fictional optional workplace'));
      v_out := pg_temp.contract_out((v_in->>'session_id')::uuid, 'contract-matrix-out-' || v_i, jsonb_build_object(
        'longitude', case v_out_context when 'factory' then 0.0001 when 'external_worksite' then 0.002 else 0.0009 end));
      return next is(v_in->>'location_context', v_in_context, 'arrival matrix derives ' || v_in_context || ' #' || v_i);
      return next is(v_out->>'location_context', v_in_context, 'departure never rewrites arrival #' || v_i);
      return next is(v_out#>>'{location_outcome,classification}', v_out_context, 'independent departure matrix #' || v_i);
      return next is((select site_description from public.work_sessions where id = (v_in->>'session_id')::uuid),
        case when v_in_context = 'factory' then 'Fictional Contract Factory' else 'Fictional optional workplace' end,
        'factory/server name and external/unverified description remain distinct #' || v_i);
    end loop;
  end loop;
end;
$$;
set local role authenticated;
select * from pg_temp.test_arrival_departure_matrix();
reset role;

-- Review statuses are independent from current fix quality and note text.
create function pg_temp.test_review_statuses()
returns setof text language plpgsql as $$
declare v_status text; v_in jsonb; v_out jsonb; v_i integer := 0;
begin
  foreach v_status in array array['normal','anomaly_open','correction_pending','reviewed','corrected','disputed'] loop
    v_i := v_i + 1;
    v_in := pg_temp.contract_in('contract-review-good-in-' || v_i);
    update public.work_sessions set review_status = v_status, employee_note = 'General business note'
      where id = (v_in->>'session_id')::uuid;
    v_out := pg_temp.contract_out((v_in->>'session_id')::uuid, 'contract-review-good-out-' || v_i);
    return next is(v_out->>'review_status', v_status, 'successful checkout preserves ' || v_status);
    return next is((select employee_note from public.work_sessions where id = (v_in->>'session_id')::uuid),
      'General business note', 'checkout without note action leaves employee note untouched for ' || v_status);
    v_in := pg_temp.contract_in('contract-review-poor-in-' || v_i);
    update public.work_sessions set review_status = v_status where id = (v_in->>'session_id')::uuid;
    v_out := pg_temp.contract_out((v_in->>'session_id')::uuid, 'contract-review-poor-out-' || v_i, '{"permission":"denied"}');
    return next is(v_out->>'review_status', case when v_status in ('normal','reviewed','corrected') then 'anomaly_open' else v_status end,
      'insufficient checkout evidence reopens/preserves ' || v_status);
  end loop;
end;
$$;
select * from pg_temp.test_review_statuses();

create function pg_temp.reject_contract_observation()
returns trigger language plpgsql as $$ begin
  if new.company_id = '82000000-0000-0000-0000-000000000001' and new.provider = 'emulator' then
    raise exception 'fixture_observation_failure' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger contract_observation_failure before insert on public.location_observations
for each row execute function pg_temp.reject_contract_observation();
set local role authenticated;
select throws_ok($$select pg_temp.contract_in('contract-atomic-in-001', '{"provider":"emulator"}')$$,
  'P0001', 'fixture_observation_failure', 'observation failure aborts check-in transaction');
select is((select count(*)::int from public.work_sessions where check_in_idempotency_key = 'contract-atomic-in-001'), 0, 'failed check-in leaves no session');
select is((select count(*)::int from public.session_events where idempotency_key = 'contract-atomic-in-001'), 0, 'failed check-in leaves no event');
insert into contract_results values ('atomic', pg_temp.contract_in('contract-atomic-in-002'));
select throws_ok($$select pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'atomic'),
  'contract-atomic-out-001', '{"provider":"emulator"}')$$, 'P0001', 'fixture_observation_failure', 'evidence failure aborts checkout');
select is((select lifecycle_status from public.work_sessions where check_in_idempotency_key = 'contract-atomic-in-002'), 'active', 'failed checkout keeps session active');
select is((select count(*)::int from public.session_events where idempotency_key = 'contract-atomic-out-001'), 0, 'failed checkout leaves no event');
reset role;
drop trigger contract_observation_failure on public.location_observations;
set local role authenticated;
select is(pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'atomic'),
  'contract-atomic-out-001', '{"provider":"emulator"}')->>'status', 'closed', 'exact checkout retry succeeds after backend failure is removed');
insert into contract_results values ('suspended', pg_temp.contract_in('contract-suspension-in-001'));
reset role;
update public.companies set status = 'suspended' where id = '82000000-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$select pg_temp.contract_in('contract-suspended-new-in')$$, 'P0001', 'company_not_active', 'suspended company cannot start new attendance');
select is(pg_temp.contract_in('contract-suspension-in-001', '{}', true)->>'status', 'idempotent_replay', 'company suspension does not destroy an existing receipt');
select is(pg_temp.contract_out((select (result->>'session_id')::uuid from contract_results where label = 'suspended'),
  'contract-suspension-out-001')->>'status', 'closed', 'authorized employee can close an existing session after company suspension');
reset role;
update public.companies set status = 'active' where id = '82000000-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$update public.session_events set metadata = '{}'$$, '42501', null::text, 'employee cannot forge classification metadata');
select throws_ok($$insert into public.location_observations (work_session_id,employee_profile_id,company_id,observation_type)
  values ('84000000-0000-0000-0000-000000000001','83000000-0000-0000-0000-000000000001','82000000-0000-0000-0000-000000000001','unavailable')$$,
  '42501', null::text, 'employee cannot insert evidence directly');
select throws_ok($$select public.check_out_v2('84000000-0000-0000-0000-000000000001','contract-foreign-out-001')$$,
  '42501', 'active_session_not_found_for_employee', 'unknown session does not expose another employee record');
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000002', true);
select is((select count(*)::int from public.work_sessions), 0, 'other company employee cannot read contract fixtures');
select throws_ok($$select public.check_out_v2((select (result->>'session_id')::uuid from contract_results where label = 'atomic'), 'contract-cross-company-out')$$,
  '42501', 'active_session_not_found_for_employee', 'other company cannot close known session ID');
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000003', true);
select is((select count(*)::int from public.work_sessions), 0, 'same-company colleague cannot read attendance');
select is((select count(*)::int from public.session_events), 0, 'same-company colleague cannot read event outcomes');
select is((select count(*)::int from public.location_observations), 0, 'same-company colleague cannot read sensitive evidence');
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000004', true);
select ok((select count(*) > 0 from public.session_events), 'company administrator can retrieve event outcomes');
select ok((select count(*) > 0 from public.location_observations), 'company administrator can retrieve linked observations');
select throws_ok($$select pg_temp.contract_in('contract-admin-only-in')$$, '42501', 'employee_role_required', 'administrator-only profile cannot punch attendance');
reset role;
select throws_ok($$update public.session_events set metadata = '[]' where idempotency_key = 'contract-factory-in-001'$$,
  '23514', null::text, 'metadata must be a JSON object');
select throws_ok($$update public.session_events set metadata = jsonb_build_object('unbounded', repeat('x',16384)) where idempotency_key = 'contract-factory-in-001'$$,
  '23514', null::text, 'event metadata size is bounded');
update public.user_profiles set status = 'disabled' where id = '83000000-0000-0000-0000-000000000001';
set local role authenticated;
select set_config('request.jwt.claim.sub', '81000000-0000-0000-0000-000000000001', true);
select throws_ok($$select pg_temp.contract_in('contract-factory-in-001', '{}', true)$$, '42501', 'employee_role_required', 'disabled employee cannot replay protected results');
select is((select count(*)::int from public.work_sessions), 0, 'disabled profile loses attendance reads');
reset role;
update public.user_profiles set status = 'active' where id = '83000000-0000-0000-0000-000000000001';
update public.role_assignments set status = 'revoked', revoked_at = statement_timestamp()
  where user_profile_id = '83000000-0000-0000-0000-000000000001';
set local role authenticated;
select throws_ok($$select pg_temp.contract_in('contract-revoked-in')$$, '42501', 'employee_role_required', 'revoked employee cannot submit attendance');
select is((select count(*)::int from public.location_observations), 0, 'revoked employee loses evidence reads');
reset role;
update public.role_assignments set status = 'active', revoked_at = null
  where user_profile_id = '83000000-0000-0000-0000-000000000001';
select set_config('request.jwt.claim.sub', '', true);
select throws_ok($$select public.check_in_v2('contract-unauthenticated')$$, '42501', 'authentication_required', 'missing Auth identity is rejected');
set local role anon;
select throws_ok($$select public.check_in_v2('contract-anonymous-in')$$, '42501', null::text, 'anonymous role cannot execute attendance');
reset role;

do $$ begin execute (select definition from contract_definitions where label = 'gate'); end $$;
select is(private.attendance_write_contract(), 1, 'cutover test restores legacy mode before rollback');
select * from finish();
rollback;
