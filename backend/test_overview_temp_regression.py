"""Large snapshots must not be copied into metadata sort/group records.

SQLite can flatten a projected JSON expression and defer its output until after
DISTINCT/ORDER BY or GROUP BY. A narrow SQL result alone does not keep the raw
snapshot out of the intermediate record. Bound the intermediate row length to
make that regression deterministic without filling a machine's temporary disk.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import json
import sqlite3

import pytest

from . import app as core
from .test_api import c, headers, login


@pytest.fixture
def large_snapshot_school(c, monkeypatch):
    monkeypatch.setattr(core, 'now', lambda: datetime(2026, 11, 5, 4, tzinfo=timezone.utc))
    auth = headers(login(c))
    snapshot = core.canonical({'subject_id': 'math', 'type': 'single',
                               'media': {'figure': 'data:image/png;base64,' + 'A' * 1_000_000}})
    original_db = core.db
    with original_db() as conn:
        student = core.one(conn, "SELECT id FROM users WHERE username='student'")['id']
        classroom = core.one(conn, 'SELECT id FROM classes LIMIT 1')['id']
        question = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        conn.execute("UPDATE users SET activated=1,must_change_password=0 WHERE id=?", (student,))
        conn.execute("UPDATE memberships SET status='active',visibility_accepted=1 WHERE user_id=?", (student,))
        records = []
        for _ in range(50):
            identifier = core.uid()
            records.append((identifier, student, identifier, question, identifier,
                            '2026-11-05T01:00:00Z', core.iso(), snapshot))
        conn.executemany('''INSERT INTO records(id,user_id,client_uuid,question_id,payload_hash,
          selected,correct,duration_seconds,answered_at,received_at,question_snapshot)
          VALUES(?,?,?,?,?,'["A"]',1,12,?,?,?)''', records)

    @contextmanager
    def bounded_db():
        with original_db() as conn:
            # The source JSON fits, but JSON + repeated subject/fallback values
            # in a flattened sorter record do not. Legitimate API output is tiny.
            conn.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, len(snapshot.encode('utf-8')) + 10)
            yield conn

    monkeypatch.setattr(core, 'db', bounded_db)
    return {'auth': auth, 'student': student, 'class_id': classroom, 'snapshot': snapshot}


def test_overview_and_export_keep_large_snapshots_out_of_metadata_sort(c, large_snapshot_school):
    school = large_snapshot_school
    filters = {'class_id': school['class_id'], 'date_from': '2026-10-07', 'date_to': '2026-11-05'}
    for subject in (None, 'math'):
        query = {**filters, **({'subject_id': subject} if subject else {})}
        response = c.get('/api/management/students/overview', params=query, headers=school['auth'])
        assert response.status_code == 200, response.text
        data = response.json()
        assert data['total'] == 1 and data['summary']['answered'] == 50
        assert data['summary']['accuracy'] == 100.0
        assert data['items'][0]['practice']['answered'] == 50
        assert len(response.content) < 20_000 and 'data:image/png' not in response.text
        exported = c.post('/api/management/students/overview/export', json=query, headers=school['auth'])
        assert exported.status_code == 200 and exported.headers['X-Export-Count'] == '1'
        assert len(exported.content) < 5_000 and b'data:image/png' not in exported.content


def test_individual_analytics_groups_only_projected_subject_and_type(c, large_snapshot_school):
    school = large_snapshot_school
    for days in (7, 30, 90):
        response = c.get('/api/management/users/' + school['student'] + '/analytics',
                         params={'days': days}, headers=school['auth'])
        assert response.status_code == 200, response.text
        data = response.json()
        assert data['summary']['answered'] == data['lifetime']['answered'] == 50
        assert [(item['subject_id'], item['answered']) for item in data['subjects']] == [('math', 50)]
        assert [(item['type'], item['answered']) for item in data['types']] == [('single', 50)]
        assert len(response.content) < 50_000 and 'data:image/png' not in response.text


def test_sqlite_legacy_flattened_ordered_distinct_control():
    """The old query shape demonstrably carries the JSON in its sort record."""
    conn = sqlite3.connect(':memory:')
    try:
        conn.execute('CREATE TABLE records(question_snapshot TEXT)')
        snapshot = json.dumps({'subject_id': 'math', 'media': 'A' * 1_000_000})
        conn.execute('INSERT INTO records VALUES(?)', (snapshot,))
        conn.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, len(snapshot) + 2)
        base = '''WITH historical AS (
          SELECT json_extract(question_snapshot,'$.subject_id') subject_id FROM records)
          SELECT DISTINCT subject_id FROM historical WHERE subject_id IS NOT NULL'''
        assert conn.execute(base).fetchall() == [('math',)]
        with pytest.raises(sqlite3.DataError, match='too big'):
            conn.execute(base + ' ORDER BY subject_id').fetchall()
    finally:
        conn.close()
