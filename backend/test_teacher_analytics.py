"""Teachers see only current consenting class members and scoped aggregates."""
import json

import pytest

from . import app as core
from .test_student_analytics import PRIVATE, assert_aggregate_only, seed_record
from .test_teaching import PASSWORD, answer_payload, assign, make_paper, school


def add_member(conn, class_id, username, status='active', *, enabled=1, deleted=False, visibility=1, direct=False):
    user = core.one(conn, "SELECT * FROM users WHERE username='student'")
    user.update(id=core.uid(), username=username, name=username, enabled=enabled, deleted_at=core.iso() if deleted else None)
    conn.execute('INSERT INTO users(' + ','.join(user) + ') VALUES(' + ','.join('?' for _ in user) + ')', list(user.values()))
    admin = core.one(conn, "SELECT id FROM users WHERE username='admin'")['id']
    conn.execute('''INSERT INTO memberships(id,class_id,user_id,status,visibility_accepted,class_name,created_at,admin_enrolled_by,admin_enrolled_at)
      VALUES(?,?,?,?,?,?,?,?,?)''', (core.uid(), class_id, user['id'], status, visibility, '班内-' + username, core.iso(), admin if direct else None, core.iso() if direct else None))
    return user['id']


def test_learning_roster_and_old_management_lists_exclude_departed_but_keep_approval(school):
    _, call, tokens, class_id = school
    with core.db() as conn:
        conn.execute("UPDATE memberships SET class_name='班内学生甲' WHERE user_id=?", (tokens['student']['user']['id'],))
        pending = add_member(conn, class_id, 'pending-student', 'pending_confirmation')
        add_member(conn, class_id, 'pending-approval', 'pending_approval')
        left = add_member(conn, class_id, 'left-student', 'left')
        rejected = add_member(conn, class_id, 'rejected-student', 'rejected')
        add_member(conn, class_id, 'disabled-student', enabled=0)
        add_member(conn, class_id, 'deleted-student', deleted=True)
        add_member(conn, class_id, 'unconfirmed-active', visibility=0)
        direct = add_member(conn, class_id, 'admin-direct', visibility=0, direct=True)
    path = '/teaching/classes/' + class_id + '/students'
    response = call('GET', path)
    assert response.status_code == 200, response.text
    value = response.json()
    assert {item['id'] for item in value['students']} == {tokens['student']['user']['id'], direct}
    assert next(item for item in value['students'] if item['id'] == tokens['student']['user']['id'])['name'] == '班内学生甲'
    assert all(set(item) == {'id', 'username', 'name', 'role', 'enabled', 'created_at', 'status', 'current_wrong_count'} for item in value['students'])
    assert value['wrong_summary'] == {'wrong_questions': 0, 'students_with_wrong': 0, 'student_count': 2}
    members = call('GET', '/management/classes/' + class_id + '/members').json()
    assert pending in {item['id'] for item in members} and not {left, rejected}.intersection(item['id'] for item in members)
    users = call('GET', '/management/users').json()
    assert pending in {item['id'] for item in users} and not {left, rejected}.intersection(item['id'] for item in users)
    assert call('GET', '/management/dashboard').json()['stats']['students'] == 2
    assert call('GET', '/management/classes').json()[0]['member_count'] == 2
    assert {left, rejected}.issubset(item['id'] for item in call('GET', '/management/classes/' + class_id + '/members', role='admin').json())
    assert_aggregate_only(value)


def test_teacher_only_class_ownership_membership_and_live_revocation(school):
    client, call, tokens, class_id = school
    student = tokens['student']['user']['id']
    base = '/teaching/classes/' + class_id + '/students'
    for path in (base, base + '/' + student + '/analytics'):
        assert client.get('/api' + path).status_code == 401
        for role in ('admin', 'student'):
            assert call('GET', path, role=role).status_code == 403
    with core.db() as conn:
        other = core.create_user(conn, 'foreign-analytics-teacher', '外班教师', 'teacher', PASSWORD, False, True)
    foreign = client.post('/api/auth/login', json={'username': other['username'], 'password': PASSWORD}).json()
    for path in (base, base + '/' + student + '/analytics'):
        assert client.get('/api' + path, headers={'Authorization': 'Bearer ' + foreign['access_token']}).status_code == 403
    assert call('GET', base + '/' + student + '/analytics').status_code == 200
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='left' WHERE class_id=? AND user_id=?", (class_id, student))
    assert call('GET', base).json()['students'] == []
    assert call('GET', base + '/' + student + '/analytics').status_code == 404
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='active',visibility_accepted=0 WHERE class_id=? AND user_id=?", (class_id, student))
    assert call('GET', base + '/' + student + '/analytics').status_code == 404
    with core.db() as conn:
        conn.execute('UPDATE memberships SET admin_enrolled_by=?,admin_enrolled_at=? WHERE class_id=? AND user_id=?', (tokens['admin']['user']['id'], core.iso(), class_id, student))
    assert call('GET', base + '/' + student + '/analytics').status_code == 200
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (class_id,))
    assert call('GET', base).status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=0,deleted_at=? WHERE id=?', (core.iso(), class_id))
    assert call('GET', base).status_code == 404


def test_aggregate_scope_includes_politics_and_historical_subjects_without_private_profile(school):
    _, call, tokens, class_id = school
    student = tokens['student']['user']['id']
    with core.db() as conn:
        conn.execute("INSERT OR IGNORE INTO subjects(id,name) VALUES('politics','思想政治')")
        conn.execute("UPDATE groups SET subject_ids=? WHERE id='group-mechanics'", (core.canonical(['math', 'politics']),))
        math = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        english = core.one(conn, "SELECT id FROM questions WHERE subject_id='english' LIMIT 1")['id']
        for correct in (0, 1):
            seed_record(conn, student, math, core.iso(), correct, 30, core.canonical({'subject_id': 'math', 'type': 'single', 'selected': PRIVATE, 'media': PRIVATE}))
        seed_record(conn, student, math, core.iso(), 0, 20, core.canonical({'subject_id': 'politics', 'type': 'judge'}))
        seed_record(conn, student, english, core.iso(), 0, 10, '{}')
        conn.execute("UPDATE questions SET subject_id='english',knowledge_id='english-basic',status='deleted' WHERE id=?", (math,))
    path = '/teaching/classes/' + class_id + '/students/' + student + '/analytics'
    value = call('GET', path).json()
    assert value['summary']['answered'] == value['lifetime']['answered'] == 3
    assert value['summary']['correct'] == 1 and value['summary']['wrong'] == 2 and value['summary']['accuracy'] == 33.3
    assert {row['subject_id']: row['wrong'] for row in value['subjects']} == {'math': 1, 'politics': 1}
    assert {row['type']: row['wrong'] for row in value['types']} == {'single': 1, 'judge': 1}
    assert value['available_subjects'] == [{'id': 'math', 'name': '数学'}, {'id': 'politics', 'name': '思想政治'}]
    assert sum(item['answered'] for item in value['daily']) == 3
    assert not {'birth_year', 'grade', 'target', 'consent_version', 'subject_group_id'}.intersection(value['student'])
    filtered = call('GET', path + '?subject_id=politics&days=7').json()
    assert filtered['summary']['answered'] == 1 and filtered['types'][0]['wrong'] == 1
    assert filtered['available_subjects'] == value['available_subjects']
    assert call('GET', path + '?subject_id=english').status_code == 403
    assert call('GET', path + '?days=8').status_code == 422
    assert call('GET', '/management/users/' + student + '/analytics', role='admin').json()['summary']['answered'] == 4
    assert_aggregate_only(value)


def test_current_class_tasks_only_and_departed_results_hidden_without_erasing_history(school):
    _, call, tokens, class_id = school
    student = tokens['student']['user']['id']
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    path = '/student/assignments/' + task['id']
    attempt = call('GET', path, role='student').json()
    grade = call('POST', path + '/submit', role='student', json=answer_payload(paper, attempt)).json()
    pending = assign(call, make_paper(call, title='尚未打开'), class_id)
    with core.db() as conn:
        second_class = core.uid()
        conn.execute("INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,created_at) VALUES(?,?,?,'group-mechanics','2027',?,?)", (second_class, '另一个班', tokens['teacher']['user']['id'], core.uid(), core.iso()))
        conn.execute("INSERT INTO teaching_assignments VALUES(?,?,?,?,?)", ('foreign-class-assignment', paper['id'], second_class, '另一个班', core.iso()))
        conn.execute('INSERT INTO teaching_recipients VALUES(?,?)', ('foreign-class-assignment', student))
        before = core.rows(conn, 'SELECT * FROM teaching_attempts ORDER BY assignment_id')
    analytics = '/teaching/classes/' + class_id + '/students/' + student + '/analytics?days=7&subject_id=english'
    value = call('GET', analytics).json()
    assert value['classwork']['scope'] == 'lifetime_current_class_all_subjects'
    assert value['classwork']['assigned'] == 2 and value['classwork']['submitted'] == value['classwork']['pending'] == 1
    assert value['classwork']['results'][0]['score'] == grade['score']
    assert_aggregate_only(value)
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='left' WHERE class_id=? AND user_id=?", (class_id, student))
    assert call('GET', analytics).status_code == 404
    hidden = call('GET', '/teaching/assignments/' + task['id'] + '/results').json()
    assert hidden['results'] == [] and hidden['assignment']['recipient_count'] == hidden['assignment']['submitted_count'] == 0
    assert call('GET', '/teaching/assignments').json()[0]['recipient_count'] == 0
    assert call('GET', path, role='student').json()['result'] == grade
    admin = call('GET', '/management/users/' + student + '/analytics', role='admin').json()
    assert admin['classwork']['submitted'] == 1 and admin['classwork']['results'][0]['score'] == grade['score']
    with core.db() as conn:
        assert before == core.rows(conn, 'SELECT * FROM teaching_attempts ORDER BY assignment_id')
        assert core.one(conn, "SELECT reason FROM audit WHERE action='teaching.student.analytics.view'")['reason'].startswith('教师查看在班学生学习汇总')


def test_teacher_cannot_read_disabled_deleted_pending_or_reassigned_class_student(school):
    _, call, tokens, class_id = school
    with core.db() as conn:
        disabled = add_member(conn, class_id, 'not-enabled', enabled=0)
        deleted = add_member(conn, class_id, 'already-deleted', deleted=True)
        pending = add_member(conn, class_id, 'not-confirmed', 'pending_confirmation')
    for student in (disabled, deleted, pending, 'missing'):
        assert call('GET', '/teaching/classes/' + class_id + '/students/' + student + '/analytics').status_code == 404
    with core.db() as conn:
        teacher = core.create_user(conn, 'new-owner-teacher', '新教师', 'teacher', PASSWORD, False, True)
        conn.execute('UPDATE classes SET teacher_id=? WHERE id=?', (teacher['id'], class_id))
    assert call('GET', '/teaching/classes/' + class_id + '/students').status_code == 403
