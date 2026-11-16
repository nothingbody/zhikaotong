"""Student analytics preserve historical scope and expose aggregate data only."""
import json
from datetime import datetime, timezone

import pytest

from . import app as core
from .test_api import activate, c, headers, login


PRIVATE = 'private-selected-answer-image-must-not-be-returned'
NOW = datetime(2026, 11, 3, 4, tzinfo=timezone.utc)


def student_id():
    with core.db() as conn:
        return core.one(conn, "SELECT id FROM users WHERE username='student'")['id']


def other_student():
    with core.db() as conn:
        row = core.one(conn, "SELECT * FROM users WHERE username='student'")
        row.update(id=core.uid(), username='another-student')
        conn.execute('INSERT INTO users(' + ','.join(row) + ') VALUES(' + ','.join('?' for _ in row) + ')', list(row.values()))
        return row['id']


def seed_record(conn, user_id, question_id, at, correct, seconds, snapshot):
    identifier = core.uid()
    conn.execute('''INSERT INTO records(id,user_id,client_uuid,question_id,payload_hash,selected,
      correct,duration_seconds,answered_at,received_at,question_snapshot) VALUES(?,?,?,?,?,?,?,?,?,?,?)''',
                 (identifier, user_id, identifier, question_id, identifier, json.dumps([PRIVATE]),
                  correct, seconds, at, '2026-11-03T03:00:00Z', snapshot))


def assert_aggregate_only(value):
    forbidden = {'password_hash', 'access_hash', 'refresh_hash', 'selected', 'answer', 'stem', 'questions', 'media', 'question_snapshot', 'result'}
    if isinstance(value, dict):
        assert not forbidden.intersection(value)
        for item in value.values():
            assert_aggregate_only(item)
    elif isinstance(value, list):
        for item in value:
            assert_aggregate_only(item)
    assert PRIVATE not in str(value)


def test_profile_disabled_student_basic_fields_membership_and_fixed_audit(c):
    auth = headers(login(c))
    identifier = student_id()
    with core.db() as conn:
        conn.execute("UPDATE users SET enabled=0,subject_group_id='group-mechanics' WHERE id=?", (identifier,))
        conn.execute("UPDATE memberships SET status='pending_confirmation' WHERE user_id=?", (identifier,))
        conn.execute('UPDATE classes SET archived=1')
        before = {table: core.rows(conn, 'SELECT * FROM ' + table + ' ORDER BY rowid') for table in ('users', 'classes', 'memberships', 'questions', 'records', 'bank_releases')}
    response = c.get('/api/management/users/' + identifier + '/profile', headers=auth)
    assert response.status_code == 200, response.text
    value = response.json()
    assert value['user']['enabled'] is False and value['user']['role'] == 'student'
    assert value['user']['subject_group_name']
    assert value['classes'][0]['status'] == 'pending_confirmation' and value['classes'][0]['archived'] is True
    assert set(value['classes'][0]) == {'id', 'name', 'teacher_id', 'teacher_name', 'status', 'archived', 'term', 'deleted_at', 'class_name', 'joined_at', 'visibility_accepted', 'admin_enrolled'}
    assert_aggregate_only(value)
    with core.db() as conn:
        assert before == {table: core.rows(conn, 'SELECT * FROM ' + table + ' ORDER BY rowid') for table in before}
        audit = core.one(conn, "SELECT * FROM audit WHERE action='user.profile.view'")
        assert audit['target'] == identifier and audit['reason'] == '账号管理查看基础资料'


def test_new_views_require_admin_and_non_deleted_student_without_relaxing_details(c):
    identifier = student_id()
    admin = headers(login(c))
    teacher = headers(login(c, 'teacher'))
    student = headers(activate(c))
    with core.db() as conn:
        teacher_id = core.one(conn, "SELECT id FROM users WHERE username='teacher'")['id']
    for view in ('profile', 'analytics'):
        path = '/api/management/users/' + identifier + '/' + view
        assert c.get(path).status_code == 401
        for auth in (teacher, student, {**admin, 'X-Zhikaotong-Surface': 'app'}):
            assert c.get(path, headers=auth).status_code == 403
        assert c.get('/api/management/users/missing/' + view, headers=admin).status_code == 404
        assert c.get('/api/management/users/' + teacher_id + '/' + view, headers=admin).status_code == 422
    assert c.get('/api/management/users/' + identifier + '/details', headers=admin).status_code == 422
    with core.db() as conn:
        conn.execute('UPDATE users SET deleted_at=? WHERE id=?', (core.iso(), identifier))
    for view in ('profile', 'analytics'):
        assert c.get('/api/management/users/' + identifier + '/' + view, headers=admin).status_code == 404


def test_timezone_repeated_attempts_historical_reclassification_and_filters(c, monkeypatch):
    monkeypatch.setattr(core, 'now', lambda: NOW)
    auth = headers(login(c))
    identifier, other = student_id(), other_student()
    with core.db() as conn:
        math = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        english = core.one(conn, "SELECT id FROM questions WHERE subject_id='english' LIMIT 1")['id']
        snapshot = core.canonical({'subject_id': 'math', 'type': 'judge', 'stem': PRIVATE, 'media': {PRIVATE: PRIVATE}})
        for at, correct, seconds in [('2026-10-27T15:59:59.999999Z', 0, 2), ('2026-10-27T16:00:00Z', 1, 10),
                                     ('2026-11-02T15:59:59.999999Z', 0, 20), ('2026-11-02T16:00:00Z', 1, 30),
                                     ('2026-11-03T16:00:00Z', 1, 3)]:
            seed_record(conn, identifier, math, at, correct, seconds, snapshot)
        seed_record(conn, identifier, english, '2026-11-03T01:00:00Z', 0, 40, '{}')
        seed_record(conn, other, english, '2026-11-03T01:00:00Z', 1, 500, '{}')
        conn.execute("UPDATE questions SET subject_id='english',knowledge_id='english-basic',type='multiple',status='deleted' WHERE id=?", (math,))
    path = '/api/management/users/' + identifier + '/analytics'
    value = c.get(path + '?days=7', headers=auth).json()
    assert value['period'] == {'days': 7, 'start': '2026-10-28', 'end': '2026-11-03', 'timezone': 'Asia/Shanghai'}
    assert value['lifetime']['answered'] == 6 and value['lifetime']['unique_questions'] == 2
    assert value['summary'] == {'answered': 4, 'correct': 2, 'wrong': 2, 'unique_questions': 2, 'study_seconds': 100,
                                'active_days': 3, 'last_answered_at': '2026-11-03T01:00:00Z', 'accuracy': 50.0}
    assert len(value['daily']) == 7 and value['daily'][0]['date'] == '2026-10-28'
    assert value['daily'][0]['answered'] == 1 and value['daily'][-2]['answered'] == 1 and value['daily'][-1]['answered'] == 2
    assert value['daily'][1]['answered'] == 0 and value['daily'][1]['accuracy'] is None
    assert sum(item['answered'] for item in value['daily']) == value['summary']['answered']
    assert sum(item['answered'] for item in value['subjects']) == value['summary']['answered']
    assert sum(item['answered'] for item in value['types']) == value['summary']['answered']
    filtered = c.get(path + '?days=7&subject_id=math', headers=auth).json()
    assert filtered['lifetime']['answered'] == 5 and filtered['summary']['answered'] == 3
    assert filtered['summary']['accuracy'] == 66.7 and filtered['summary']['unique_questions'] == 1
    assert filtered['subjects'][0]['subject_id'] == 'math'
    assert filtered['types'][0]['type'] == 'judge'
    assert filtered['available_subjects'] == value['available_subjects']
    assert_aggregate_only(value)
    with core.db() as conn:
        audit = core.one(conn, "SELECT reason FROM audit WHERE action='user.analytics.view' LIMIT 1")
        assert audit['reason'] == '账号管理查看学习分析'


def test_empty_period_zero_fill_and_malformed_snapshot_fallback(c, monkeypatch):
    monkeypatch.setattr(core, 'now', lambda: NOW)
    auth, identifier = headers(login(c)), student_id()
    path = '/api/management/users/' + identifier + '/analytics'
    empty = c.get(path, headers=auth).json()
    assert empty['period']['days'] == 30 and len(empty['daily']) == 30
    assert empty['summary']['accuracy'] is None and empty['lifetime']['last_answered_at'] is None
    assert empty['summary']['answered'] == 0 and empty['subjects'] == empty['types'] == []
    assert all(row['answered'] == 0 and row['accuracy'] is None for row in empty['daily'])
    with core.db() as conn:
        configured = core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid')
    assert empty['available_subjects'] == configured
    assert any(item['id'] == 'politics' for item in empty['available_subjects'])
    with core.db() as conn:
        question = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        for malformed in ('not-json', '', '[]', '{"subject_id":[],"type":[]}', '{"subject_id":null}'):
            seed_record(conn, identifier, question, '2026-11-03T01:00:00Z', 0, 1, malformed)
        seed_record(conn, identifier, question, '2026-11-03T01:00:00Z', 1, 1, '{"subject_id":"historical-subject","type":"fill"}')
    value = c.get(path, headers=auth).json()
    assert value['summary']['answered'] == 6
    assert {row['subject_id']: row['answered'] for row in value['subjects']} == {'math': 5, 'historical-subject': 1}
    historical = c.get(path + '?subject_id=historical-subject', headers=auth).json()
    assert historical['summary']['answered'] == 1 and historical['types'][0]['type'] == 'fill'
    assert {'id': 'historical-subject', 'name': 'historical-subject'} in historical['available_subjects']
    assert_aggregate_only(value)


def test_classwork_counts_unopened_and_historical_tasks_without_private_answers(c, monkeypatch):
    monkeypatch.setattr(core, 'now', lambda: NOW)
    auth, identifier, other = headers(login(c)), student_id(), other_student()
    with core.db() as conn:
        classroom = core.one(conn, 'SELECT * FROM classes LIMIT 1')
        for index in range(29):
            paper, assignment = f'analytics-paper-{index:02d}', f'analytics-assignment-{index:02d}'
            conn.execute('INSERT INTO teaching_papers VALUES(?,?,?,?,?,?,?,?)', (paper, classroom['teacher_id'], f'班级任务{index}', '[]', core.canonical([{'stem': PRIVATE, 'answer': [PRIVATE], 'media': {PRIVATE: PRIVATE}}]), 0, 0, core.iso()))
            conn.execute('INSERT INTO teaching_assignments VALUES(?,?,?,?,?)', (assignment, paper, classroom['id'], '布置时班级名', core.iso()))
            recipient = other if index == 28 else identifier
            conn.execute('INSERT INTO teaching_recipients VALUES(?,?)', (assignment, recipient))
            if index <= 26:
                submitted = None if index == 26 else f'2026-10-{index + 1:02d}T00:00:00Z'
                result = 'malformed' if index == 25 else core.canonical({'score': index, 'full_score': 100, 'correct': 1, 'total': 2, 'questions': [{'selected': [PRIVATE]}]})
                conn.execute('INSERT INTO teaching_attempts(assignment_id,user_id,questions,created_at,result,submitted_at) VALUES(?,?,?,?,?,?)',
                             (assignment, recipient, core.canonical([{'answer': [PRIVATE]}]), core.iso(), result if submitted else None, submitted))
        conn.execute('UPDATE classes SET archived=1,deleted_at=? WHERE id=?', (core.iso(), classroom['id']))
    value = c.get('/api/management/users/' + identifier + '/analytics?days=7&subject_id=english', headers=auth).json()
    tasks = value['classwork']
    assert tasks['scope'] == 'lifetime_all_subjects' and tasks['pending_includes_unavailable'] is True
    assert tasks['assigned'] == 28 and tasks['submitted'] == 26 and tasks['pending'] == 2
    assert len(tasks['results']) == 20 and tasks['results'][0]['assignment_id'] == 'analytics-assignment-24'
    assert tasks['results'][0]['score'] == 24 and tasks['results'][0]['class_name'] == '布置时班级名'
    assert value['summary']['answered'] == 0
    assert_aggregate_only(value)


def test_period_and_subject_validation(c):
    auth, identifier = headers(login(c)), student_id()
    path = '/api/management/users/' + identifier + '/analytics'
    for query in ('days=0', 'days=8', 'days=365', 'days=not-a-number', 'subject_id=' + 'x' * 129):
        assert c.get(path + '?' + query, headers=auth).status_code == 422
    assert c.get(path + '?subject_id=missing', headers=auth).status_code == 404
    for days in (7, 30, 90):
        response = c.get(path + '?days=' + str(days), headers=auth)
        assert response.status_code == 200 and len(response.json()['daily']) == days


def test_microseconds_do_not_round_into_adjacent_shanghai_days(c, monkeypatch):
    monkeypatch.setattr(core, 'now', lambda: NOW)
    auth, identifier = headers(login(c)), student_id()
    with core.db() as conn:
        question = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        for at in ('2026-10-27T15:59:59.999999Z', '2026-11-02T15:59:59.999999Z',
                   '2026-11-03T15:59:59.999999Z', '2026-11-03T15:59:59Z',
                   '2026-11-03T15:59:59+00:00', '2026-11-03T16:00:00Z'):
            seed_record(conn, identifier, question, at, 1, 1, '{}')
    value = c.get('/api/management/users/' + identifier + '/analytics?days=7', headers=auth).json()
    assert value['lifetime']['answered'] == 6 and value['summary']['answered'] == 4
    assert value['daily'][-2]['answered'] == 1 and value['daily'][-1]['answered'] == 3
    assert value['summary']['last_answered_at'] == '2026-11-03T15:59:59.999999Z'
