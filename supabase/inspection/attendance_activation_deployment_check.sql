-- STRICT SIX-MIGRATION gate-1 postdeployment inspection; NOT the old 19 checks.
-- Verify the linked project is chantipoint-dev BEFORE using --linked.
-- All returned rows must exist and passed=true; errors/missing rows mean STOP.
-- No application-function/RPC execution, DDL/DML, identities, keys, epoch value or row contents.
-- Function fingerprints/metadata are derived from the ordered committed sources.
-- RLS expressions are the reviewed PG17 deparsing of the original policies.
-- Catalog equality does not test PostgREST schema cache or authorize v2 cutover.
begin read only;
set local statement_timeout = '10s';
set local lock_timeout = '3s';
set local search_path = pg_catalog;
with expected_functions as (
  select * from jsonb_to_recordset($functions$
[
  {
    "signature": "private.attendance_distance_meters(numeric,numeric,numeric,numeric)",
    "body_sha256": "4dd01397c1b54de61008c045060a8350b26cd57c5be11f969e1b99f365bdffb3",
    "argument_names": [
      "p_latitude",
      "p_longitude",
      "p_center_latitude",
      "p_center_longitude"
    ],
    "defaults": "",
    "result_type": "double precision",
    "definer": false,
    "language": "sql",
    "volatility": "i",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_employee()",
    "body_sha256": "2e50e67e010011a5f3badf51921810ff5ca754b1a5dfac0d8e9e34e77541352d",
    "argument_names": [],
    "defaults": "",
    "result_type": "public.user_profiles",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_finite_numeric(numeric)",
    "body_sha256": "cc0d1a8c85d35a29a47c1266feb3230dd39afeb3c9c23af2e8f05088d62ed50d",
    "argument_names": [
      "p_value"
    ],
    "defaults": "",
    "result_type": "boolean",
    "definer": false,
    "language": "sql",
    "volatility": "i",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_location_policy()",
    "body_sha256": "7e71e19accedf7fd755dd0a2bf262e545c4499f2b6198713ac1c1a47941702fc",
    "argument_names": [],
    "defaults": "",
    "result_type": "jsonb",
    "definer": false,
    "language": "sql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_numeric_token(numeric)",
    "body_sha256": "6d652b16d65bcf84af5ac70256bf93192202e795381c6982fee0c42f555a02e7",
    "argument_names": [
      "p_value"
    ],
    "defaults": "",
    "result_type": "text",
    "definer": false,
    "language": "sql",
    "volatility": "i",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_receipt(public.work_sessions,text,text,integer)",
    "body_sha256": "60ce9521bde004936dfb26a481237b82fa8eab74248ca77f80e7d43fb3247232",
    "argument_names": [
      "p_session",
      "p_operation",
      "p_status",
      "p_contract"
    ],
    "defaults": "",
    "result_type": "jsonb",
    "definer": false,
    "language": "plpgsql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_request_hash(integer,text,uuid,uuid,uuid,text,text,timestamptz,numeric,numeric,numeric,timestamptz,text,boolean,text,text)",
    "body_sha256": "53034806f6f360da1005a59d3a830b7d0791d0669ef7859582aed38f1c64418d",
    "argument_names": [
      "p_contract",
      "p_operation",
      "p_profile_id",
      "p_company_id",
      "p_work_session_id",
      "p_location_context",
      "p_site_description",
      "p_device_observed_at",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_location_observed_at",
      "p_permission",
      "p_services_enabled",
      "p_location_result",
      "p_provider"
    ],
    "defaults": "",
    "result_type": "text",
    "definer": false,
    "language": "plpgsql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_time_token(timestamptz)",
    "body_sha256": "f135fa6fbbea01509319f45b29d744d4c1c6a235b69b9cacab257aac931bb3a3",
    "argument_names": [
      "p_value"
    ],
    "defaults": "",
    "result_type": "text",
    "definer": false,
    "language": "sql",
    "volatility": "i",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.attendance_write_contract()",
    "body_sha256": "5419df19b684af0e9a2f023d156f32736f5326d6ba9a8837072c2e88f833304a",
    "argument_names": [],
    "defaults": "",
    "result_type": "integer",
    "definer": false,
    "language": "sql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.check_in_legacy_impl(text,text,timestamptz,text,numeric,numeric,numeric,text)",
    "body_sha256": "6b6b0431be8e30a6d3906be56425727a6ded80b1083eb1a6f04d8982fc4a0009",
    "argument_names": [
      "p_location_context",
      "p_site_description",
      "p_device_observed_at",
      "p_idempotency_key",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_provider"
    ],
    "defaults": "NULL::numeric, NULL::numeric, NULL::numeric, NULL::text",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.check_out_legacy_impl(uuid,text,timestamptz,numeric,numeric,numeric,text)",
    "body_sha256": "f030c1045c37eef9835ae5ceaf6083077692bf02e42861fa9160cd4703483bf9",
    "argument_names": [
      "p_work_session_id",
      "p_idempotency_key",
      "p_device_observed_at",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_provider"
    ],
    "defaults": "NULL::timestamp with time zone, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.current_company_id()",
    "body_sha256": "b3573c2b98cba4b60f581ab300294a61c04963c684374380565a8d158bfe2838",
    "argument_names": [],
    "defaults": "",
    "result_type": "uuid",
    "definer": true,
    "language": "sql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "private.current_profile_id()",
    "body_sha256": "b280b5f7493cf28cea632297de063f1bd521fd8e29888d6f75b94192088435ab",
    "argument_names": [],
    "defaults": "",
    "result_type": "uuid",
    "definer": true,
    "language": "sql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "private.current_user_can_read_own_attendance(uuid)",
    "body_sha256": "703feac2bf603e027bedfa090b13a070b8d8780efa0a9d62dedc19f220e5cd7a",
    "argument_names": [
      "p_profile_id"
    ],
    "defaults": "",
    "result_type": "boolean",
    "definer": true,
    "language": "sql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "private.current_user_has_role(text)",
    "body_sha256": "553696737a65b1f67bd6eb389a7cdc533b47b55fba2f2028f28ce894af40e6cf",
    "argument_names": [
      "p_role"
    ],
    "defaults": "",
    "result_type": "boolean",
    "definer": true,
    "language": "sql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "private.current_user_is_company_admin(uuid)",
    "body_sha256": "53ef37365f58f669f7ab5e9783b78c529212d983e4b310f4167122625f657227",
    "argument_names": [
      "p_company_id"
    ],
    "defaults": "",
    "result_type": "boolean",
    "definer": true,
    "language": "sql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "private.evaluate_attendance_location(public.companies,timestamptz,timestamptz,timestamptz,numeric,numeric,numeric,text,boolean,text)",
    "body_sha256": "4b28ec84f239944f1898bc586d3d0468737859434b609b1b7edb32d3498d31f6",
    "argument_names": [
      "p_company",
      "p_now",
      "p_device_observed_at",
      "p_location_observed_at",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_permission",
      "p_services_enabled",
      "p_location_result"
    ],
    "defaults": "",
    "result_type": "jsonb",
    "definer": false,
    "language": "plpgsql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.lock_attendance_deployment_change()",
    "body_sha256": "9e79c363ed51b92f33ab81d30cb5f0e0baa32c16419192622bc422721c374145",
    "argument_names": [],
    "defaults": "",
    "result_type": "trigger",
    "definer": false,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.locked_attendance_deployment()",
    "body_sha256": "30110c33272948a9159e5d7af168df23c85b3f727434f240ef2f4778e385bf73",
    "argument_names": [],
    "defaults": "",
    "result_type": "private.attendance_deployment",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.prevent_admin_audit_event_mutation()",
    "body_sha256": "4a43ccb6a85541183bd31f2bc29d599c5c8efef982da29c1c7ad8e09a3a18b44",
    "argument_names": [],
    "defaults": "",
    "result_type": "trigger",
    "definer": false,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.prevent_last_admin_profile_disable()",
    "body_sha256": "8302aa5888bc3ab81148442b8dacb886855cf1317eaefd3694d035112946fee1",
    "argument_names": [],
    "defaults": "",
    "result_type": "trigger",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.prevent_last_admin_role_loss()",
    "body_sha256": "1848157804ca4bf1c31676d1c4b5bca88b2a286ead68f13b59b89f320876ebb5",
    "argument_names": [],
    "defaults": "",
    "result_type": "trigger",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.require_attendance_epoch()",
    "body_sha256": "a5b71c55138af59a53cff0e0b9c1391afaae03ecaca0960bb2c1fbecd1aa72cf",
    "argument_names": [],
    "defaults": "",
    "result_type": "void",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.save_employee_note_legacy_impl(uuid,text,text,text,boolean)",
    "body_sha256": "a29a1c53dae0546b1e60aee079eb63fc4638f31b0420645a8179fca31f54aa2a",
    "argument_names": [
      "p_work_session_id",
      "p_operation_key",
      "p_note_action",
      "p_employee_note",
      "p_replay_only"
    ],
    "defaults": "false",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\"",
      "TimeZone=UTC"
    ],
    "client_execute": false
  },
  {
    "signature": "private.set_updated_at()",
    "body_sha256": "5a8f4016886cdf8674eb096c4d9b4b5c2599fd42d6952222e5c60717d5075fda",
    "argument_names": [],
    "defaults": "",
    "result_type": "trigger",
    "definer": false,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.submit_attendance(integer,text,uuid,text,timestamptz,text,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean,text,text)",
    "body_sha256": "0069caa62c5e5cf8825b13cc6522286786af7bcdc6d861fbee1e1fa426a04cb5",
    "argument_names": [
      "p_contract",
      "p_operation",
      "p_work_session_id",
      "p_idempotency_key",
      "p_device_observed_at",
      "p_site_description",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_location_observed_at",
      "p_permission",
      "p_services_enabled",
      "p_location_result",
      "p_provider",
      "p_replay_only",
      "p_note_action",
      "p_employee_note"
    ],
    "defaults": "'preserve'::text, NULL::text",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.update_employee_note_legacy_impl(uuid,text)",
    "body_sha256": "c6b60b5cdb8d81514d3216e68770561a248015673158c92b36b8cc033e60ee65",
    "argument_names": [
      "p_work_session_id",
      "p_employee_note"
    ],
    "defaults": "",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "private.validate_location_observation_session()",
    "body_sha256": "8b5f6016ba6a02522cd0ab8df754eb71a89e7b3658f88797ae21293204c675a2",
    "argument_names": [],
    "defaults": "",
    "result_type": "trigger",
    "definer": false,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": false
  },
  {
    "signature": "public.attendance_capability()",
    "body_sha256": "38c8fc13edede4ac7006d01c1e5688076df6119cfea75c0852ae0e5bedf313d5",
    "argument_names": [],
    "defaults": "",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "s",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "public.check_in(text,text,timestamptz,text,numeric,numeric,numeric,text)",
    "body_sha256": "eef856e40b058f4c6a6823791a03fb978294ea2c23296685e92037996590a7c7",
    "argument_names": [
      "p_location_context",
      "p_site_description",
      "p_device_observed_at",
      "p_idempotency_key",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_provider"
    ],
    "defaults": "NULL::numeric, NULL::numeric, NULL::numeric, NULL::text",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "public.check_in_v2(text,timestamptz,text,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean)",
    "body_sha256": "7eb3a5dc1c77525c571d760d171ba2fe4f664d4665b6133b5510d0477e0d60f8",
    "argument_names": [
      "p_idempotency_key",
      "p_device_observed_at",
      "p_site_description",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_location_observed_at",
      "p_permission",
      "p_services_enabled",
      "p_location_result",
      "p_provider",
      "p_replay_only"
    ],
    "defaults": "NULL::timestamp with time zone, NULL::text, NULL::numeric, NULL::numeric, NULL::numeric, NULL::timestamp with time zone, 'unknown'::text, NULL::boolean, 'unknown'::text, 'unknown'::text, false",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\"",
      "TimeZone=UTC"
    ],
    "client_execute": true
  },
  {
    "signature": "public.check_out(uuid,text,timestamptz,numeric,numeric,numeric,text)",
    "body_sha256": "6da708882177129cddf0bef2a38a35870d694bbd18b781fb37f12f81ac10ebc4",
    "argument_names": [
      "p_work_session_id",
      "p_idempotency_key",
      "p_device_observed_at",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_provider"
    ],
    "defaults": "NULL::timestamp with time zone, NULL::numeric, NULL::numeric, NULL::numeric, NULL::text",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "public.check_out_v2(uuid,text,timestamptz,numeric,numeric,numeric,timestamptz,text,boolean,text,text,boolean,text,text)",
    "body_sha256": "8de491a6eeb851af3ae83e4ce549c24027aa65eec409a7ba09f08f819d3c60c9",
    "argument_names": [
      "p_work_session_id",
      "p_idempotency_key",
      "p_device_observed_at",
      "p_latitude",
      "p_longitude",
      "p_accuracy_meters",
      "p_location_observed_at",
      "p_permission",
      "p_services_enabled",
      "p_location_result",
      "p_provider",
      "p_replay_only",
      "p_note_action",
      "p_employee_note"
    ],
    "defaults": "NULL::timestamp with time zone, NULL::numeric, NULL::numeric, NULL::numeric, NULL::timestamp with time zone, 'unknown'::text, NULL::boolean, 'unknown'::text, 'unknown'::text, false, 'preserve'::text, NULL::text",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\"",
      "TimeZone=UTC"
    ],
    "client_execute": true
  },
  {
    "signature": "public.disable_user_profile(uuid)",
    "body_sha256": "635efd334666726e6f678483e002a028a67e0a1516c87f397e56d8d6c8c55f9f",
    "argument_names": [
      "p_user_profile_id"
    ],
    "defaults": "",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "public.revoke_role_assignment(uuid)",
    "body_sha256": "2ad3d1c73ddab1acd2ebff5b681b35865245d97463bc7f60dd4350de82dcbd9a",
    "argument_names": [
      "p_role_assignment_id"
    ],
    "defaults": "",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  },
  {
    "signature": "public.save_employee_note(uuid,text,text,text,boolean)",
    "body_sha256": "a7673b496ce47e1639bfc8073e44068801d94810a2813e48af11b8f74c3f042a",
    "argument_names": [
      "p_work_session_id",
      "p_operation_key",
      "p_note_action",
      "p_employee_note",
      "p_replay_only"
    ],
    "defaults": "false",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\"",
      "TimeZone=UTC"
    ],
    "client_execute": true
  },
  {
    "signature": "public.update_employee_note(uuid,text)",
    "body_sha256": "0a26572b1de4532512161e66f121d682608202c0c22a88fe4126724e761b2130",
    "argument_names": [
      "p_work_session_id",
      "p_employee_note"
    ],
    "defaults": "",
    "result_type": "jsonb",
    "definer": true,
    "language": "plpgsql",
    "volatility": "v",
    "config": [
      "search_path=\"\""
    ],
    "client_execute": true
  }
]
$functions$::jsonb) as e(signature text, body_sha256 text, argument_names text[],
  defaults text, result_type text, definer boolean, language text, volatility text,
  config text[], client_execute boolean)
), expected_policies as (
  select * from jsonb_to_recordset($policies$
[
  {
    "table_name": "admin_audit_events",
    "policy_name": "admin_audit_events_select_company_admin",
    "qual": "((auth.uid() IS NOT NULL) AND private.current_user_is_company_admin(company_id))"
  },
  {
    "table_name": "companies",
    "policy_name": "companies_select_own_company_or_admin",
    "qual": "((auth.uid() IS NOT NULL) AND (id = private.current_company_id()) AND (private.current_user_has_role('employee'::text) OR private.current_user_is_company_admin(id)))"
  },
  {
    "table_name": "location_observations",
    "policy_name": "location_observations_select_self_or_company_admin",
    "qual": "((auth.uid() IS NOT NULL) AND (private.current_user_can_read_own_attendance(employee_profile_id) OR private.current_user_is_company_admin(company_id)))"
  },
  {
    "table_name": "role_assignments",
    "policy_name": "role_assignments_select_self_or_company_admin",
    "qual": "((auth.uid() IS NOT NULL) AND (((user_profile_id = private.current_profile_id()) AND (private.current_user_has_role('employee'::text) OR private.current_user_is_company_admin(company_id))) OR private.current_user_is_company_admin(company_id)))"
  },
  {
    "table_name": "session_events",
    "policy_name": "session_events_select_self_or_company_admin",
    "qual": "((auth.uid() IS NOT NULL) AND (private.current_user_can_read_own_attendance(employee_profile_id) OR private.current_user_is_company_admin(company_id)))"
  },
  {
    "table_name": "user_profiles",
    "policy_name": "user_profiles_select_self_or_company_admin",
    "qual": "((auth.uid() IS NOT NULL) AND (((auth_user_id = auth.uid()) AND (status = 'active'::text) AND (private.current_user_has_role('employee'::text) OR private.current_user_is_company_admin(company_id))) OR private.current_user_is_company_admin(company_id)))"
  },
  {
    "table_name": "work_sessions",
    "policy_name": "work_sessions_select_self_or_company_admin",
    "qual": "((auth.uid() IS NOT NULL) AND (private.current_user_can_read_own_attendance(employee_profile_id) OR private.current_user_is_company_admin(company_id)))"
  }
]
$policies$::jsonb) as e(table_name text, policy_name text, qual text)
), function_checks as (
  select 'function: ' || e.signature as check_name,
    coalesce(p.prokind='f' and p.proargmodes is null and p.provariadic=0
      and not p.proretset and not p.proisstrict
      and not p.proleakproof and p.proparallel='u'
      and p.proowner='postgres'::regrole
      and encode(sha256(convert_to(replace(p.prosrc,E'\r\n',E'\n'),'UTF8')),'hex')=e.body_sha256
      and coalesce(p.proargnames,'{}'::text[])=e.argument_names
      and coalesce(pg_get_expr(p.proargdefaults,0),'')=e.defaults
      and p.prorettype=to_regtype(e.result_type) and p.prosecdef=e.definer
      and l.lanname=e.language and p.provolatile::text=e.volatility
      and p.proconfig @> e.config and e.config @> p.proconfig
      and has_function_privilege('authenticated',p.oid,'EXECUTE')=e.client_execute
      and not has_function_privilege('anon',p.oid,'EXECUTE')
      and not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where a.grantee in (0,'anon'::regrole::oid,'authenticated'::regrole::oid) and a.is_grantable)
      and not exists(select 1 from aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
        where a.grantee=0 and a.privilege_type='EXECUTE'),false) as passed
  from expected_functions e left join pg_proc p on p.oid=to_regprocedure(e.signature)
  left join pg_language l on l.oid=p.prolang
), checks as (
  select * from function_checks
  union all select 'exact six-migration history',
    (select array_agg(version::text order by version) from supabase_migrations.schema_migrations)
      =array['20261013000100','20261016000100','20261017000100','20261017000200','20261021000100','20261025000100']
  union all select 'gate 1 and exactly one canonical server epoch',
    (select count(*)=1 and bool_and(singleton and write_contract=1 and deployment_epoch is not null
      and deployment_epoch::text ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
      from private.attendance_deployment)
  union all select 'no unexpected contract overloads',
    (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname||'.'||p.proname in
        (select split_part(signature,'(',1) from expected_functions))
      =(select count(*) from expected_functions)
  union all select 'private tables protected',
    (select count(*)=2 and bool_and(c.relkind='r' and c.relrowsecurity
      and c.relowner='postgres'::regrole
      and not has_table_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      and not has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      and not has_any_column_privilege('authenticated',c.oid,'SELECT,INSERT,UPDATE,REFERENCES')
      and not has_any_column_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,REFERENCES')
      and not exists(select 1 from pg_policy p where p.polrelid=c.oid))
      from pg_class c where c.oid in
        (to_regclass('private.attendance_deployment'),to_regclass('private.employee_note_operations')))
  union all select 'private schema has no API CREATE grant',
    not has_schema_privilege('authenticated','private','CREATE')
      and not has_schema_privilege('anon','private','CREATE,USAGE')
      and has_schema_privilege('authenticated','private','USAGE')
  union all select 'deployment table columns and server-owned defaults',
    (select count(*)=3 and bool_and(a.attnotnull and
      case a.attname
        when 'singleton' then a.atttypid='bool'::regtype and pg_get_expr(d.adbin,d.adrelid)='true'
        when 'deployment_epoch' then a.atttypid='uuid'::regtype and pg_get_expr(d.adbin,d.adrelid)='gen_random_uuid()'
        when 'write_contract' then a.atttypid='int4'::regtype and pg_get_expr(d.adbin,d.adrelid)='1'
        else false end)
      from pg_attribute a left join pg_attrdef d on d.adrelid=a.attrelid and d.adnum=a.attnum
      where a.attrelid=to_regclass('private.attendance_deployment') and a.attnum>0 and not a.attisdropped)
  union all select 'deployment singleton and gate constraints',
    (select count(*)=3 and bool_and(convalidated and not condeferrable and
      case conname
        when 'attendance_deployment_pkey' then contype='p' and pg_get_constraintdef(oid)='PRIMARY KEY (singleton)'
        when 'attendance_deployment_singleton_check' then contype='c' and pg_get_constraintdef(oid)='CHECK (singleton)'
        when 'attendance_deployment_write_contract_check' then contype='c' and pg_get_constraintdef(oid)='CHECK ((write_contract = ANY (ARRAY[1, 2])))'
        else false end)
      from pg_constraint where conrelid=to_regclass('private.attendance_deployment'))
  union all select 'deployment statement fence trigger',
    (select count(*)=1 and bool_and(t.tgname='attendance_deployment_change_lock'
      and t.tgfoid=to_regprocedure('private.lock_attendance_deployment_change()')
      and t.tgtype=30 and t.tgenabled='O' and t.tgnargs=0 and t.tgqual is null
      and not t.tgdeferrable and t.tgconstraint=0)
      from pg_trigger t where t.tgrelid=to_regclass('private.attendance_deployment') and not t.tgisinternal)
  union all select 'application tables RLS and read-only API grants',
    (select count(*)=7 and bool_and(c.relkind='r' and c.relrowsecurity
      and c.relowner='postgres'::regrole
      and has_table_privilege('authenticated',c.oid,'SELECT')
      and not has_table_privilege('authenticated',c.oid,'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      and not has_any_column_privilege('authenticated',c.oid,'INSERT,UPDATE,REFERENCES')
      and not has_table_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
      and not has_any_column_privilege('anon',c.oid,'SELECT,INSERT,UPDATE,REFERENCES'))
      from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relname in (select table_name from expected_policies))
  union all select 'API roles cannot bypass RLS or assume owner',
    (select count(*)=2 and bool_and(not r.rolsuper and not r.rolbypassrls
      and not r.rolcreaterole and not r.rolcreatedb and not r.rolreplication
      and not pg_has_role(r.oid,'postgres'::regrole,'MEMBER')
      and not exists(select 1 from pg_roles privileged where
        (privileged.rolsuper or privileged.rolbypassrls) and pg_has_role(r.oid,privileged.oid,'MEMBER')))
      from pg_roles r where r.rolname in ('anon','authenticated'))
  union all select 'exact owner-scoped RLS policies',
    (select count(*)=7 and bool_and(p.oid is not null and p.polcmd='r' and p.polpermissive
      and p.polroles=array['authenticated'::regrole::oid] and p.polwithcheck is null
      and pg_get_expr(p.polqual,p.polrelid)=e.qual)
      from expected_policies e left join pg_policy p
        on p.polrelid=to_regclass('public.'||e.table_name) and p.polname=e.policy_name)
    and (select count(*)=7 from pg_policy p where p.polrelid in
      (select to_regclass('public.'||table_name) from expected_policies))
  union all select 'History composite relationships',
    (select count(*)=2 and bool_and(c.contype='f' and c.convalidated
      and not c.condeferrable and c.confdeltype='r' and c.confupdtype='a'
      and c.confrelid=to_regclass('public.user_profiles')
      and (select array_agg(a.attname::text order by u.ord) from unnest(c.conkey) with ordinality u(num,ord)
        join pg_attribute a on a.attrelid=c.conrelid and a.attnum=u.num)
        =case c.conname when 'work_sessions_employee_company_fk' then array['employee_profile_id','company_id']
          else array['user_profile_id','company_id'] end
      and (select array_agg(a.attname::text order by u.ord) from unnest(c.confkey) with ordinality u(num,ord)
        join pg_attribute a on a.attrelid=c.confrelid and a.attnum=u.num)=array['id','company_id'])
      from pg_constraint c where
        (c.conrelid=to_regclass('public.work_sessions') and c.conname='work_sessions_employee_company_fk') or
        (c.conrelid=to_regclass('public.role_assignments') and c.conname='role_assignments_profile_company_fk'))
  union all select 'History projection types and nullability',
    (select count(*)=10 and bool_and(a.atttypid=case
      when a.attname in ('id','employee_profile_id','company_id') then 'uuid'::regtype
      when a.attname in ('started_at','ended_at') then 'timestamptz'::regtype else 'text'::regtype end
      and a.attnotnull=(a.attname not in ('ended_at','site_description','employee_note')))
      from pg_attribute a where a.attrelid=to_regclass('public.work_sessions') and not a.attisdropped
      and a.attname in ('id','employee_profile_id','company_id','location_context','lifecycle_status',
        'started_at','ended_at','site_description','employee_note','review_status'))
  union all select 'additive nullable columns retained',
    (select count(*)=5 and bool_and(not a.attnotnull and a.atttypid=case
      when a.attname='metadata' then 'jsonb'::regtype
      when a.attname='factory_radius_meters' then 'int4'::regtype
      when a.attname='employee_note' then 'text'::regtype else 'numeric'::regtype end)
      from pg_attribute a where not a.attisdropped and
        ((a.attrelid=to_regclass('public.companies') and a.attname in ('factory_latitude','factory_longitude','factory_radius_meters'))
        or (a.attrelid=to_regclass('public.work_sessions') and a.attname='employee_note')
        or (a.attrelid=to_regclass('public.session_events') and a.attname='metadata')))
  union all select 'existing session shapes remain compatible', not exists(
    select 1 from public.work_sessions where
      location_context not in ('factory','external_worksite','location_unverified') or
      lifecycle_status not in ('active','closed_manual','closed_automatic','closed_admin','voided') or
      review_status not in ('normal','anomaly_open','correction_pending','reviewed','corrected','disputed') or
      (site_description is not null and char_length(site_description)>500) or
      (employee_note is not null and char_length(employee_note)>1000) or
      not isfinite(started_at) or (ended_at is not null and not isfinite(ended_at)) or
      (lifecycle_status='active')<>(ended_at is null) or ended_at<started_at)
)
select check_name,coalesce(passed,false) as passed from checks order by check_name;
rollback;
