"""Class-first roster privacy and aggregate overview/export regressions."""
import csv
from datetime import datetime, timezone
import io
import json

import pytest

from . import app as core
from .test_api import c, headers, login
from .student_overview import _cohort, _learning_sql, _overview

NOW = datetime(2026, 11, 4, 4, tzinfo=timezone.utc)
PRIVATE = 'private-selected-answer-image-must-never-leave-the-record'


def clone_user(conn, template, username, name=None, role='student', enabled=1):
    row = {**template, 'id': core.uid(), 'username': username, 'name': name or username,
           'role': role, 'enabled': enabled, 'deleted_at': None, 'activated': 1,
           'must_change_password': 0, 'subject_group_id': 'group-mechanics',
           'birth_year': 2008, 'target': PRIVATE, 'consent_version': PRIVATE}
    conn.execute('INSERT INTO users(' + ','.join(row) + ') VALUES(' + ','.join('?' for _ in row) + ')', list(row.values()))
    return row['id']


def membership(conn, class_id, user_id, status='active', confirmed=True, class_name=''):
    conn.execute('''INSERT INTO memberships(id,class_id,user_id,status,visibility_accepted,class_name,created_at)
      VALUES(?,?,?,?,?,?,?)''', (core.uid(), class_id, user_id, status, int(confirmed), class_name, core.iso()))


def record(conn, student, question, at, correct, seconds, subject=None):
    identifier = core.uid()
    snapshot = {} if subject is None else {'subject_id': subject, 'type': 'single', 'stem': PRIVATE, 'media': {PRIVATE: PRIVATE}}
    conn.execute('''INSERT INTO records(id,user_id,client_uuid,question_id,payload_hash,selected,correct,
      duration_seconds,answered_at,received_at,question_snapshot) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
                 (identifier, student, identifier, question, identifier, json.dumps([PRIVATE]), correct,
                  seconds, at, NOW.isoformat(), core.canonical(snapshot)))


@pytest.fixture
def population(c, monkeypatch):
    monkeypatch.setattr(core, 'now', lambda: NOW)
    auth = headers(login(c))
    with core.db() as conn:
        classroom = core.one(conn, 'SELECT * FROM classes LIMIT 1')
        template = core.one(conn, "SELECT * FROM users WHERE username='student'")
        alice = template['id']
        conn.execute("UPDATE users SET name='Alice',activated=1,must_change_password=0,subject_group_id='group-mechanics' WHERE id=?", (alice,))
        conn.execute("UPDATE memberships SET status='active',visibility_accepted=1,class_name='班内Alice' WHERE user_id=?", (alice,))
        bob = clone_user(conn, template, 'bob-account', 'Bob')
        zero = clone_user(conn, template, 'zero-account', 'Zero', enabled=0)
        pending = clone_user(conn, template, 'pending-account', 'Pending')
        unconfirmed = clone_user(conn, template, 'unconfirmed-account', 'Unconfirmed')
        left = clone_user(conn, template, 'left-account', 'Left')
        for student, status, confirmed in [(bob, 'active', True), (zero, 'active', True),
                                           (pending, 'pending_confirmation', False),
                                           (unconfirmed, 'active', False), (left, 'left', True)]:
            membership(conn, classroom['id'], student, status, confirmed)
        math = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        english = core.one(conn, "SELECT id FROM questions WHERE subject_id='english' LIMIT 1")['id']
        for at, correct, seconds in [('2026-11-02T15:59:59.999999Z', 0, 999),
                                     ('2026-11-02T16:00:00Z', 1, 10),
                                     ('2026-11-03T15:59:59.999999Z', 0, 30),
                                     ('2026-11-03T16:00:00Z', 1, 999)]:
            record(conn, alice, math, at, correct, seconds, 'math')
        record(conn, alice, english, '2026-11-03T01:00:00Z', 0, 20, 'english')
        record(conn, bob, math, '2026-11-03T02:00:00+00:00', 1, 5)
        for student in (left, pending, unconfirmed):
            record(conn, student, math, '2026-11-03T03:00:00Z', 1, 5000, 'math')
        # Reclassification must not rewrite the historical scope of snapshots.
        conn.execute("UPDATE questions SET subject_id='english',knowledge_id='english-basic',type='multiple',status='deleted' WHERE id=?", (math,))
    return {'auth': auth, 'class_id': classroom['id'], 'teacher_id': classroom['teacher_id'],
            'alice': alice, 'bob': bob, 'zero': zero, 'pending': pending,
            'unconfirmed': unconfirmed, 'left': left, 'math': math, 'template': template}


def overview(c, p, **params):
    return c.get('/api/management/students/overview', headers=p['auth'], params={
        'class_id': p['class_id'], 'date_from': '2026-11-03', 'date_to': '2026-11-03', **params})


def assert_private_absent(value):
    forbidden = {'birth_year', 'target', 'consent_version', 'password_hash', 'selected', 'question_snapshot',
                 'answer', 'stem', 'media', 'result', 'access_hash', 'refresh_hash'}
    if isinstance(value, dict):
        assert not forbidden.intersection(value)
        for item in value.values():
            assert_private_absent(item)
    elif isinstance(value, list):
        for item in value:
            assert_private_absent(item)
    assert PRIVATE not in str(value)


def test_class_directory_counts_pagination_and_account_loading_are_separate(c, population):
    p = population
    with core.db() as conn:
        for name in ('Z班', '归档班'):
            conn.execute('''INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,archived,created_at)
              VALUES(?,?,?,'group-mechanics','2026',?,?,?)''',
                         (core.uid(), name, p['teacher_id'], core.uid(), int(name == '归档班'), core.iso()))
    response = c.get('/api/management/student-classes', headers=p['auth'], params={'page_size': 1})
    assert response.status_code == 200, response.text
    data = response.json()
    assert data['total'] == 2 and data['pages'] == 2 and len(data['items']) == 1
    current = data['items'][0]
    assert current['student_count'] == 5 and current['formal_student_count'] == 3 and current['pending_student_count'] == 2
    assert data['unassigned']['student_count'] == 1  # left-only member is not a current-class account.
    assert 'items' not in current and 'students' not in current
    archived = c.get('/api/management/student-classes?class_status=archived', headers=p['auth']).json()
    assert archived['total'] == 1 and archived['items'][0]['archived'] is True
    assert c.get('/api/management/students/page', headers=p['auth']).status_code == 422
    result = c.get('/api/management/students/page', headers=p['auth'], params={'class_id': p['class_id'], 'page_size': 2}).json()
    assert result['total'] == 5 and result['pages'] == 3 and len(result['items']) == 2
    assert [s['name'] for s in result['items']] == ['Alice', 'Bob']
    assert_private_absent(result)
    pending = c.get('/api/management/students/page', headers=p['auth'], params={'class_id': p['class_id'], 'membership_status': 'pending'}).json()
    assert {s['id'] for s in pending['items']} == {p['pending'], p['unconfirmed']}
    formal = c.get('/api/management/students/page', headers=p['auth'], params={'class_id': p['class_id'], 'membership_status': 'active'}).json()
    assert formal['total'] == 3 and {s['id'] for s in formal['items']} == {p['alice'], p['bob'], p['zero']}
    disabled = c.get('/api/management/students/page', headers=p['auth'], params={'class_id': p['class_id'], 'enabled': 'false'}).json()
    assert [s['id'] for s in disabled['items']] == [p['zero']]


def test_overview_keeps_zero_rows_and_historical_time_course_scope(c, population, monkeypatch):
    p = population
    monkeypatch.setattr(core, 'current_bank', lambda _: (_ for _ in ()).throw(AssertionError('No image-bearing bank may load')))
    response = overview(c, p, page_size=1)
    assert response.status_code == 200, response.text
    data = response.json()
    assert data['period'] == {'date_from': '2026-11-03', 'date_to': '2026-11-03', 'timezone': 'Asia/Shanghai'}
    assert data['total'] == 3 and data['pages'] == 3
    assert data['classroom']['student_count'] == 5 and data['classroom']['formal_student_count'] == 3
    assert data['summary'] == {'student_count': 3, 'active_students': 2, 'answered': 4, 'correct': 2,
                               'wrong': 2, 'accuracy': 50.0, 'study_seconds': 65, 'student_question_pairs': 3,
                               'eligible_roster_count': 3, 'pending_student_count': 2}
    assert data['items'][0]['id'] == p['alice']
    assert data['items'][0]['practice'] == {'answered': 3, 'correct': 1, 'wrong': 2, 'accuracy': 33.3,
                                          'unique_questions': 2, 'study_seconds': 60, 'active_days': 1,
                                          'last_answered_at': '2026-11-03T15:59:59.999999Z'}
    filtered = overview(c, p, subject_id='math', sort_by='name', order='asc').json()
    by_id = {s['id']: s for s in filtered['items']}
    assert by_id[p['alice']]['practice']['answered'] == 2
    assert by_id[p['bob']]['practice']['answered'] == 0
    assert by_id[p['zero']]['practice']['accuracy'] is None
    assert filtered['summary']['accuracy'] == 50.0 and filtered['summary']['study_seconds'] == 40
    assert_private_absent(data)
    assert_private_absent(filtered)
    with core.db() as conn:
        logs = core.rows(conn, "SELECT reason FROM audit WHERE action='students.learning.overview'")
        assert len(logs) == 2 and all(PRIVATE not in r['reason'] for r in logs)


def test_stable_sort_nulls_last_and_selected_students_apply_same_filters(c, population):
    p = population
    for direction in ('asc', 'desc'):
        data = overview(c, p, sort_by='accuracy', order=direction).json()
        assert data['items'][-1]['id'] == p['zero']
        expected = [p['alice'], p['bob']] if direction == 'asc' else [p['bob'], p['alice']]
        assert [s['id'] for s in data['items'][:2]] == expected
    pages = [overview(c, p, sort_by='name', order='asc', page=i, page_size=1).json() for i in (1, 2, 3)]
    assert [v['items'][0]['id'] for v in pages] == [p['alice'], p['bob'], p['zero']]
    assert overview(c, p, student_ids=p['left']).status_code == 409
    assert overview(c, p, student_ids=p['bob'], q='Alice').status_code == 409
    assert overview(c, p, student_ids=p['zero'], enabled='true').status_code == 409
    selected = overview(c, p, student_ids=p['alice'] + ',' + p['bob']).json()
    assert selected['summary']['student_count'] == 2 and selected['total'] == 2
    empty = overview(c, p, q='no-matching-person').json()
    assert empty['items'] == [] and empty['summary']['accuracy'] is None and empty['page'] == empty['pages'] == 1


def test_teacher_class_roster_does_not_gain_analytics_or_private_account_fields(c, population):
    p = population
    teacher = headers(login(c, 'teacher'))
    with core.db() as conn:
        other_teacher = clone_user(conn, p['template'], 'other-teacher', role='teacher')
        foreign = core.uid()
        archived = core.uid()
        for identifier, owner, archive in [(foreign, other_teacher, 0), (archived, p['teacher_id'], 1)]:
            conn.execute('''INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,archived,created_at)
              VALUES(?,?,?,'group-mechanics','2026',?,?,?)''',
                         (identifier, identifier, owner, core.uid(), archive, core.iso()))
    directory = c.get('/api/management/student-classes', headers=teacher).json()
    assert directory['unassigned'] is None and [s['id'] for s in directory['items']] == [p['class_id']]
    response = c.get('/api/management/students/page', headers=teacher, params={'class_id': p['class_id']})
    assert response.status_code == 200
    assert response.json()['total'] == 5
    allowed = {'id', 'username', 'name', 'role', 'enabled', 'created_at', 'class_name', 'membership_status', 'visibility_confirmed'}
    assert all(set(s) == allowed for s in response.json()['items'])
    for class_id in (foreign, archived, 'unassigned'):
        assert c.get('/api/management/students/page', headers=teacher, params={'class_id': class_id}).status_code == 403
    assert c.get('/api/management/students/page', headers=teacher, params={'class_id': p['class_id'], 'sort_by': 'last_login_at'}).status_code == 403
    assert c.get('/api/management/student-classes?class_status=all', headers=teacher).status_code == 403
    assert c.get('/api/management/students/overview', headers=teacher, params={'class_id': p['class_id']}).status_code == 403
    assert c.post('/api/management/students/overview/export', headers=teacher, json={'class_id': p['class_id']}).status_code == 403
    student = headers(login(c, 'student', 'TestStudent123!'))
    for auth in (student, {**p['auth'], 'X-Zhikaotong-Surface': 'app'}):
        assert c.get('/api/management/student-classes', headers=auth).status_code == 403


def test_csv_matches_filtered_overview_order_and_escapes_spreadsheet_formulas(c, population):
    p = population
    with core.db() as conn:
        conn.execute("UPDATE users SET name='=SUM(1,2)' WHERE id=?", (p['alice'],))
        conn.execute("UPDATE memberships SET class_name=? WHERE user_id=?", ('\t@external', p['alice']))
    filters = {'class_id': p['class_id'], 'date_from': '2026-11-03', 'date_to': '2026-11-03',
               'sort_by': 'accuracy', 'order': 'desc', 'student_ids': [p['alice'], p['bob']]}
    visible = overview(c, p, sort_by='accuracy', order='desc', student_ids=','.join(filters['student_ids'])).json()
    response = c.post('/api/management/students/overview/export', headers=p['auth'], json=filters)
    assert response.status_code == 200, response.text
    assert response.content.startswith(b'\xef\xbb\xbf')
    assert response.headers['X-Export-Count'] == '2'
    assert response.headers['Cache-Control'] == 'no-store'
    assert 'attachment;' in response.headers['Content-Disposition']
    rows = list(csv.DictReader(io.StringIO(response.content.decode('utf-8-sig'))))
    assert [r['账号'] for r in rows] == [s['username'] for s in visible['items']]
    for row, student in zip(rows, visible['items']):
        assert int(row['答题次数']) == student['practice']['answered']
        assert float(row['正确率(%)']) == student['practice']['accuracy']
    formula = next(row for row in rows if row['账号'] == 'student')
    assert formula['姓名'] == "'=SUM(1,2)" and formula['班内姓名'] == "'\t@external"
    assert PRIVATE not in response.text
    assert '出生' not in response.text and '密码' not in response.text
    assert c.post('/api/management/students/overview/export', headers=p['auth'], json={**filters, 'page': 1}).status_code == 422
    assert c.post('/api/management/students/overview/export', headers=p['auth'], json={**filters, 'student_ids': []}).status_code == 422


def test_date_sort_and_query_validation_fail_closed(c, population):
    p = population
    for params in ({'date_from': '2026-02-30'}, {'date_from': '2026-11-05'},
                   {'date_from': '2025-01-01'}, {'date_from': '0001-01-01', 'date_to': '0001-01-01'},
                   {'date_to': '9999-12-31'}, {'sort_by': 'answered; DROP TABLE users'},
                   {'order': 'sideways'}, {'page_size': 101}, {'student_ids': 'x,'}):
        assert overview(c, p, **params).status_code == 422, params
    with core.db() as conn:
        conn.execute("UPDATE users SET name='literal_% name' WHERE id=?", (p['alice'],))
    data = overview(c, p, q='_%').json()
    assert [s['id'] for s in data['items']] == [p['alice']]
    assert overview(c, p, subject_id='unrecognised-subject').status_code == 404
    assert c.get('/api/management/students/overview', params={'class_id': p['class_id']}).status_code == 401
    assert c.get('/api/management/students/overview', headers=p['auth'], params={
        'class_id': p['class_id'], 'date_to': '0001-01-01'}).status_code == 422
    for invalid in ({'enabled': 'false'}, {'student_ids': p['alice']}, {'date_from': False}):
        assert c.post('/api/management/students/overview/export', headers=p['auth'],
                      json={'class_id': p['class_id'], **invalid}).status_code == 422


def test_overview_uses_fixed_sql_queries_and_indexed_record_time_scope(c, population, monkeypatch):
    p = population
    query_count = []
    original_rows, original_one = core.rows, core.one

    def rows(conn, sql, args=()):
        query_count.append(sql)
        return original_rows(conn, sql, args)

    def one(conn, sql, args=()):
        query_count.append(sql)
        return original_one(conn, sql, args)

    monkeypatch.setattr(core, 'rows', rows)
    monkeypatch.setattr(core, 'one', one)
    with core.db() as conn:
        actor = original_one(conn, "SELECT * FROM users WHERE username='admin'")
        _overview(conn, core, actor, p['class_id'], date_from='2026-11-03', date_to='2026-11-03')
        small_count = len(query_count)
        for index in range(80):
            student = clone_user(conn, p['template'], f'larger-roster-{index}')
            membership(conn, p['class_id'], student)
        query_count.clear()
        result = _overview(conn, core, actor, p['class_id'], date_from='2026-11-03', date_to='2026-11-03', page_size=100)
        assert result['total'] == 83 and len(query_count) == small_count == 7
        _, cohort, args = _cohort(conn, core, p['class_id'], actor, formal=True)
        sql, values = _learning_sql(cohort, args, '2026-11-02T16:00:00', '2026-11-03T16:00:00', None)
        plan = original_rows(conn, 'EXPLAIN QUERY PLAN ' + sql + 'SELECT * FROM learning ORDER BY answered DESC LIMIT 100', values)
        details = [step['detail'] for step in plan]
        assert any('records_user_time' in detail and 'user_id=?' in detail and 'answered_at>?' in detail and 'answered_at<?' in detail for detail in details), details
        assert not any(detail.startswith('SCAN r') for detail in details), details


def test_formal_admin_enrollment_and_deleted_accounts_respect_current_roster(c, population):
    p = population
    with core.db() as conn:
        admin = core.one(conn, "SELECT id FROM users WHERE username='admin'")['id']
        direct = clone_user(conn, p['template'], 'admin-direct-student')
        membership(conn, p['class_id'], direct, confirmed=False)
        conn.execute('UPDATE memberships SET admin_enrolled_by=?,admin_enrolled_at=? WHERE user_id=?',
                     (admin, core.iso(), direct))
        deleted = clone_user(conn, p['template'], 'deleted-student')
        membership(conn, p['class_id'], deleted)
        conn.execute('UPDATE users SET deleted_at=? WHERE id=?', (core.iso(), deleted))
        record(conn, deleted, p['math'], '2026-11-03T01:00:00Z', 1, 9999, 'math')
    data = overview(c, p).json()
    assert data['total'] == 4 and direct in {s['id'] for s in data['items']}
    assert deleted not in {s['id'] for s in data['items']}
    assert data['summary']['answered'] == 4 and data['summary']['study_seconds'] == 65
    unassigned = c.get('/api/management/students/page', headers=p['auth'], params={'class_id': 'unassigned'}).json()
    assert [s['id'] for s in unassigned['items']] == [p['left']]
    with core.db() as conn:
        conn.execute('UPDATE classes SET deleted_at=? WHERE id=?', (core.iso(), p['class_id']))
    assert overview(c, p).status_code == 404


def test_export_limit_does_not_silently_truncate(c):
    auth = headers(login(c))
    with core.db() as conn:
        template = core.one(conn, "SELECT * FROM users WHERE username='student'")
        rows = []
        for index in range(5001):
            row = {**template, 'id': core.uid(), 'username': f'limit-{index:04}',
                   'name': 'limit-allowed' if index < 5000 else 'limit-extra'}
            rows.append(list(row.values()))
        conn.executemany('INSERT INTO users(' + ','.join(template) + ') VALUES(' + ','.join('?' for _ in template) + ')', rows)
    filters = {'class_id': 'unassigned', 'q': 'limit-allowed'}
    allowed = c.post('/api/management/students/overview/export', headers=auth, json=filters)
    assert allowed.status_code == 200, allowed.text
    assert allowed.headers['X-Export-Count'] == '5000'
    assert len(list(csv.reader(io.StringIO(allowed.content.decode('utf-8-sig'))))) == 5001
    blocked = c.post('/api/management/students/overview/export', headers=auth, json={**filters, 'q': 'limit-'})
    assert blocked.status_code == 422 and '5000' in blocked.json()['detail']
    assert c.post('/api/management/students/overview/export', headers=auth,
                  json={**filters, 'student_ids': ['x' + str(i) for i in range(501)]}).status_code == 422
