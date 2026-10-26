"""Offline audit: preserve the six-state inspection's applicable invariants.

No database, Docker, hosted connection, application RPC or persistent mutation.
The seven-state SQL additionally requires independently supplied gate/epoch.
"""
import json
from pathlib import Path
import re

import attendance_activation_inspection_test as six


ROOT = Path(__file__).resolve().parents[3]


def without_manifest(sql):
    return re.sub(r'jsonb_to_recordset\(\$functions\$.*?\$functions\$::jsonb\)',
                  'FUNCTION_MANIFEST', sql, count=1, flags=re.S)


def main():
    old = six.INSPECTION.read_text(encoding='utf-8')
    new = (ROOT / 'supabase/inspection/active_session_notes_v2_deployment_check.sql').read_text(
        encoding='utf-8')
    six.VERSIONS = [*six.VERSIONS, '20261025000200']
    expected = six.source_functions()
    manifest = json.loads(re.search(
        r'jsonb_to_recordset\(\$functions\$(.*?)\$functions\$::jsonb\)', new, re.S).group(1))
    assert manifest == expected and len(manifest) == 38
    # Seven-state inspection must preserve every prior invariant other than
    # the reviewed function update, migration count, and explicitly selected gate.
    old_tail = without_manifest(old)[without_manifest(old).index('begin read only;'):]
    new_tail = without_manifest(new)[without_manifest(new).index('begin read only;'):]
    new_tail = re.sub(
        r"  union all select 'predeployment epoch preserved',.*?(?=  union all select 'no unexpected contract overloads',)",
        '', new_tail, count=1, flags=re.S)
    new_tail = new_tail.replace("'exact seven-migration history'", "'exact six-migration history'")
    new_tail = new_tail.replace(", '20261025000200'", '').replace(",'20261025000200'", '')
    new_tail = new_tail.replace("'exact approved gate and one canonical server epoch'",
                                "'gate 1 and exactly one canonical server epoch'")
    new_tail = new_tail.replace(
        "write_contract=current_setting('chantipoint.inspection.expected_gate')::integer\n"
        "      and current_setting('chantipoint.inspection.expected_gate') in ('1','2')",
        'write_contract=1')
    assert new_tail == old_tail, 'An applicable six-state inspection invariant changed'
    for required in ('predeployment epoch preserved', 'note protocol columns and defaults',
                     'validated exact note protocol constraint', 'existing note evidence protocol shapes'):
        assert new.count("union all select '" + required + "'") == 1
    assert "current_setting('chantipoint.inspection.expected_epoch')::uuid" in new
    assert new.rstrip().endswith('rollback;')
    print('PASS: 38 function contracts match all seven migration sources; all prior applicable '
          'checks retained; four additional note/epoch checks; explicit gate required.')


if __name__ == '__main__':
    main()
