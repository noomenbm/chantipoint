"""Local deployment-fence tests; no accounts, attendance or hosted connections.

Gate/epoch changes roll back. One no-op metadata UPDATE commits solely to advance
the tuple version for the repeatable-read test; all stored values remain equal.
"""
import json
import subprocess
import time
import uuid

PSQL = ['docker', 'exec', '-i', 'supabase_db_chantipoint', 'psql', '-X', '-qAt',
        '-h', '127.0.0.1', '-U', 'postgres', '-d', 'postgres', '-v', 'ON_ERROR_STOP=1',
        '-v', 'VERBOSITY=verbose']
assertions = 0


def check(condition, message):
    global assertions
    if not condition:
        raise AssertionError(message)
    assertions += 1


def execute(sql):
    p = subprocess.run(PSQL, input=sql, text=True, encoding='utf-8', capture_output=True, timeout=25)
    if p.returncode:
        raise RuntimeError('Local fence test SQL failed (details suppressed)')
    return p.stdout.strip()


class Connection:
    def __init__(self, name, sql):
        self.name = name
        self.p = subprocess.Popen(PSQL, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, text=True, encoding='utf-8')
        self.send("begin; set local statement_timeout='15s'; set local lock_timeout='10s'; "
                  f"set local application_name='{name}'; " + sql)

    def send(self, sql):
        self.p.stdin.write(sql + '\n')
        self.p.stdin.flush()

    def ready(self):
        for line in self.p.stdout:
            if line.strip() == 'READY':
                return
        raise RuntimeError('Local connection ended before checkpoint (details suppressed)')

    def finish(self):
        if self.p.poll() is None:
            self.send('rollback;\n\\q')
            self.p.stdin.close()
            self.p.stdin = None
        return self.p.communicate(timeout=20)


HEADERS = """do $$ begin perform set_config('request.headers',jsonb_build_object(
 'x-chantipoint-attendance-epoch',(select deployment_epoch::text from private.attendance_deployment))::text,true); end $$; """
STATE = "select to_jsonb(d)::text from private.attendance_deployment d;"


def wait_for_lock(connection):
    deadline = time.monotonic() + 6
    while time.monotonic() < deadline:
        waiting = execute("select exists(select 1 from pg_stat_activity where "
                          f"application_name='{connection.name}' and wait_event_type='Lock');")
        if waiting == 't':
            return True
        time.sleep(0.05)
    return False


def main():
    original = execute(STATE)
    check(json.loads(original)['write_contract'] == 1, 'local gate must start at 1')
    prefix = 'cp_activation_' + uuid.uuid4().hex
    connections = []
    try:
        caller = Connection(prefix + '_caller', HEADERS + "select private.require_attendance_epoch(); select 'READY';")
        connections.append(caller)
        caller.ready()
        operator = Connection(prefix + '_operator', "update private.attendance_deployment set "
                              "deployment_epoch=gen_random_uuid(),write_contract=2 where singleton; select 'READY';")
        connections.append(operator)
        check(wait_for_lock(operator), 'epoch/gate update must wait for submitted transaction guard')
        caller.finish()
        operator.ready()
        late = Connection(prefix + '_late', HEADERS + "select private.require_attendance_epoch(); select 'READY';")
        connections.append(late)
        check(wait_for_lock(late), 'new transaction guard must wait for uncommitted epoch/gate change')
        operator.finish()  # Rollback: gate 2 is never committed.
        late.ready()
        late.finish()
        check(execute(STATE) == original, 'rollback must retain exact deployment values')

        stale = Connection(prefix + '_snapshot',
                           "set transaction isolation level repeatable read; " + HEADERS + "select 'READY';")
        connections.append(stale)
        stale.ready()
        # Same values, newer tuple version: proves stale FOR SHARE fails closed.
        execute('begin; update private.attendance_deployment set write_contract=write_contract where singleton; commit;')
        stale.send('select private.require_attendance_epoch();\n\\q')
        stale.p.stdin.close()
        stale.p.stdin = None
        _, errors = stale.p.communicate(timeout=20)
        check(stale.p.returncode != 0 and '40001:' in errors,
              'repeatable-read guard must reject a deployment row changed since its snapshot')
        check(execute(STATE) == original, 'MVCC test must leave all stored deployment values unchanged')
    finally:
        for connection in reversed(connections):
            if connection.p.poll() is None:
                try:
                    connection.finish()
                except Exception:
                    connection.p.kill()
                    connection.p.communicate(timeout=10)
    check(execute('select private.attendance_write_contract();') == '1', 'final local gate must remain 1')
    print(f'PASS: 2 blocked overlaps and stale snapshot rejection; {assertions} assertions; gate 1; exact deployment values retained')


if __name__ == '__main__':
    main()
