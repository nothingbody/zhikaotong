"""Reversible administrator removal, authorization, history and migration integrity."""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import json

from . import app as core
from .test_teaching import PASSWORD, answer_payload, assign, make_paper, school


def remove_user(call, target, **changes):
    return call('DELETE', '/management/users/' + target['id'], role='admin',
                json={'confirm': target['username'], 'reason': '清理测试账号', **changes})


def remove_class(call, class_id, **changes):
    with core.db() as conn:
        classroom = core.one(conn, 'SELECT * FROM classes WHERE id=?', (class_id,))
    return call('DELETE', '/management/classes/' + class_id, role='admin',
                json={'confirm': classroom['name'], 'reason': '清理测试班级', **changes})


def test_user_remove_revokes_session_hides_roster_preserves_records_and_restores_state(school):
    client, call, tokens, class_id = school
    student = tokens['student']['user']
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    attempt = call('GET', '/student/assignments/' + task['id'], role='student').json()
    grade = call('POST', '/student/assignments/' + task['id'] + '/submit', role='student', json=answer_payload(paper, attempt)).json()
    question = paper['questions'][0]
    record = {'client_uuid': core.uid(), 'question_id': question['id'], 'question_version': question['version'],
              'selected': question['answer'], 'duration_seconds': 2, 'answered_at': core.iso()}
    assert call('POST', '/student/records/batch', role='student', json={'records': [record]}).status_code == 200
    assert remove_user(call, student).status_code == 200
    assert call('GET', '/auth/me', role='student').status_code == 401
    assert client.post('/api/auth/refresh', json={'refresh_token': tokens['student']['refresh_token']}).status_code == 401
    assert client.post('/api/auth/login', json={'username': 'student', 'password': PASSWORD}).status_code == 401
    assert all(item['id'] != student['id'] for item in call('GET', '/management/users', role='admin').json())
    assert call('GET', '/management/classes/' + class_id + '/members').json() == []
    assert call('GET', '/management/classes').json()[0]['member_count'] == 0
    assert call('GET', '/management/dashboard').json()['stats']['students'] == 0
    deleted = call('GET', '/management/users?deleted=true', role='admin').json()
    assert deleted[0]['id'] == student['id'] and deleted[0]['can_restore'] and deleted[0]['deleted_at']
    hidden = call('GET', '/teaching/assignments/' + task['id'] + '/results').json()
    assert hidden['results'] == []
    assert hidden['assignment']['recipient_count'] == hidden['assignment']['submitted_count'] == 0
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM records WHERE user_id=?', (student['id'],)).fetchone()[0] == 1
        assert json.loads(core.one(conn, 'SELECT result FROM teaching_attempts WHERE assignment_id=? AND user_id=?', (task['id'], student['id']))['result']) == grade
    restored = call('POST', '/management/users/' + student['id'] + '/restore', role='admin', json={'reason': '恢复原账号'})
    assert restored.status_code == 200 and restored.json()['enabled'] is True
    assert call('GET', '/auth/me', role='student').status_code == 401
    relogin = client.post('/api/auth/login', json={'username': 'student', 'password': PASSWORD})
    assert relogin.status_code == 200
    assert call('GET', '/management/classes').json()[0]['member_count'] == 1
    assert call('GET', '/management/users?deleted=true', role='admin').json() == []
    with core.db() as conn:
        actions = [row['action'] for row in core.rows(conn, 'SELECT action FROM audit WHERE target=?', (student['id'],))]
    assert 'user.delete' in actions and 'user.restore' in actions


def test_user_remove_is_admin_only_confirmed_and_protects_current_admin(school):
    _, call, tokens, class_id = school
    student, teacher = tokens['student']['user'], tokens['teacher']['user']
    for role in ('student', 'teacher'):
        for method, path, payload in (
            ('DELETE', '/management/users/' + student['id'], {'confirm': student['username'], 'reason': '不允许删除'}),
            ('POST', '/management/users/' + student['id'] + '/restore', {'reason': '不允许恢复'}),
            ('DELETE', '/management/classes/' + class_id, {'confirm': '任意', 'reason': '不允许删除'}),
            ('POST', '/management/classes/' + class_id + '/restore', {'reason': '不允许恢复'}),
        ):
            assert call(method, path, role=role, json=payload).status_code == 403
        assert call('GET', '/management/users?deleted=true', role=role).status_code == 403
        assert call('GET', '/management/classes?deleted=true', role=role).status_code == 403
    assert remove_user(call, student, confirm='另一个账号').status_code == 422
    assert remove_user(call, student, reason=' ').status_code == 422
    assert remove_user(call, student, unexpected=True).status_code == 422
    assert remove_user(call, tokens['admin']['user']).status_code == 409
    assert remove_user(call, teacher).status_code == 409
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (class_id,))
    assert remove_user(call, teacher).status_code == 409
    assert remove_class(call, class_id).status_code == 200
    assert remove_user(call, teacher).status_code == 200
    assert call('POST', '/management/classes/' + class_id + '/restore', role='admin', json={'reason': '先恢复班级'}).status_code == 409
    assert call('POST', '/management/users/' + teacher['id'] + '/restore', role='admin', json={'reason': '先恢复教师'}).status_code == 200
    restored = call('POST', '/management/classes/' + class_id + '/restore', role='admin', json={'reason': '再恢复班级'})
    assert restored.status_code == 200 and restored.json()['archived'] is True


def test_restore_keeps_previously_disabled_user_disabled_and_never_reuses_account(school):
    _, call, _, _ = school
    with core.db() as conn:
        target = core.create_user(conn, 'disabled_fixture', '原禁用账号', 'student', PASSWORD, False, True)
        conn.execute('UPDATE users SET enabled=0 WHERE id=?', (target['id'],))
    assert remove_user(call, target).status_code == 200
    assert call('POST', '/management/users', role='admin', json={'username': target['username'], 'name': '重复', 'role': 'student', 'password': PASSWORD}).status_code == 409
    restored = call('POST', '/management/users/' + target['id'] + '/restore', role='admin', json={'reason': '恢复禁用账号'})
    assert restored.status_code == 200 and restored.json()['enabled'] is False


def test_pending_self_deletion_anonymizes_removed_user_and_cannot_be_restored(school):
    _, call, tokens, _ = school
    student = tokens['student']['user']
    with core.db() as conn:
        conn.execute("INSERT INTO deletions(user_id,status,requested_at,execute_at) VALUES(?,'pending',?,?)",
                     (student['id'], core.iso(), core.iso(core.now() - timedelta(seconds=1))))
    assert remove_user(call, student).status_code == 200
    with core.db() as conn:
        assert core.execute_deletions(conn) == 1
        target = core.one(conn, 'SELECT * FROM users WHERE id=?', (student['id'],))
    assert target['password_hash'] == '' and target['name'] == '已注销用户'
    assert call('POST', '/management/users/' + student['id'] + '/restore', role='admin', json={'reason': '不得复活已注销身份'}).status_code == 409
    assert call('GET', '/management/users?deleted=true', role='admin').json() == []


def test_class_remove_blocks_current_flows_but_preserves_completed_grades_and_restores(school):
    _, call, tokens, class_id = school
    paper = make_paper(call)
    completed, pending = assign(call, paper, class_id), assign(call, make_paper(call, title='待完成卷'), class_id)
    path = '/student/assignments/' + completed['id']
    attempt = call('GET', path, role='student').json()
    grade = call('POST', path + '/submit', role='student', json=answer_payload(paper, attempt)).json()
    assert remove_class(call, class_id, confirm='错误名称').status_code == 422
    assert remove_class(call, class_id).status_code == 200
    assert remove_class(call, class_id).status_code == 200  # Lost responses are safe to retry.
    assert call('GET', '/management/classes', role='admin').json() == []
    assert call('GET', '/management/classes').json() == []
    assert call('GET', '/management/users').json() == []
    assert call('GET', '/student/classes', role='student').json() == []
    assert call('GET', '/student/dashboard', role='student').json()['classes'] == []
    assert call('GET', '/teaching/catalog').json()['classes'] == []
    assert call('GET', '/management/classes/' + class_id + '/members').status_code == 404
    assert call('POST', '/management/classes/' + class_id + '/members', json={'user_id': tokens['student']['user']['id']}).status_code in (403, 404)
    assert call('PATCH', '/management/classes/' + class_id, role='admin', json={'archived': False}).status_code == 404
    assert call('POST', '/student/classes/' + class_id + '/confirm', role='student', json={'accepted': True, 'class_name': '测试'}).status_code == 409
    assert call('POST', '/student/classes/' + class_id + '/leave', role='student').status_code == 404
    assert call('GET', '/student/assignments/' + pending['id'], role='student').status_code == 403
    assert call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [class_id]}).status_code == 404
    assert call('GET', path, role='student').json()['result'] == grade
    hidden = call('GET', '/teaching/assignments/' + completed['id'] + '/results').json()
    assert hidden['results'] == []
    assert hidden['assignment']['recipient_count'] == hidden['assignment']['submitted_count'] == 0
    deleted = call('GET', '/management/classes?deleted=true', role='admin').json()
    assert deleted[0]['can_restore'] is True and deleted[0]['deleted_at']
    restored = call('POST', '/management/classes/' + class_id + '/restore', role='admin', json={'reason': '恢复教学'})
    assert restored.status_code == 200 and restored.json()['archived'] is False
    assert call('GET', '/student/assignments/' + pending['id'], role='student').status_code == 200


def test_class_restore_requires_current_valid_teacher_and_group(school):
    _, call, tokens, class_id = school
    assert remove_class(call, class_id).status_code == 200
    with core.db() as conn:
        conn.execute('UPDATE users SET enabled=0 WHERE id=?', (tokens['teacher']['user']['id'],))
    deleted = call('GET', '/management/classes?deleted=true', role='admin').json()[0]
    assert deleted['can_restore'] is False
    assert call('POST', '/management/classes/' + class_id + '/restore', role='admin', json={'reason': '教师尚未启用'}).status_code == 409
    with core.db() as conn:
        conn.execute('UPDATE users SET enabled=1 WHERE id=?', (tokens['teacher']['user']['id'],))
        conn.execute("UPDATE groups SET enabled=0 WHERE id='group-mechanics'")
    assert call('POST', '/management/classes/' + class_id + '/restore', role='admin', json={'reason': '科目组尚未启用'}).status_code == 409


def test_concurrent_administrators_cannot_remove_last_valid_admin(school):
    client, call, tokens, _ = school
    reviewer = client.post('/api/auth/login', json={'username': 'reviewer', 'password': PASSWORD}).json()
    def remove(actor, target):
        return client.delete('/api/management/users/' + target['id'], headers={'Authorization': 'Bearer ' + actor['access_token']},
                             json={'confirm': target['username'], 'reason': '并发管理员删除保护'})
    with ThreadPoolExecutor(max_workers=2) as executor:
        first = executor.submit(remove, tokens['admin'], reviewer['user'])
        second = executor.submit(remove, reviewer, tokens['admin']['user'])
        responses = [first.result(), second.result()]
    assert sorted(response.status_code for response in responses)[0] == 200
    assert all(response.status_code in (200, 401, 409) for response in responses)
    with core.db() as conn:
        assert conn.execute("SELECT COUNT(*) FROM users WHERE role='admin' AND enabled=1 AND deleted_at IS NULL").fetchone()[0] >= 1


def test_existing_030_database_migrates_class_columns_idempotently(tmp_path, monkeypatch):
    monkeypatch.setattr(core, 'DB_PATH', str(tmp_path / 'legacy.db'))
    monkeypatch.setattr(core, 'APP_ENV', 'development')
    monkeypatch.setenv('DEV_SEED', 'true')
    monkeypatch.setenv('DEV_SEED_QUESTIONS', 'true')
    for name in ('ADMIN', 'REVIEWER', 'TEACHER', 'STUDENT'):
        monkeypatch.setenv('BOOTSTRAP_' + name + '_PASSWORD', PASSWORD)
    legacy_schema = core.SCHEMA.replace(',deleted_at TEXT,deleted_previous_archived INTEGER);', ');')
    with core.db() as conn:
        conn.executescript(legacy_schema)
        assert 'deleted_at' not in {row['name'] for row in conn.execute('PRAGMA table_info(classes)')}
        core.seed(conn)
        before = dict(conn.execute('SELECT id,name,teacher_id,archived FROM classes').fetchone())
    core.initialize()
    core.initialize()
    with core.db() as conn:
        columns = {row['name'] for row in conn.execute('PRAGMA table_info(classes)')}
        after = dict(conn.execute('SELECT id,name,teacher_id,archived FROM classes').fetchone())
    assert {'deleted_at', 'deleted_previous_archived'}.issubset(columns)
    assert before == after


def test_class_creation_and_teacher_removal_cannot_create_orphan_active_class(school):
    _, call, _, _ = school
    for index in range(3):
        with core.db() as conn:
            teacher = core.create_user(conn, 'race_teacher_' + str(index), '并发教师', 'teacher', PASSWORD, False, True)
        def create():
            return call('POST', '/management/classes', role='admin', json={
                'name': '并发班级', 'term': '2027', 'teacher_id': teacher['id'], 'subject_group_id': 'group-mechanics'})
        with ThreadPoolExecutor(max_workers=2) as executor:
            added = executor.submit(create)
            removed = executor.submit(remove_user, call, teacher)
            responses = [added.result(), removed.result()]
        assert responses[0].status_code in (200, 422)
        assert responses[1].status_code in (200, 409)
        with core.db() as conn:
            assert conn.execute('''SELECT COUNT(*) FROM classes c JOIN users u ON u.id=c.teacher_id
              WHERE c.teacher_id=? AND c.deleted_at IS NULL AND u.deleted_at IS NOT NULL''', (teacher['id'],)).fetchone()[0] == 0
