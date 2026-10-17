"""Real local SQL concurrency; stdlib only. No resets, images, or credentials.

Temporarily enables v2 locally and commits fresh fictional, unconfigured-company
fixtures so independent transactions can see them. Finally restores the exact
gate and deletes only those checked-new fixture IDs. Never targets hosted DBs.
"""
import json
import subprocess
import time
import uuid
from datetime import datetime, timezone

PSQL = ["docker", "exec", "-i", "supabase_db_chantipoint", "psql", "-X", "-qAt",
        "-h", "127.0.0.1", "-U", "postgres", "-d", "postgres",
        "-v", "ON_ERROR_STOP=1", "-v", "VERBOSITY=verbose"]
COUNTS = """select jsonb_build_array(
 (select count(*) from auth.users),(select count(*) from public.companies),
 (select count(*) from public.user_profiles),(select count(*) from public.role_assignments),
 (select count(*) from public.work_sessions),(select count(*) from public.session_events),
 (select count(*) from public.location_observations),(select count(*) from public.admin_audit_events));"""
assertions = 0


def execute(sql):
    result = subprocess.run(PSQL, input=sql, text=True, encoding="utf-8", capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return result.stdout.strip()


def check(condition, message):
    global assertions
    if not condition:
        raise AssertionError(message)
    assertions += 1


def main():
    before_counts = execute(COUNTS)
    gate_query = "select pg_get_functiondef('private.attendance_write_contract()'::regprocedure);"
    original_gate = execute(gate_query)
    check(execute("select private.attendance_write_contract();") == "1", "original gate must be legacy")
    check(execute("select count(*) from supabase_migrations.schema_migrations where version='20261017000100';") == "1",
          "reviewed migration must already be applied locally")
    company, auth, profile = (str(uuid.uuid4()) for _ in range(3))
    prefix = "cp_contract_" + uuid.uuid4().hex
    check(execute(f"select count(*) from public.companies where id='{company}';") == "0", "company must be new")
    check(execute(f"select count(*) from auth.users where id='{auth}';") == "0", "Auth fixture must be new")
    check(execute(f"select count(*) from public.user_profiles where id='{profile}';") == "0", "profile must be new")
    observed = datetime.now(timezone.utc).isoformat()

    def command(operation, key, session=None):
        target = "" if session is None else f"p_work_session_id=>'{session}',"
        return f"select public.{operation}_v2({target} p_idempotency_key=>'{key}',p_device_observed_at=>'{observed}'::timestamptz);"

    def authenticated(sql, name=""):
        return ("begin; set local statement_timeout='15s'; set local lock_timeout='10s'; "
                f"set local application_name='{name}'; set local role authenticated; "
                f"select set_config('request.jwt.claim.sub','{auth}',true); "
                f"select set_config('request.jwt.claim.role','authenticated',true); {sql} commit;")

    def decode(code, stdout, stderr):
        if code:
            return {"error": stderr}
        return json.loads(next(line for line in stdout.splitlines() if line.startswith("{")))

    def accepted(sql):
        return decode(0, execute(authenticated(sql)), "")

    def parallel(statements):
        # Lock the employee row, launch two independent transactions, and prove
        # both are blocked before release. Sequential calls cannot pass this.
        holder = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, encoding="utf-8")
        workers = []
        try:
            holder.stdin.write("begin; set local statement_timeout='15s'; set local lock_timeout='10s'; "
                               f"select 1 from public.user_profiles where id='{profile}' for update; select 'LOCK_HELD';\n")
            holder.stdin.flush()
            while True:
                line = holder.stdout.readline()
                if line.strip() == "LOCK_HELD":
                    break
                if not line:
                    raise RuntimeError("lock holder failed: " + holder.stderr.read())
            names = [prefix + "_" + str(i) for i in range(2)]
            for statement, name in zip(statements, names):
                worker = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                          stderr=subprocess.PIPE, text=True, encoding="utf-8")
                worker.stdin.write(authenticated(statement, name))
                worker.stdin.close()
                worker.stdin = None
                workers.append(worker)
            deadline = time.monotonic() + 8
            waiting = "0"
            while time.monotonic() < deadline:
                waiting = execute("select count(*) from pg_stat_activity where application_name in "
                                  f"('{names[0]}','{names[1]}') and wait_event_type='Lock';")
                if waiting == "2":
                    break
                time.sleep(0.1)
            check(waiting == "2", "both transactions must overlap and wait for the employee lock")
        finally:
            if holder.poll() is None:
                holder.stdin.write("rollback;\n\\q\n")
                holder.stdin.close()
                holder.stdin = None
            holder.communicate(timeout=20)
            outcomes = []
            for worker in workers:
                stdout, stderr = worker.communicate(timeout=25)
                outcomes.append(decode(worker.returncode, stdout, stderr))
        return outcomes

    setup_attempted = False
    try:
        setup_attempted = True
        execute(f"""begin;
select pg_advisory_xact_lock(174811,2);
create or replace function private.attendance_write_contract() returns integer
language sql volatile set search_path='' as $$ select 2 $$;
insert into public.companies(id,name) values('{company}','Fictional concurrency test company');
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
values('{auth}','authenticated','authenticated','concurrency.{auth}@example.test','not-a-password',statement_timestamp());
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
values('{profile}','{auth}','{company}','Fictional concurrency employee','concurrency.{auth}@example.test');
insert into public.role_assignments(user_profile_id,company_id,role) values('{profile}','{company}','employee');
commit;""")
        check(execute(f"select factory_latitude is null and factory_longitude is null and factory_radius_meters is null from public.companies where id='{company}';") == "t",
              "concurrency test never configures a factory")

        results = parallel([command("check_in", "concurrent-same-in-001")] * 2)
        check(sorted(r.get("status", "error") for r in results) == ["created", "idempotent_replay"], "same-key check-in results: " + str(results))
        session = results[0]["session_id"]
        check(session == results[1]["session_id"], "same-key check-in returns one session")
        check(results[0]["event_id"] == results[1]["event_id"], "same-key check-in returns one event")
        check(execute(f"select count(*) from public.location_observations where work_session_id='{session}';") == "1", "same-key race creates one observation")
        accepted(command("check_out", "concurrent-finish-out-001", session))
        print("PASS: concurrent identical check-ins", flush=True)

        results = parallel([command("check_in", "concurrent-new-in-001"), command("check_in", "concurrent-new-in-002")])
        check(sum(r.get("status") == "created" for r in results) == 1, "different-key race creates exactly one session")
        check(sum("23505: active_session_exists" in r.get("error", "") for r in results) == 1, "expected active-session conflict: " + str(results))
        session = next(r["session_id"] for r in results if r.get("status") == "created")
        check(execute(f"select count(*) from public.work_sessions where employee_profile_id='{profile}' and lifecycle_status='active';") == "1", "one active session survives")
        print("PASS: concurrent different-key check-ins", flush=True)

        results = parallel([command("check_out", "concurrent-new-out-001", session), command("check_out", "concurrent-new-out-002", session)])
        check(sum(r.get("status") == "closed" for r in results) == 1, "checkout closes exactly once")
        check(sum("P0001: session_not_active" in r.get("error", "") for r in results) == 1, "expected closed-session conflict: " + str(results))
        check(execute(f"select count(*) from public.session_events where work_session_id='{session}' and event_type='manual_checkout';") == "1", "one closure event survives")
        print("PASS: concurrent different-key checkouts", flush=True)

        session = accepted(command("check_in", "concurrent-last-in-001"))["session_id"]
        results = parallel([command("check_out", "concurrent-same-out-001", session)] * 2)
        check(sorted(r.get("status", "error") for r in results) == ["closed", "idempotent_replay"], "same-key checkout results: " + str(results))
        check(results[0]["ended_at"] == results[1]["ended_at"], "same-key checkout keeps original end time")
        check(results[0]["event_id"] == results[1]["event_id"], "same-key checkout keeps original event")
        check(execute(f"select count(*) from public.location_observations where work_session_id='{session}';") == "2", "only arrival and one departure observation survive")
        print("PASS: concurrent identical checkouts", flush=True)
    finally:
        if setup_attempted:
            # Fresh UUIDs were checked absent before setup; cleanup never touches
            # existing records, audit history, migrations, schemas, or volumes.
            execute(f"""begin; set local lock_timeout='10s';
select pg_advisory_xact_lock(174811,2);
{original_gate};
delete from public.location_observations where employee_profile_id='{profile}' and company_id='{company}';
delete from public.session_events where employee_profile_id='{profile}' and company_id='{company}';
delete from public.work_sessions where employee_profile_id='{profile}' and company_id='{company}';
delete from public.role_assignments where user_profile_id='{profile}' and company_id='{company}';
delete from public.user_profiles where id='{profile}' and auth_user_id='{auth}' and company_id='{company}';
delete from public.companies where id='{company}';
delete from auth.users where id='{auth}';
commit;""")
        check(execute(COUNTS) == before_counts, "all eight table counts restored")
        check(execute(gate_query) == original_gate, "original gate definition restored exactly")
    print(f"PASS: 4 concurrent scenarios; {assertions} assertions; fixtures removed; legacy gate restored")


if __name__ == "__main__":
    main()
