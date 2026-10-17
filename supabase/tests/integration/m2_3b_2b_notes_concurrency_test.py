"""Local, real overlapping note/checkout transactions; no images or credentials.

Uses the existing test transport. Only checked-new fictional fixture IDs are
committed/removed; no factory configuration. The original gate is restored.
"""
import json
import subprocess
import time
import uuid
from datetime import datetime, timezone

import m2_3b_2a_concurrency_test as db


def main():
    before_counts = db.execute(db.COUNTS)
    gate_query = "select pg_get_functiondef('private.attendance_write_contract()'::regprocedure);"
    original_gate = db.execute(gate_query)
    db.check(db.execute("select private.attendance_write_contract();") == "1", "gate starts in legacy mode")
    db.check(db.execute("select count(*) from supabase_migrations.schema_migrations where version='20261017000200';") == "1",
             "employee-note migration must already be applied locally")
    company, auth, profile = (str(uuid.uuid4()) for _ in range(3))
    for table, key in (("public.companies", company), ("auth.users", auth), ("public.user_profiles", profile)):
        db.check(db.execute(f"select count(*) from {table} where id='{key}';") == "0", "fixture ID must be new")
    prefix = "cp_notes_" + uuid.uuid4().hex
    observed = datetime.now(timezone.utc).isoformat()

    def authenticated(sql, name=""):
        return ("begin; set local statement_timeout='15s'; set local lock_timeout='10s'; "
                f"set local application_name='{name}'; set local role authenticated; "
                f"select set_config('request.jwt.claim.sub','{auth}',true); "
                f"select set_config('request.jwt.claim.role','authenticated',true); {sql}")

    def decode(code, stdout, stderr):
        return {"error": stderr} if code else json.loads(next(line for line in stdout.splitlines() if line.startswith("{")))

    def accepted(sql):
        return decode(0, db.execute(authenticated(sql) + " commit;"), "")

    def start(key):
        return accepted(f"select public.check_in_v2('{key}',p_device_observed_at=>'{observed}'::timestamptz);")["session_id"]

    def note(session, text):
        return f"select public.update_employee_note('{session}','{text}');"

    def checkout(session, key, action="preserve", text=None):
        # All text comes from fixed test literals, not employee data/input.
        value = "null" if text is None else "'" + text + "'"
        return (f"select public.check_out_v2('{session}','{key}',p_device_observed_at=>'{observed}'::timestamptz,"
                f"p_note_action=>'{action}',p_employee_note=>{value});")

    def overlap(first_sql, second_sql):
        """First RPC has executed but not committed; prove the second waits."""
        first = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True, encoding="utf-8")
        second = None
        ready = False
        first_output = []
        try:
            first.stdin.write(authenticated(first_sql) + " select 'OPERATION_READY';\n")
            first.stdin.flush()
            while True:
                line = first.stdout.readline()
                if not line:
                    raise RuntimeError("first transaction failed: " + first.stderr.read())
                first_output.append(line)
                if line.strip() == "OPERATION_READY":
                    ready = True
                    break
            second_name = prefix + "_waiting"
            second = subprocess.Popen(db.PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.PIPE, text=True, encoding="utf-8")
            second.stdin.write(authenticated(second_sql, second_name) + " commit;")
            second.stdin.close()
            second.stdin = None
            deadline = time.monotonic() + 8
            waiting = "0"
            while time.monotonic() < deadline:
                waiting = db.execute("select count(*) from pg_stat_activity "
                                     f"where application_name='{second_name}' and wait_event_type='Lock';")
                if waiting == "1":
                    break
                time.sleep(0.1)
            db.check(waiting == "1", "second RPC must overlap and wait for first transaction")
        finally:
            if first.poll() is None:
                first.stdin.write(("commit;" if ready else "rollback;") + "\n\\q\n")
                first.stdin.close()
                first.stdin = None
            tail, first_errors = first.communicate(timeout=20)
            second_output, second_errors = second.communicate(timeout=25) if second else ("", "")
        return (decode(first.returncode, "".join(first_output) + tail, first_errors),
                decode(second.returncode, second_output, second_errors))

    setup_attempted = False
    try:
        setup_attempted = True
        db.execute(f"""begin;
select pg_advisory_xact_lock(174811,2);
create or replace function private.attendance_write_contract() returns integer language sql volatile set search_path='' as $$ select 2 $$;
insert into public.companies(id,name) values('{company}','Fictional note concurrency company');
insert into auth.users(id,aud,role,email,encrypted_password,email_confirmed_at)
values('{auth}','authenticated','authenticated','notes.{auth}@example.test','not-a-password',statement_timestamp());
insert into public.user_profiles(id,auth_user_id,company_id,display_name,email)
values('{profile}','{auth}','{company}','Fictional note employee','notes.{auth}@example.test');
insert into public.role_assignments(user_profile_id,company_id,role) values('{profile}','{company}','employee');
commit;""")
        db.check(db.execute(f"select factory_latitude is null and factory_longitude is null and factory_radius_meters is null from public.companies where id='{company}';") == "t",
                 "no factory configuration in committed concurrency fixtures")

        session = start("notes-race-preserve-in")
        saved, closed = overlap(note(session, "Saved before checkout"), checkout(session, "notes-race-preserve-out"))
        db.check(saved.get("status") == "updated" and closed.get("status") == "closed", "save then checkout both succeed")
        db.check(db.execute(f"select employee_note from public.work_sessions where id='{session}';") == "Saved before checkout",
                 "preserve sees the committed active-session save")
        print("PASS: note save overlaps checkout preserve", flush=True)

        session = start("notes-race-final-in")
        closed, rejected = overlap(checkout(session, "notes-race-final-out", "replace", "Final checkout note"), note(session, "Late edit"))
        db.check(closed.get("status") == "closed", "final note checkout succeeds")
        db.check("P0001: session_not_active" in rejected.get("error", ""), "waiting edit rejects after checkout: " + str(rejected))
        db.check(db.execute(f"select employee_note from public.work_sessions where id='{session}';") == "Final checkout note",
                 "waiting edit cannot overwrite final note")
        print("PASS: checkout final replacement overlaps late note save", flush=True)

        session = start("notes-race-edits-in")
        first, second = overlap(note(session, "First active save"), note(session, "Second active save"))
        db.check(first.get("status") == second.get("status") == "updated", "both serialized active saves succeed")
        db.check(db.execute(f"select employee_note from public.work_sessions where id='{session}';") == "Second active save",
                 "last serialized active save wins without versions")
        accepted(checkout(session, "notes-race-edits-out", "clear"))
        print("PASS: overlapping active note saves serialize", flush=True)

        session = start("notes-race-replay-in")
        command = checkout(session, "notes-race-replay-out", "replace", "One immutable final note")
        first, replay = overlap(command, command)
        db.check(first.get("status") == "closed" and replay.get("status") == "idempotent_replay", "same final-note command replays")
        db.check(first.get("event_id") == replay.get("event_id") and first.get("ended_at") == replay.get("ended_at"),
                 "replay returns same event and acceptance time")
        db.check(db.execute(f"select count(*) from public.location_observations where work_session_id='{session}';") == "2",
                 "concurrent final-note replay adds no evidence")
        print("PASS: overlapping identical final-note checkouts", flush=True)

        session = start("notes-race-conflict-in")
        first, conflict = overlap(checkout(session, "notes-race-conflict-out", "replace", "Accepted final note"),
                                  checkout(session, "notes-race-conflict-out", "replace", "Conflicting final note"))
        db.check(first.get("status") == "closed", "first checkout accepted")
        db.check("23505: idempotency_key_conflict" in conflict.get("error", ""), "conflicting final text is rejected: " + str(conflict))
        db.check(db.execute(f"select employee_note from public.work_sessions where id='{session}';") == "Accepted final note",
                 "conflicting retry cannot mutate accepted note")
        print("PASS: overlapping changed-payload final-note checkouts", flush=True)
        db.check(db.execute(f"select count(*) from public.session_events where company_id='{company}';") == "10",
                 "five sessions have only arrival/checkout events, no note-edit events")
        db.check(db.execute(f"select count(*) from public.admin_audit_events where company_id='{company}';") == "0",
                 "ordinary note saves generate no admin audit records")
    finally:
        if setup_attempted:
            db.execute(f"""begin; set local lock_timeout='10s';
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
        db.check(db.execute(db.COUNTS) == before_counts, "all eight table counts restored")
        db.check(db.execute(gate_query) == original_gate, "original gate definition restored exactly")
    print(f"PASS: 5 real overlapping scenarios; {db.assertions} assertions; own fixtures removed; legacy gate restored")


if __name__ == "__main__":
    main()
