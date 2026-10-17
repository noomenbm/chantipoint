-- M2.3b.2a: server-classified attendance, deliberately gated off initially.
-- No company configuration, note editing, tracking, or automatic closure.

alter table public.session_events
  add column metadata jsonb null,
  add constraint session_events_metadata_object_size_check check (
    metadata is null or (
      jsonb_typeof(metadata) = 'object'
      and octet_length(metadata::text) <= 16384
    )
  );

-- Preserve the exact deployed v1 bodies/hashes, but remove client execution.
alter function public.check_in(text, text, timestamptz, text, numeric, numeric, numeric, text)
  set schema private;
alter function private.check_in(text, text, timestamptz, text, numeric, numeric, numeric, text)
  rename to check_in_legacy_impl;
alter function public.check_out(uuid, text, timestamptz, numeric, numeric, numeric, text)
  set schema private;
alter function private.check_out(uuid, text, timestamptz, numeric, numeric, numeric, text)
  rename to check_out_legacy_impl;
revoke all on function private.check_in_legacy_impl(text, text, timestamptz, text, numeric, numeric, numeric, text)
  from public, anon, authenticated;
revoke all on function private.check_out_legacy_impl(uuid, text, timestamptz, numeric, numeric, numeric, text)
  from public, anon, authenticated;

-- A trusted cutover must first take pg_advisory_xact_lock(174811, 2),
-- then replace this function in the same transaction. Every writer takes
-- the shared lock, so cutover waits for already-running legacy requests.
-- Never use a client-settable GUC, JWT claim, or function argument as the gate.
create function private.attendance_write_contract()
returns integer language sql volatile set search_path = ''
as $$ select 1 $$;

create function private.attendance_location_policy()
returns jsonb language sql stable set search_path = ''
as $$
  select jsonb_build_object(
    'version', 'dev-v1',
    'max_accuracy_meters', 50,
    'max_fix_age_seconds', 120,
    'future_allowance_seconds', 30,
    'max_action_age_seconds', 300,
    'accuracy_multiplier', 2,
    'boundary_margin_meters', 10
  )
$$;

create function private.attendance_numeric_token(p_value numeric)
returns text language sql immutable set search_path = ''
as $$ select trim_scale(p_value)::text $$;

create function private.attendance_time_token(p_value timestamptz)
returns text language sql immutable set search_path = ''
as $$
  select case when p_value is null then null
    when not isfinite(p_value) then p_value::text
    else trim_scale(extract(epoch from p_value) * 1000000)::text end
$$;

create function private.attendance_finite_numeric(p_value numeric)
returns boolean language sql immutable set search_path = ''
as $$ select p_value is not null and p_value::text not in ('NaN', 'Infinity', '-Infinity') $$;

-- Lock order: profile -> employee role -> company -> session. The profile
-- lock serializes attendance for one employee; role/profile locks also
-- serialize these authorization checks with disablement and revocation.
create function private.attendance_employee()
returns public.user_profiles language plpgsql security definer set search_path = ''
as $$
declare v_profile public.user_profiles%rowtype;
begin
  if auth.uid() is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select * into v_profile from public.user_profiles
    where auth_user_id = auth.uid() for update;
  if not found or v_profile.status <> 'active' then
    raise exception 'employee_role_required' using errcode = '42501';
  end if;
  perform 1 from public.role_assignments
    where user_profile_id = v_profile.id and company_id = v_profile.company_id
      and role = 'employee' and status = 'active' for share;
  if not found then
    raise exception 'employee_role_required' using errcode = '42501';
  end if;
  return v_profile;
end;
$$;

-- Contract 1 deliberately uses the original jsonb/timestamptz/numeric
-- serialization. Contract 2 uses independent, timezone/scale-stable tokens.
create function private.attendance_request_hash(
  p_contract integer, p_operation text, p_profile_id uuid, p_company_id uuid,
  p_work_session_id uuid, p_location_context text, p_site_description text,
  p_device_observed_at timestamptz, p_latitude numeric, p_longitude numeric,
  p_accuracy_meters numeric, p_location_observed_at timestamptz,
  p_permission text, p_services_enabled boolean, p_location_result text, p_provider text
)
returns text language plpgsql stable set search_path = ''
as $$
declare v_payload jsonb;
begin
  if p_contract = 1 then
    if p_operation = 'check_in' then
      v_payload := jsonb_build_object(
        'location_context', p_location_context,
        'site_description', nullif(btrim(p_site_description), ''),
        'device_observed_at', p_device_observed_at,
        'latitude', p_latitude, 'longitude', p_longitude,
        'accuracy_meters', p_accuracy_meters, 'provider', p_provider);
    else
      v_payload := jsonb_build_object(
        'work_session_id', p_work_session_id,
        'device_observed_at', p_device_observed_at,
        'latitude', p_latitude, 'longitude', p_longitude,
        'accuracy_meters', p_accuracy_meters, 'provider', p_provider);
    end if;
  else
    v_payload := jsonb_build_object(
      'contract_version', 2, 'operation', p_operation,
      'employee_profile_id', p_profile_id, 'company_id', p_company_id,
      'work_session_id', p_work_session_id,
      'site_description', nullif(btrim(p_site_description), ''),
      'action_time_us', private.attendance_time_token(p_device_observed_at),
      'fix_time_us', private.attendance_time_token(p_location_observed_at),
      'latitude', private.attendance_numeric_token(p_latitude),
      'longitude', private.attendance_numeric_token(p_longitude),
      'accuracy_meters', private.attendance_numeric_token(p_accuracy_meters),
      'permission', p_permission, 'services_enabled', p_services_enabled,
      'location_result', p_location_result, 'provider', p_provider);
  end if;
  return encode(extensions.digest(convert_to(v_payload::text, 'UTF8'), 'sha256'), 'hex');
end;
$$;

create function private.attendance_distance_meters(
  p_latitude numeric, p_longitude numeric, p_center_latitude numeric, p_center_longitude numeric
)
returns double precision language sql immutable set search_path = ''
as $$
  select 2 * 6371008.8 * asin(sqrt(greatest(0::double precision, least(1::double precision,
    power(sin(radians((p_latitude - p_center_latitude)::double precision) / 2), 2)
    + cos(radians(p_latitude::double precision)) * cos(radians(p_center_latitude::double precision))
    * power(sin(radians((p_longitude - p_center_longitude)::double precision) / 2), 2)
  ))))
$$;

create function private.evaluate_attendance_location(
  p_company public.companies, p_now timestamptz,
  p_device_observed_at timestamptz, p_location_observed_at timestamptz,
  p_latitude numeric, p_longitude numeric, p_accuracy_meters numeric,
  p_permission text, p_services_enabled boolean, p_location_result text
)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare
  v_policy jsonb := private.attendance_location_policy();
  v_issues text[] := array[]::text[];
  v_latitude numeric;
  v_longitude numeric;
  v_accuracy numeric;
  v_coordinates text := 'missing';
  v_accuracy_status text := 'missing';
  v_action_status text := 'missing';
  v_fix_status text := 'missing';
  v_classification text := 'location_unverified';
  v_distance double precision;
  v_uncertainty numeric;
  v_factory jsonb;
begin
  if p_latitude is not null or p_longitude is not null then
    v_coordinates := 'invalid';
    if private.attendance_finite_numeric(p_latitude)
      and private.attendance_finite_numeric(p_longitude)
      and p_latitude between -90 and 90 and p_longitude between -180 and 180 then
      v_coordinates := 'valid';
      v_latitude := round(p_latitude, 6);
      v_longitude := round(p_longitude, 6);
    end if;
  end if;
  if p_accuracy_meters is not null then
    v_accuracy_status := 'invalid';
    if private.attendance_finite_numeric(p_accuracy_meters)
      and p_accuracy_meters >= 0 and p_accuracy_meters <= 99999999.99 then
      v_accuracy := ceil(p_accuracy_meters * 100) / 100;
      if v_accuracy > 0 then
        v_accuracy_status := case when v_accuracy <= (v_policy->>'max_accuracy_meters')::numeric
          then 'usable' else 'insufficient' end;
        v_uncertainty := (v_policy->>'accuracy_multiplier')::numeric * v_accuracy
          + (v_policy->>'boundary_margin_meters')::numeric;
      end if;
    end if;
  end if;
  if p_device_observed_at is not null then
    v_action_status := 'invalid';
    if isfinite(p_device_observed_at)
      and p_device_observed_at >= p_now - (v_policy->>'max_action_age_seconds')::numeric * interval '1 second'
      and p_device_observed_at <= p_now + (v_policy->>'future_allowance_seconds')::numeric * interval '1 second' then
      v_action_status := 'plausible';
    end if;
  end if;
  if p_location_observed_at is not null then
    v_fix_status := 'invalid';
    if isfinite(p_location_observed_at)
      and p_location_observed_at <= p_now + (v_policy->>'future_allowance_seconds')::numeric * interval '1 second' then
      v_fix_status := case when p_location_observed_at < p_now - (v_policy->>'max_fix_age_seconds')::numeric * interval '1 second'
        then 'stale' else 'plausible' end;
    end if;
  end if;
  if p_company.factory_latitude is not null and p_company.factory_longitude is not null
    and p_company.factory_radius_meters is not null then
    v_factory := jsonb_build_object('latitude', p_company.factory_latitude,
      'longitude', p_company.factory_longitude, 'radius_meters', p_company.factory_radius_meters);
    if v_coordinates = 'valid' then
      v_distance := private.attendance_distance_meters(v_latitude, v_longitude,
        p_company.factory_latitude, p_company.factory_longitude);
    end if;
  end if;

  -- Deterministic primary reason; claims remain client-reported diagnostics.
  if p_permission = 'denied' or p_location_result = 'permission_denied' then v_issues := array_append(v_issues, 'permission_denied'); end if;
  if p_services_enabled is false or p_location_result = 'location_services_disabled' then v_issues := array_append(v_issues, 'location_services_disabled'); end if;
  if p_location_result = 'timeout' then v_issues := array_append(v_issues, 'location_timeout'); end if;
  if p_location_result = 'provider_error' then v_issues := array_append(v_issues, 'provider_error'); end if;
  if p_permission = 'approximate' then v_issues := array_append(v_issues, 'approximate_only'); end if;
  if v_coordinates = 'invalid' then v_issues := array_append(v_issues, 'coordinates_invalid'); end if;
  if v_action_status = 'invalid' then v_issues := array_append(v_issues, 'device_time_invalid'); end if;
  if v_action_status = 'missing' then v_issues := array_append(v_issues, 'device_time_missing'); end if;
  if v_coordinates = 'valid' then
    if v_fix_status = 'invalid' then v_issues := array_append(v_issues, 'location_time_invalid'); end if;
    if v_fix_status = 'stale' then v_issues := array_append(v_issues, 'location_stale'); end if;
    if v_accuracy_status = 'invalid' then v_issues := array_append(v_issues, 'accuracy_invalid'); end if;
    if v_accuracy_status = 'insufficient' then v_issues := array_append(v_issues, 'accuracy_insufficient'); end if;
    if v_accuracy_status = 'missing' then v_issues := array_append(v_issues, 'accuracy_missing'); end if;
    if v_fix_status = 'missing' then v_issues := array_append(v_issues, 'location_time_missing'); end if;
  end if;
  if v_coordinates = 'missing' then v_issues := array_append(v_issues, 'coordinates_missing'); end if;
  if p_location_result = 'unavailable' then v_issues := array_append(v_issues, 'location_unavailable'); end if;
  if p_permission = 'unknown' or p_services_enabled is null or p_location_result = 'unknown' then v_issues := array_append(v_issues, 'unknown'); end if;
  if v_factory is null then v_issues := array_append(v_issues, 'factory_configuration_missing'); end if;
  if cardinality(v_issues) = 0 then
    if v_distance + v_uncertainty < p_company.factory_radius_meters then
      v_classification := 'factory';
    elsif v_distance - v_uncertainty > p_company.factory_radius_meters then
      v_classification := 'external_worksite';
    else
      v_issues := array_append(v_issues, 'boundary_uncertain');
    end if;
  end if;
  return jsonb_build_object(
    'classification', v_classification, 'reason_code', v_issues[1], 'issues', to_jsonb(v_issues),
    'policy_version', v_policy->>'version', 'latitude', v_latitude,
    'longitude', v_longitude, 'accuracy_meters', v_accuracy,
    'diagnostics', jsonb_build_object(
      'client', jsonb_build_object('permission', p_permission, 'services_enabled', p_services_enabled, 'location_result', p_location_result),
      'evaluation', jsonb_build_object('policy', v_policy, 'factory', v_factory,
        'distance_meters', v_distance, 'uncertainty_meters', v_uncertainty,
        'coordinate_status', v_coordinates, 'accuracy_status', v_accuracy_status,
        'action_time_status', v_action_status, 'fix_time_status', v_fix_status)
    )
  );
end;
$$;

create function private.attendance_receipt(
  p_session public.work_sessions, p_operation text, p_status text, p_contract integer
)
returns jsonb language plpgsql stable set search_path = ''
as $$
declare v_result jsonb; v_event public.session_events%rowtype;
begin
  v_result := jsonb_build_object('status', p_status, 'session_id', p_session.id,
    'lifecycle_status', p_session.lifecycle_status, 'location_context', p_session.location_context,
    'started_at', p_session.started_at, 'ended_at', p_session.ended_at);
  if p_contract = 1 then return v_result; end if;
  select * into v_event from public.session_events
    where work_session_id = p_session.id and company_id = p_session.company_id
      and employee_profile_id = p_session.employee_profile_id
      and event_type = case when p_operation = 'check_in' then 'check_in' else 'manual_checkout' end
      and idempotency_key = case when p_operation = 'check_in' then p_session.check_in_idempotency_key else p_session.check_out_idempotency_key end;
  if not found or v_event.metadata->>'contract_version' is distinct from '2'
    or v_event.metadata->>'operation' is distinct from p_operation
    or v_event.metadata->>'location_classification' is null
    or v_event.metadata->>'location_classification' not in ('factory', 'external_worksite', 'location_unverified')
    or nullif(v_event.metadata->>'policy_version', '') is null then
    raise exception 'attendance_receipt_unavailable' using errcode = 'P0001';
  end if;
  return v_result || jsonb_build_object('contract_version', 2,
    'review_status', p_session.review_status, 'event_id', v_event.id,
    'location_outcome', jsonb_build_object('classification', v_event.metadata->>'location_classification',
      'reason_code', v_event.reason_code, 'policy_version', v_event.metadata->>'policy_version'));
end;
$$;

-- Only public wrappers call this implementation; no client-supplied contract
-- version, employee identity, classification, metadata, or server timestamp.
create function private.submit_attendance(
  p_contract integer, p_operation text, p_work_session_id uuid, p_idempotency_key text,
  p_device_observed_at timestamptz, p_site_description text,
  p_latitude numeric, p_longitude numeric, p_accuracy_meters numeric,
  p_location_observed_at timestamptz, p_permission text, p_services_enabled boolean,
  p_location_result text, p_provider text, p_replay_only boolean
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_profile public.user_profiles%rowtype;
  v_company public.companies%rowtype;
  v_session public.work_sessions%rowtype;
  v_key text := btrim(p_idempotency_key);
  v_permission text := coalesce(p_permission, 'unknown');
  v_result text := coalesce(p_location_result, 'unknown');
  v_provider text := coalesce(p_provider, 'unknown');
  v_hash text;
  v_evaluation jsonb;
  v_metadata jsonb;
  v_diagnostics jsonb;
  v_event_id uuid;
  v_now timestamptz;
  v_received_at timestamptz := statement_timestamp();
  v_action_at timestamptz := case when isfinite(p_device_observed_at) then p_device_observed_at else null end;
  v_fix_at timestamptz := case when isfinite(p_location_observed_at) then p_location_observed_at else null end;
  v_review text;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(174811, 2);
  v_profile := private.attendance_employee();
  if p_operation not in ('check_in', 'check_out') or p_operation is null
    or p_contract not in (1, 2) or p_contract is null
    or (p_contract = 1 and p_operation <> 'check_out') then
    raise exception 'invalid_attendance_operation' using errcode = '22023';
  end if;
  if v_key is null or length(v_key) not between 8 and 160 then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;
  if p_replay_only is null or length(p_site_description) > 500
    or v_permission not in ('precise', 'approximate', 'denied', 'unknown')
    or v_result not in ('fix', 'permission_denied', 'location_services_disabled', 'timeout', 'provider_error', 'unavailable', 'unknown')
    or (p_contract = 2 and v_provider not in ('gps', 'network', 'fused', 'emulator', 'unknown'))
    or (p_contract = 1 and v_provider not in ('gps', 'network', 'fused', 'geofence', 'platform_event', 'emulator', 'unknown')) then
    raise exception 'invalid_attendance_request' using errcode = '22023';
  end if;
  if p_operation = 'check_out' and p_work_session_id is null then
    raise exception 'work_session_id_required' using errcode = '22023';
  end if;
  select * into v_company from public.companies where id = v_profile.company_id for share;
  v_hash := private.attendance_request_hash(p_contract, p_operation, v_profile.id, v_profile.company_id,
    p_work_session_id, null, p_site_description, p_device_observed_at, p_latitude, p_longitude,
    p_accuracy_meters, p_location_observed_at,
    v_permission, p_services_enabled, v_result, case when p_contract = 1 then p_provider else v_provider end);

  select * into v_session from public.work_sessions
    where employee_profile_id = v_profile.id and company_id = v_profile.company_id
      and case when p_operation = 'check_in' then check_in_idempotency_key = v_key else check_out_idempotency_key = v_key end;
  if found then
    if (p_operation = 'check_in' and v_session.check_in_request_hash is distinct from v_hash)
      or (p_operation = 'check_out' and (v_session.id <> p_work_session_id or v_session.check_out_request_hash is distinct from v_hash)) then
      raise exception 'idempotency_key_conflict' using errcode = '23505';
    end if;
    return private.attendance_receipt(v_session, p_operation, 'idempotent_replay', p_contract);
  end if;
  if p_replay_only then return jsonb_build_object('contract_version', 2, 'status', 'not_found'); end if;
  if p_contract = 2 and private.attendance_write_contract() is distinct from 2 then
    raise exception 'attendance_contract_not_enabled' using errcode = 'P0001';
  end if;

  if p_operation = 'check_in' then
    if v_company.status <> 'active' then raise exception 'company_not_active' using errcode = 'P0001'; end if;
    if exists (select 1 from public.work_sessions where employee_profile_id = v_profile.id and lifecycle_status = 'active') then
      raise exception 'active_session_exists' using errcode = '23505';
    end if;
  else
    select * into v_session from public.work_sessions where id = p_work_session_id
      and employee_profile_id = v_profile.id and company_id = v_profile.company_id for update;
    if not found then raise exception 'active_session_not_found_for_employee' using errcode = '42501'; end if;
    if v_session.lifecycle_status <> 'active' then raise exception 'session_not_active' using errcode = 'P0001'; end if;
  end if;

  v_now := clock_timestamp();
  v_evaluation := private.evaluate_attendance_location(v_company, v_now, p_device_observed_at,
    p_location_observed_at, p_latitude, p_longitude, p_accuracy_meters,
    v_permission, p_services_enabled, v_result);
  if p_contract = 1 then
    v_evaluation := v_evaluation || jsonb_build_object('classification', 'location_unverified',
      'reason_code', 'legacy_location_evidence',
      'issues', jsonb_build_array('legacy_location_evidence') || (v_evaluation->'issues'));
  end if;
  v_metadata := jsonb_build_object('contract_version', p_contract, 'operation', p_operation,
    'location_classification', v_evaluation->>'classification',
    'policy_version', v_evaluation->>'policy_version', 'location_issues', v_evaluation->'issues');
  v_diagnostics := v_evaluation->'diagnostics';
  if octet_length(v_diagnostics::text) > 4096 then
    raise exception 'attendance_metadata_limit' using errcode = 'P0001';
  end if;

  if p_operation = 'check_in' then
    insert into public.work_sessions (employee_profile_id, company_id, location_context, site_description,
      lifecycle_status, review_status, current_monitoring_status, started_at,
      check_in_device_observed_at, check_in_idempotency_key, check_in_request_hash)
    values (v_profile.id, v_profile.company_id, v_evaluation->>'classification',
      case when v_evaluation->>'classification' = 'factory' then v_company.name else nullif(btrim(p_site_description), '') end,
      'active', case when v_evaluation->>'classification' = 'location_unverified' then 'anomaly_open' else 'normal' end,
      'not_applicable', v_now, v_action_at, v_key, v_hash)
    returning * into v_session;
  end if;

  insert into public.session_events (work_session_id, employee_profile_id, company_id, event_type,
    source, actor_profile_id, device_observed_at, server_accepted_at, reason_code, idempotency_key, metadata)
  values (v_session.id, v_profile.id, v_profile.company_id,
    case when p_operation = 'check_in' then 'check_in' else 'manual_checkout' end,
    'employee_app', v_profile.id, v_action_at, v_now, v_evaluation->>'reason_code', v_key, v_metadata)
  returning id into v_event_id;

  -- Evidence is always inserted while the session is active, including checkout.
  insert into public.location_observations (work_session_id, session_event_id, employee_profile_id, company_id,
    observation_type, latitude, longitude, accuracy_meters, provider,
    device_observed_at, server_received_at, raw_metadata)
  values (v_session.id, v_event_id, v_profile.id, v_profile.company_id,
    case when v_evaluation->>'latitude' is null then 'unavailable'
      when p_operation = 'check_in' then 'check_in_location' else 'checkout_location' end,
    (v_evaluation->>'latitude')::numeric, (v_evaluation->>'longitude')::numeric,
    (v_evaluation->>'accuracy_meters')::numeric, v_provider, v_fix_at, v_received_at, v_diagnostics);

  if p_operation = 'check_out' then
    v_review := v_session.review_status;
    if v_evaluation->>'classification' = 'location_unverified' and v_review in ('normal', 'reviewed', 'corrected') then
      v_review := 'anomaly_open';
    end if;
    update public.work_sessions set lifecycle_status = 'closed_manual', ended_at = v_now,
      checkout_source = 'manual', checkout_reason_code = 'manual_checkout',
      current_monitoring_status = 'stopped', review_status = v_review,
      check_out_device_observed_at = v_action_at, check_out_idempotency_key = v_key, check_out_request_hash = v_hash
    where id = v_session.id returning * into v_session;
  end if;
  return private.attendance_receipt(v_session, p_operation,
    case when p_operation = 'check_in' then 'created' else 'closed' end, p_contract);
end;
$$;

create function public.check_in_v2(
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_site_description text default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_location_observed_at timestamptz default null,
  p_permission text default 'unknown',
  p_services_enabled boolean default null,
  p_location_result text default 'unknown',
  p_provider text default 'unknown',
  p_replay_only boolean default false
)
returns jsonb language sql volatile security definer set search_path = '' set timezone = 'UTC'
as $$
  select private.submit_attendance(2, 'check_in', null, p_idempotency_key,
    p_device_observed_at, p_site_description, p_latitude, p_longitude, p_accuracy_meters,
    p_location_observed_at, p_permission, p_services_enabled, p_location_result, p_provider, p_replay_only)
$$;

create function public.check_out_v2(
  p_work_session_id uuid,
  p_idempotency_key text,
  p_device_observed_at timestamptz default null,
  p_latitude numeric default null,
  p_longitude numeric default null,
  p_accuracy_meters numeric default null,
  p_location_observed_at timestamptz default null,
  p_permission text default 'unknown',
  p_services_enabled boolean default null,
  p_location_result text default 'unknown',
  p_provider text default 'unknown',
  p_replay_only boolean default false
)
returns jsonb language sql volatile security definer set search_path = '' set timezone = 'UTC'
as $$
  select private.submit_attendance(2, 'check_out', p_work_session_id, p_idempotency_key,
    p_device_observed_at, null, p_latitude, p_longitude, p_accuracy_meters,
    p_location_observed_at, p_permission, p_services_enabled, p_location_result, p_provider, p_replay_only)
$$;

create function public.check_in(
  p_location_context text, p_site_description text, p_device_observed_at timestamptz, p_idempotency_key text,
  p_latitude numeric default null, p_longitude numeric default null,
  p_accuracy_meters numeric default null, p_provider text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare v_profile public.user_profiles%rowtype; v_session public.work_sessions%rowtype; v_hash text;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(174811, 2);
  if private.attendance_write_contract() = 1 then
    return private.check_in_legacy_impl(p_location_context, p_site_description, p_device_observed_at,
      p_idempotency_key, p_latitude, p_longitude, p_accuracy_meters, p_provider);
  end if;
  v_profile := private.attendance_employee();
  if p_idempotency_key is null or length(btrim(p_idempotency_key)) not between 8 and 160 then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;
  select * into v_session from public.work_sessions
    where employee_profile_id = v_profile.id and company_id = v_profile.company_id
      and check_in_idempotency_key = btrim(p_idempotency_key);
  if not found then raise exception 'attendance_client_update_required' using errcode = 'P0001'; end if;
  v_hash := private.attendance_request_hash(1, 'check_in', v_profile.id, v_profile.company_id,
    null, p_location_context, p_site_description, p_device_observed_at,
    p_latitude, p_longitude, p_accuracy_meters, null, null, null, null, p_provider);
  if v_session.check_in_request_hash is distinct from v_hash then
    raise exception 'idempotency_key_conflict' using errcode = '23505';
  end if;
  return private.attendance_receipt(v_session, 'check_in', 'idempotent_replay', 1);
end;
$$;

create function public.check_out(
  p_work_session_id uuid, p_idempotency_key text, p_device_observed_at timestamptz default null,
  p_latitude numeric default null, p_longitude numeric default null,
  p_accuracy_meters numeric default null, p_provider text default null
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(174811, 2);
  if private.attendance_write_contract() = 1 then
    return private.check_out_legacy_impl(p_work_session_id, p_idempotency_key,
      p_device_observed_at, p_latitude, p_longitude, p_accuracy_meters, p_provider);
  end if;
  return private.submit_attendance(1, 'check_out', p_work_session_id, p_idempotency_key,
    p_device_observed_at, null, p_latitude, p_longitude, p_accuracy_meters,
    null, 'unknown', null, 'unknown', p_provider, false);
end;
$$;

revoke all on function private.attendance_write_contract() from public, anon, authenticated;
revoke all on function private.attendance_location_policy() from public, anon, authenticated;
revoke all on function private.attendance_numeric_token(numeric) from public, anon, authenticated;
revoke all on function private.attendance_time_token(timestamptz) from public, anon, authenticated;
revoke all on function private.attendance_finite_numeric(numeric) from public, anon, authenticated;
revoke all on function private.attendance_employee() from public, anon, authenticated;
revoke all on function private.attendance_request_hash(integer, text, uuid, uuid, uuid, text, text, timestamptz, numeric, numeric, numeric, timestamptz, text, boolean, text, text) from public, anon, authenticated;
revoke all on function private.attendance_distance_meters(numeric, numeric, numeric, numeric) from public, anon, authenticated;
revoke all on function private.evaluate_attendance_location(public.companies, timestamptz, timestamptz, timestamptz, numeric, numeric, numeric, text, boolean, text) from public, anon, authenticated;
revoke all on function private.attendance_receipt(public.work_sessions, text, text, integer) from public, anon, authenticated;
revoke all on function private.submit_attendance(integer, text, uuid, text, timestamptz, text, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean) from public, anon, authenticated;

revoke all on function public.check_in_v2(text, timestamptz, text, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean) from public, anon;
revoke all on function public.check_out_v2(uuid, text, timestamptz, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean) from public, anon;
revoke all on function public.check_in(text, text, timestamptz, text, numeric, numeric, numeric, text) from public, anon;
revoke all on function public.check_out(uuid, text, timestamptz, numeric, numeric, numeric, text) from public, anon;
grant execute on function public.check_in_v2(text, timestamptz, text, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean) to authenticated;
grant execute on function public.check_out_v2(uuid, text, timestamptz, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean) to authenticated;
grant execute on function public.check_in(text, text, timestamptz, text, numeric, numeric, numeric, text) to authenticated;
grant execute on function public.check_out(uuid, text, timestamptz, numeric, numeric, numeric, text) to authenticated;

notify pgrst, 'reload schema';
