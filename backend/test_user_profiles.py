"""Editable user identity, transactional validation and unchanged school history."""
from concurrent.futures import ThreadPoolExecutor
import json

from . import app as core
from .test_api import activate, c, headers, login, record
from .test_teaching import PASSWORD, answer_payload, assign, make_paper, school


def account(username):
    with core.db() as conn:
        return core.one(conn, 'SELECT * FROM users WHERE username=?', (username,))


def group(conn, name, subjects, enabled=True):
    identifier = core.uid()
    conn.execute('INSERT INTO groups(id,name,enabled,subject_ids) VALUES(?,?,?,?)',
                 (identifier, name, int(enabled), core.canonical(subjects)))
    return identifier


def snapshot_history(identifier):
    with core.db() as conn:
        tables = ('records', 'wrong', 'marks', 'memberships', 'consents', 'teaching_papers',
                  'teaching_assignments', 'teaching_recipients', 'teaching_attempts', 'bank_releases')
        return {table: core.rows(conn, 'SELECT * FROM ' + table + ' ORDER BY rowid') for table in tables}


def test_admin_edit_get_is_role_scoped_redacted_and_deleted_accounts_are_hidden(c):
    admin = headers(login(c))
    student = account('student')
    result = c.get('/api/management/users/' + student['id'], headers=admin)
    assert result.status_code == 200
    data = result.json()
    assert data['user']['id'] == student['id']
    assert data['limits'] == {'birth_year_min': 1900, 'birth_year_max': core.now().year - 14,
                             'exam_year_min': core.now().year, 'exam_year_max': core.now().year + 10}
    assert set(data['editable_fields']) == {'username', 'name', 'enabled', 'birth_year',
                                            'subject_group_id', 'exam_year', 'grade', 'target'}
    assert not {'password_hash', 'access_hash', 'refresh_hash', 'deleted_at'}.intersection(data['user'])
    for role in ('teacher', 'admin'):
        value = c.get('/api/management/users/' + account(role)['id'], headers=admin).json()
        assert set(value['editable_fields']) == {'username', 'name', 'enabled'}
    for role in ('teacher', 'student'):
        assert c.get('/api/management/users/' + student['id'], headers=headers(login(c, role))).status_code == 403
    assert c.get('/api/management/users/' + student['id']).status_code == 401
    assert c.get('/api/management/users/missing', headers=admin).status_code == 404
    with core.db() as conn:
        conn.execute('UPDATE users SET deleted_at=? WHERE id=?', (core.iso(), student['id']))
    assert c.get('/api/management/users/' + student['id'], headers=admin).status_code == 404
    assert c.patch('/api/management/users/' + student['id'], headers=admin, json={'name': '不可编辑'}).status_code == 404


def test_admin_edits_identity_and_student_fields_without_replacing_history(school):
    client, call, tokens, class_id = school
    student = tokens['student']['user']
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    attempt = call('GET', '/student/assignments/' + task['id'], role='student').json()
    assert call('POST', '/student/assignments/' + task['id'] + '/submit', role='student', json=answer_payload(paper, attempt)).status_code == 200
    question = paper['questions'][0]
    assert call('POST', '/student/records/batch', role='student', json={'records': [record(question)]}).status_code == 200
    before = snapshot_history(student['id'])
    original = account('student')
    changes = {'username': 'corrected-student', 'name': '  修正姓名  ', 'birth_year': 2007,
               'subject_group_id': original['subject_group_id'], 'exam_year': core.now().year + 2,
               'grade': '二年级', 'target': '私人目标不得进入审计原文'}
    response = call('PATCH', '/management/users/' + student['id'], role='admin', json=changes)
    assert response.status_code == 200, response.text
    updated = response.json()
    assert updated['id'] == student['id'] and updated['name'] == '修正姓名'
    assert updated['username'] == changes['username'] and updated['target'] == changes['target']
    assert updated['activated'] == bool(original['activated']) and updated['consent_version'] == original['consent_version']
    assert before == snapshot_history(student['id'])
    with core.db() as conn:
        row = core.one(conn, 'SELECT * FROM users WHERE id=?', (student['id'],))
        assert row['password_hash'] == original['password_hash']
        assert core.rows(conn, 'SELECT revoked FROM sessions WHERE user_id=?', (student['id'],)) == [{'revoked': 1}]
        logs = core.rows(conn, "SELECT reason FROM audit WHERE action='user.profile.update' AND target=?", (student['id'],))
        reason = json.loads(logs[-1]['reason'])
        assert set(reason['fields']) == {'username', 'name', 'birth_year', 'exam_year', 'grade', 'target'}
        assert reason['sessions_revoked_for'] == ['username']
        assert changes['target'] not in logs[-1]['reason'] and '2007' not in logs[-1]['reason']
    assert call('GET', '/auth/me', role='student').status_code == 401
    assert client.post('/api/auth/refresh', json={'refresh_token': tokens['student']['refresh_token']}).status_code == 401
    assert client.post('/api/auth/login', json={'username': 'student', 'password': PASSWORD}).status_code == 401
    fresh = client.post('/api/auth/login', json={'username': 'corrected-student', 'password': PASSWORD})
    assert fresh.status_code == 200 and fresh.json()['user']['id'] == student['id']


def test_non_sensitive_edits_keep_sessions_and_self_rename_requires_new_login(c):
    admin_session = login(c)
    admin = headers(admin_session)
    for username in ('student', 'teacher', 'admin'):
        target_session = admin_session if username == 'admin' else login(c, username)
        target = account(username)
        response = c.patch('/api/management/users/' + target['id'], headers=admin,
                           json={'name': '修改后的' + username})
        assert response.status_code == 200
        assert c.get('/api/auth/me', headers=headers(target_session)).status_code == 200
        assert c.patch('/api/management/users/' + target['id'], headers=admin,
                       json={'name': '修改后的' + username}).status_code == 200
        if username != 'student':
            assert c.patch('/api/management/users/' + target['id'], headers=admin,
                           json={'grade': '不能赋予教职工学生字段'}).status_code == 422
    own = account('admin')
    response = c.patch('/api/management/users/' + own['id'], headers=admin, json={'username': 'renamed-admin'})
    assert response.status_code == 200 and response.json()['id'] == own['id']
    assert c.get('/api/auth/me', headers=admin).status_code == 401
    assert login(c, 'renamed-admin', 'TestAdmin123!')['user']['id'] == own['id']


def test_invalid_types_fields_bounds_and_conflicts_do_not_partially_update(c):
    admin = headers(login(c))
    target = account('student')
    path = '/api/management/users/' + target['id']
    invalid = [
        {}, {'name': ''}, {'name': None}, {'name': 'x' * 51}, {'name': '姓名\n控制符'},
        {'username': 'ab'}, {'username': ' 空格账号 '}, {'username': 'x' * 65}, {'username': True},
        {'enabled': 1}, {'enabled': None}, {'birth_year': True}, {'birth_year': 1899},
        {'birth_year': core.now().year - 13}, {'birth_year': '2008'},
        {'exam_year': True}, {'exam_year': core.now().year - 1}, {'exam_year': core.now().year + 11},
        {'grade': None}, {'grade': 'x' * 41}, {'target': 'x' * 201}, {'target': 123},
        {'subject_group_id': ''}, {'subject_group_id': False}, {'role': 'admin'},
        {'activated': True}, {'consent_version': 'bypass'}, {'password_hash': 'bypass'}, {'password': 'BYPASS123!'},
    ]
    original = account('student')
    for payload in invalid:
        response = c.patch(path, headers=admin, json=payload if not payload else {'name': '临时不应保存', **payload})
        assert response.status_code == 422, (payload, response.text)
        assert account('student') == original
    for username in ('admin', 'teacher'):
        other = account(username)
        if username == 'teacher':
            with core.db() as conn:
                conn.execute('UPDATE users SET deleted_at=? WHERE id=?', (core.iso(), other['id']))
        response = c.patch(path, headers=admin, json={'username': username, 'name': '冲突后不可部分保存'})
        assert response.status_code == 409
        assert account('student') == original


def test_profession_superset_current_memberships_and_historical_classes(c):
    student_session = activate(c)
    admin = headers(login(c))
    student = account('student')
    path = '/api/management/users/' + student['id']
    with core.db() as conn:
        classroom = core.one(conn, 'SELECT * FROM classes LIMIT 1')
        original_subjects = core.json.loads(core.one(conn, 'SELECT subject_ids FROM groups WHERE id=?', (student['subject_group_id'],))['subject_ids'])
        broad = group(conn, '兼容专业', original_subjects)
        narrow = group(conn, '共享英语数学专业', ['math', 'english'])
        shared = group(conn, '共享数学班科目', ['math'])
        before_membership = core.one(conn, 'SELECT * FROM memberships WHERE user_id=?', (student['id'],))
    for status in ('active', 'pending_confirmation', 'pending_approval'):
        with core.db() as conn:
            conn.execute('UPDATE memberships SET status=? WHERE user_id=?', (status, student['id']))
        bad = c.patch(path, headers=admin, json={'subject_group_id': narrow, 'name': '不该保存'})
        assert bad.status_code == 409 and '班级管理' in bad.json()['detail']
        assert account('student')['name'] == student['name']
    good = c.patch(path, headers=admin, json={'subject_group_id': broad})
    assert good.status_code == 200
    assert c.get('/api/auth/me', headers=headers(student_session)).status_code == 401
    with core.db() as conn:
        membership = core.one(conn, 'SELECT * FROM memberships WHERE user_id=?', (student['id'],))
        assert membership['class_name'] == before_membership['class_name']
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (classroom['id'],))
        shared_class = core.uid()
        conn.execute('INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,created_at) VALUES(?,?,?,?,?,?,?)',
                     (shared_class, '共享数学班', classroom['teacher_id'], shared, '2026', core.uid(), core.iso()))
        conn.execute('INSERT INTO memberships(id,class_id,user_id,status,visibility_accepted,class_name,created_at) VALUES(?,?,?,?,1,?,?)',
                     (core.uid(), shared_class, student['id'], 'active', '独立班内姓名', core.iso()))
    assert c.patch(path, headers=admin, json={'subject_group_id': narrow}).status_code == 200
    with core.db() as conn:
        conn.execute('UPDATE classes SET deleted_at=? WHERE id=?', (core.iso(), shared_class))
        empty = group(conn, '无当前班级约束专业', [])
    assert c.patch(path, headers=admin, json={'subject_group_id': empty}).status_code == 200


def test_activated_required_fields_and_disabled_profession_can_remain_unchanged(c):
    session = activate(c)
    admin = headers(login(c))
    student = account('student')
    path = '/api/management/users/' + student['id']
    for key in ('birth_year', 'subject_group_id'):
        assert c.patch(path, headers=admin, json={key: None}).status_code == 422
    with core.db() as conn:
        conn.execute('UPDATE groups SET enabled=0 WHERE id=?', (student['subject_group_id'],))
        another = group(conn, '已停用新专业', [], enabled=False)
    assert c.patch(path, headers=admin, json={'name': '资料更正', 'subject_group_id': student['subject_group_id'], 'enabled': True}).status_code == 200
    assert c.get('/api/auth/me', headers=headers(session)).status_code == 200
    assert c.patch(path, headers=admin, json={'subject_group_id': another}).status_code == 422
    assert c.patch(path, headers=admin, json={'enabled': False}).status_code == 200
    assert c.patch(path, headers=admin, json={'name': '禁用账号仍可纠正资料'}).status_code == 200
    assert c.patch(path, headers=admin, json={'enabled': True}).status_code == 422


def test_unactivated_nullable_fields_require_no_current_class(c):
    admin = headers(login(c))
    student = account('student')
    path = '/api/management/users/' + student['id']
    assert c.patch(path, headers=admin, json={'subject_group_id': None}).status_code == 409
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='left' WHERE user_id=?", (student['id'],))
    assert c.patch(path, headers=admin, json={'birth_year': 2008, 'subject_group_id': 'group-mechanics'}).status_code == 200
    response = c.patch(path, headers=admin, json={'birth_year': None, 'subject_group_id': None})
    assert response.status_code == 200 and response.json()['activated'] is False
    assert response.json()['birth_year'] is None and response.json()['subject_group_id'] is None


def test_teacher_keeps_enabled_only_scope_and_gets_only_roster_response(c):
    admin = headers(login(c))
    teacher = headers(login(c, 'teacher'))
    student = account('student')
    path = '/api/management/users/' + student['id']
    assert c.patch(path, headers=teacher, json={'enabled': False, 'name': '越权'}).status_code == 403
    assert account('student')['enabled'] == 1
    result = c.patch(path, headers=teacher, json={'enabled': False})
    assert result.status_code == 200
    assert set(result.json()) == {'id', 'username', 'name', 'role', 'enabled', 'created_at'}
    assert c.patch('/api/management/users/' + account('admin')['id'], headers=teacher, json={'enabled': False}).status_code == 403
    assert c.patch(path, headers=admin, json={'enabled': True}).status_code == 200
    assert c.patch(path, headers=headers(login(c, 'student')), json={'name': '不能编辑'}).status_code == 403


def test_admin_self_disable_and_concurrent_last_admin_are_atomic(c):
    first, second = login(c), login(c, 'reviewer')
    admin = headers(first)
    original = account('admin')
    path = '/api/management/users/' + original['id']
    assert c.patch(path, headers=admin, json={'enabled': False, 'name': '不可部分保存'}).status_code == 409
    assert account('admin') == original
    targets = [(first, second['user']['id']), (second, first['user']['id'])]
    with ThreadPoolExecutor(max_workers=2) as executor:
        results = list(executor.map(lambda item: c.patch('/api/management/users/' + item[1], headers=headers(item[0]), json={'enabled': False}).status_code, targets))
    assert results.count(200) == 1 and all(code in (200, 401, 409) for code in results)
    with core.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users WHERE role='admin' AND enabled=1 AND deleted_at IS NULL").fetchone()[0] == 1


def test_concurrent_username_edits_never_replace_identity_or_partially_update_loser(c):
    admin = headers(login(c))
    targets = [account('student'), account('teacher')]
    def change(target):
        return c.patch('/api/management/users/' + target['id'], headers=admin,
                       json={'username': 'shared-new-login', 'name': '并发修改姓名'})
    with ThreadPoolExecutor(max_workers=2) as executor:
        responses = list(executor.map(change, targets))
    assert sorted(response.status_code for response in responses) == [200, 409]
    with core.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users WHERE username='shared-new-login'").fetchone()[0] == 1
        for original, response in zip(targets, responses):
            actual = core.one(conn, 'SELECT * FROM users WHERE id=?', (original['id'],))
            assert actual['role'] == original['role'] and actual['password_hash'] == original['password_hash']
            if response.status_code == 409:
                assert actual == original
