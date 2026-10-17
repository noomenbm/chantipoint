-- M2.3b.2b: one overwrite-only employee note; no history or schema additions.
-- Keep the deployment gate in legacy mode. No company configuration changes.
-- Drop exact old signatures (no CASCADE), leaving no ambiguous RPC overload.
drop function public.check_out_v2(uuid, text, timestamptz, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean);
drop function private.submit_attendance(integer, text, uuid, text, timestamptz, text, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean);

-- Existing check-in/legacy wrappers resolve this single implementation using
-- the preserve/NULL defaults. Their public signatures and hashes are unchanged.
create function private.submit_attendance(
  p_contract integer, p_operation text, p_work_session_id uuid, p_idempotency_key text,
  p_device_observed_at timestamptz, p_site_description text,
  p_latitude numeric, p_longitude numeric, p_accuracy_meters numeric,
  p_location_observed_at timestamptz, p_permission text, p_services_enabled boolean,
  p_location_result text, p_provider text, p_replay_only boolean,
  p_note_action text default 'preserve', p_employee_note text default null
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
  -- Preserve is explicit and never silently discards supplied text.
  if p_note_action is null or p_note_action not in ('preserve', 'replace', 'clear')
    or (p_note_action <> 'replace' and p_employee_note is not null)
    or (p_note_action = 'replace' and p_employee_note is null)
    or ((p_contract <> 2 or p_operation <> 'check_out') and p_note_action <> 'preserve') then
    raise exception 'invalid_employee_note_operation' using errcode = '22023';
  end if;
  if char_length(p_employee_note) > 1000 then
    raise exception 'employee_note_too_long' using errcode = '22023';
  end if;
  select * into v_company from public.companies where id = v_profile.company_id for share;
  v_hash := private.attendance_request_hash(p_contract, p_operation, v_profile.id, v_profile.company_id,
    p_work_session_id, null, p_site_description, p_device_observed_at, p_latitude, p_longitude,
    p_accuracy_meters, p_location_observed_at,
    v_permission, p_services_enabled, v_result, case when p_contract = 1 then p_provider else v_provider end);

  -- Finalized before v2 deployment: every v2 checkout, including preserve,
  -- binds the explicit note intent/content. Legacy and check-in hashes stay exact.
  -- Store only this overall command hash, never note copies or note-edit history.
  if p_contract = 2 and p_operation = 'check_out' then
    v_hash := encode(extensions.digest(convert_to(jsonb_build_object(
      'attendance_hash', v_hash, 'note_action', p_note_action,
      'employee_note', p_employee_note)::text, 'UTF8'), 'sha256'), 'hex');
  end if;

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
    -- The row is still locked; closure and final note are one atomic UPDATE.
    update public.work_sessions set employee_note = case p_note_action
        when 'replace' then p_employee_note when 'clear' then null else employee_note end,
      lifecycle_status = 'closed_manual', ended_at = v_now,
      checkout_source = 'manual', checkout_reason_code = 'manual_checkout',
      current_monitoring_status = 'stopped', review_status = v_review,
      check_out_device_observed_at = v_action_at, check_out_idempotency_key = v_key, check_out_request_hash = v_hash
    where id = v_session.id returning * into v_session;
  end if;
  return private.attendance_receipt(v_session, p_operation,
    case when p_operation = 'check_in' then 'created' else 'closed' end, p_contract);
end;
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
  p_replay_only boolean default false,
  p_note_action text default 'preserve',
  p_employee_note text default null
)
returns jsonb language sql volatile security definer set search_path = '' set timezone = 'UTC'
as $$
  select private.submit_attendance(2, 'check_out', p_work_session_id, p_idempotency_key,
    p_device_observed_at, null, p_latitude, p_longitude, p_accuracy_meters,
    p_location_observed_at, p_permission, p_services_enabled, p_location_result, p_provider, p_replay_only,
    p_note_action, p_employee_note)
$$;

create function public.update_employee_note(
  p_work_session_id uuid,
  p_employee_note text
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_profile public.user_profiles%rowtype;
  v_session public.work_sessions%rowtype;
begin
  perform pg_catalog.pg_advisory_xact_lock_shared(174811, 2);
  v_profile := private.attendance_employee();
  if p_work_session_id is null then
    raise exception 'work_session_id_required' using errcode = '22023';
  end if;
  if char_length(p_employee_note) > 1000 then
    raise exception 'employee_note_too_long' using errcode = '22023';
  end if;
  -- Same lock order as attendance. A suspended company does not prevent an
  -- already-authorized employee from annotating or manually closing a session.
  perform 1 from public.companies where id = v_profile.company_id for share;
  select * into v_session from public.work_sessions where id = p_work_session_id
    and employee_profile_id = v_profile.id and company_id = v_profile.company_id for update;
  if not found then
    raise exception 'active_session_not_found_for_employee' using errcode = '42501';
  end if;
  if v_session.lifecycle_status <> 'active' then
    raise exception 'session_not_active' using errcode = 'P0001';
  end if;
  update public.work_sessions set employee_note = p_employee_note
    where id = v_session.id returning * into v_session;
  return jsonb_build_object('status', 'updated', 'session_id', v_session.id,
    'employee_note', v_session.employee_note);
end;
$$;

revoke all on function private.submit_attendance(integer, text, uuid, text, timestamptz, text, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean, text, text) from public, anon, authenticated;
revoke all on function public.check_out_v2(uuid, text, timestamptz, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean, text, text) from public, anon;
revoke all on function public.update_employee_note(uuid, text) from public, anon;
grant execute on function public.check_out_v2(uuid, text, timestamptz, numeric, numeric, numeric, timestamptz, text, boolean, text, text, boolean, text, text) to authenticated;
grant execute on function public.update_employee_note(uuid, text) to authenticated;

notify pgrst, 'reload schema';
