"""Administrative enrollment bypasses class confirmation without forging consent."""
import pytest

from . import app as core
from .test_api import Client
from .test_teaching import PASSWORD, answer_payload, assign, make_paper, school


@pytest.mark.parametrize('entry', ['create', 'import', 'existing'])
def test_all_admin_enrollment_entries_are_immediate_even_if_approval_required(school, entry):
    _, call, tokens, class_id = school
    assert call('PATCH', '/management/classes/' + class_id, role='admin', json={'approval_required': True}).status_code == 200
    person = {'username': 'direct_' + entry, 'name': '管理员录入学生', 'password': PASSWORD}
    if entry == 'import':
        response = call('POST', '/management/users/import', role='admin', json={'class_id': class_id, 'rows': [person]})
        assert response.status_code == 200 and response.json()['created'] == 1, response.text
        user_id = next(user['id'] for user in call('GET', '/management/users', role='admin').json() if user['username'] == person['username'])
    else:
        response = call('POST', '/management/users', role='admin', json={**person, 'role': 'student', **({'class_id': class_id} if entry == 'create' else {})})
        assert response.status_code == 200, response.text
        user_id = response.json()['id']
        if entry == 'existing':
            response = call('POST', '/management/classes/' + class_id + '/members', role='admin', json={'user_id': user_id})
            assert response.status_code == 200, response.text
    member = next(item for item in call('GET', '/management/classes/' + class_id + '/members').json() if item['id'] == user_id)
    assert member['status'] == 'active'
    assert member['class_name'] == person['name']
    assert member['admin_enrolled'] is True and member['enrollment_source'] == 'admin'
    assert member['visibility_accepted'] is False
    classroom = call('GET', '/management/classes').json()[0]
    assert classroom['member_count'] == 2 and classroom['pending_count'] == 0
    with core.db() as conn:
        record = core.one(conn, 'SELECT * FROM memberships WHERE id=?', (member['membership_id'],))
        assert record['admin_enrolled_by'] == tokens['admin']['user']['id'] and record['admin_enrolled_at']
        assert core.one(conn, "SELECT id FROM audit WHERE action='membership.admin_enroll' AND target=? AND actor=?", (member['membership_id'], tokens['admin']['user']['id']))
        # Administrative admission must not activate an account or accept its agreements.
        user = core.one(conn, 'SELECT * FROM users WHERE id=?', (user_id,))
        assert not user['activated'] and user['must_change_password'] and not user['consent_version']
        assert conn.execute('SELECT COUNT(*) FROM consents WHERE user_id=?', (user_id,)).fetchone()[0] == 0
    # A direct membership does not bypass first-login activation gates.
    login = Client().post('/api/auth/login', json={'username': person['username'], 'password': PASSWORD}).json()
    assert Client().get('/api/student/classes', headers={'Authorization': 'Bearer ' + login['access_token']}).status_code == 403


@pytest.mark.parametrize('entry', ['create', 'import'])
def test_teacher_enrollment_still_requires_student_confirmation_and_teacher_approval(school, entry):
    _, call, tokens, class_id = school
    call('PATCH', '/management/classes/' + class_id, role='admin', json={'approval_required': True})
    person = {'username': 'teacher_created', 'name': '教师录入学生', 'password': PASSWORD}
    if entry == 'create':
        created = call('POST', '/management/users', json={**person, 'class_id': class_id})
        assert created.status_code == 200, created.text
        user_id = created.json()['id']
    else:
        imported = call('POST', '/management/users/import', json={'rows': [person], 'class_id': class_id})
        assert imported.status_code == 200 and imported.json()['created'] == 1, imported.text
        user_id = next(user['id'] for user in call('GET', '/management/users').json() if user['username'] == person['username'])
    member = next(item for item in call('GET', '/management/classes/' + class_id + '/members').json() if item['id'] == user_id)
    assert member['status'] == 'pending_confirmation' and not member['admin_enrolled']
    path = '/management/memberships/' + member['membership_id']
    assert call('PATCH', path, json={'status': 'active', 'admin_enrolled': True}).status_code == 409
    with core.db() as conn:
        conn.execute("UPDATE users SET activated=1,must_change_password=0,consent_version=?,subject_group_id='group-mechanics' WHERE id=?", (core.settings(conn)['agreement_version'], user_id))
    client = Client()
    session = client.post('/api/auth/login', json={'username': 'teacher_created', 'password': PASSWORD}).json()
    headers = {'Authorization': 'Bearer ' + session['access_token']}
    confirm = '/api/student/classes/' + class_id + '/confirm'
    assert client.post(confirm, headers=headers, json={'accepted': False, 'class_name': '学生班内姓名'}).status_code == 422
    assert client.post(confirm, headers=headers, json={'accepted': True, 'class_name': '学生班内姓名'}).json()['status'] == 'pending_approval'
    assert call('PATCH', path, json={'status': 'active'}).status_code == 200
    with core.db() as conn:
        record = core.one(conn, 'SELECT * FROM memberships WHERE id=?', (member['membership_id'],))
        assert record['visibility_accepted'] == 1 and record['admin_enrolled_by'] is None


@pytest.mark.parametrize('legacy_status', ['pending_confirmation', 'pending_approval'])
def test_admin_can_explicitly_admit_legacy_pending_and_class_practice_works(school, legacy_status):
    _, call, tokens, class_id = school
    student_id = tokens['student']['user']['id']
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status=?,visibility_accepted=0,class_name='' WHERE user_id=?", (legacy_status, student_id))
        conn.execute('UPDATE classes SET approval_required=1 WHERE id=?', (class_id,))
        member_id = core.one(conn, 'SELECT id FROM memberships WHERE class_id=? AND user_id=?', (class_id, student_id))['id']
    path = '/management/memberships/' + member_id
    assert call('PATCH', path, json={'status': 'active'}).status_code == 409
    assert call('PATCH', path, role='student', json={'status': 'active'}).status_code == 403
    assert call('PATCH', path, role='admin', json={'status': 'active'}).status_code == 200
    classroom = call('GET', '/student/classes', role='student').json()[0]
    assert classroom['status'] == 'active' and classroom['admin_enrolled'] is True
    assert classroom['class_name'] == tokens['student']['user']['name']
    assert call('POST', '/student/classes/' + class_id + '/confirm', role='student', json={'accepted': True, 'class_name': '不能覆盖管理员入班'}).status_code == 409
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    assert task['recipient_count'] == 1
    attempt = call('GET', '/student/assignments/' + task['id'], role='student')
    assert attempt.status_code == 200, attempt.text
    payload = answer_payload(paper, attempt.json())
    result = call('POST', '/student/assignments/' + task['id'] + '/submit', role='student', json=payload)
    assert result.status_code == 200 and result.json()['correct'] == len(paper['questions']), result.text
    # The exemption never bypasses current class access checks.
    second_task = assign(call, make_paper(call), class_id)
    assert call('POST', '/student/classes/' + class_id + '/leave', role='student').status_code == 200
    assert call('GET', '/student/assignments/' + second_task['id'], role='student').status_code == 403
    with core.db() as conn:
        assert core.one(conn, 'SELECT visibility_accepted FROM memberships WHERE id=?', (member_id,))['visibility_accepted'] == 0


def test_readding_by_teacher_clears_old_admin_basis_and_readonly_classes_stay_protected(school):
    _, call, tokens, class_id = school
    with core.db() as conn:
        student_id = tokens['student']['user']['id']
        teacher = core.one(conn, "SELECT * FROM users WHERE role='teacher'")
        # Teacher still owns the student through the fixture's original class.
        second_class = core.uid()
        conn.execute("INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,created_at) VALUES(?,?,?,'group-mechanics','2027',?,?)", (second_class, '再次入班测试', teacher['id'], core.uid(), core.iso()))
    assert call('POST', '/management/classes/' + second_class + '/members', role='admin', json={'user_id': student_id}).status_code == 200
    member = next(item for item in call('GET', '/management/classes/' + second_class + '/members').json() if item['id'] == student_id)
    assert call('PATCH', '/management/memberships/' + member['membership_id'], json={'status': 'left'}).status_code == 200
    assert call('POST', '/management/classes/' + second_class + '/members', json={'user_id': student_id}).status_code == 200
    member = next(item for item in call('GET', '/management/classes/' + second_class + '/members').json() if item['id'] == student_id)
    assert member['status'] == 'pending_confirmation' and member['admin_enrolled'] is False
    assert not member['visibility_accepted']
    assert call('PATCH', '/management/memberships/' + member['membership_id'], json={'status': 'active'}).status_code == 409
    # A pending student can be removed without first accepting visibility.
    assert call('PATCH', '/management/memberships/' + member['membership_id'], json={'status': 'left'}).status_code == 200
    assert call('POST', '/management/classes/' + second_class + '/members', json={'user_id': student_id}).status_code == 200
    assert call('PATCH', '/management/classes/' + second_class, role='admin', json={'archived': True}).status_code == 200
    assert call('PATCH', '/management/memberships/' + member['membership_id'], role='admin', json={'status': 'active'}).status_code == 409
    assert call('POST', '/management/classes/' + second_class + '/members', role='admin', json={'user_id': student_id}).status_code == 409
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=0,deleted_at=? WHERE id=?', (core.iso(), second_class))
    assert call('PATCH', '/management/memberships/' + member['membership_id'], role='admin', json={'status': 'active'}).status_code == 404


def test_membership_schema_migration_preserves_existing_pending_and_is_idempotent(tmp_path, monkeypatch):
    database = tmp_path / 'legacy-memberships.db'
    monkeypatch.setattr(core, 'DB_PATH', str(database))
    monkeypatch.setattr(core, 'APP_ENV', 'development')
    monkeypatch.setenv('DEV_SEED', 'true')
    monkeypatch.setenv('DEV_SEED_QUESTIONS', 'true')
    monkeypatch.delenv('ADMIN_TOTP_SECRET', raising=False)
    for name in ('ADMIN', 'REVIEWER', 'TEACHER', 'STUDENT'):
        monkeypatch.setenv('BOOTSTRAP_' + name + '_PASSWORD', PASSWORD)
    legacy_schema = core.SCHEMA.replace(',admin_enrolled_by TEXT REFERENCES users(id),admin_enrolled_at TEXT', '')
    with core.db() as conn:
        conn.executescript(legacy_schema)
        core.seed(conn)
        before = core.rows(conn, 'SELECT * FROM memberships')
    core.initialize()
    core.initialize()
    with core.db() as conn:
        after = core.rows(conn, 'SELECT * FROM memberships')
        assert len(after) == len(before)
        assert [{key: item[key] for key in before[0]} for item in after] == before
        assert all(item['admin_enrolled_by'] is None and item['admin_enrolled_at'] is None for item in after)
        assert conn.execute("SELECT COUNT(*) FROM audit WHERE action='membership.admin_enroll'").fetchone()[0] == 0
