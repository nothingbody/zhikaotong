"""Profession composition and student review keep current-bank visibility."""
import json

from . import app as core
from .test_api import activate, c, headers, login, question_payload
from .test_question_media import image


def admin_call(client):
    auth = headers(login(client))
    return lambda method, path, **kw: client.request(method, '/api' + path, headers=auth, **kw)


def new_profession(call, subjects, name='计算机测试专业', enabled=True):
    response = call('POST', '/management/groups', json={'name': name, 'enabled': enabled, 'subject_ids': subjects})
    assert response.status_code == 200, response.text
    return response.json()['id']


def test_professions_share_subjects_without_duplicating_bank_or_changing_current_scope(c):
    call = admin_call(c)
    before = call('GET', '/management/bank/summary').json()
    created = call('POST', '/management/bank/subjects', json={'name': '计算机基础测试'}).json()
    gid = new_profession(call, ['chinese', 'math', 'english', 'politics', created['id']])
    result = call('GET', '/management/professions')
    assert result.status_code == 200
    payload = result.json()
    group = next(row for row in payload['items'] if row['id'] == gid)
    assert group['subject_count'] == 5
    assert group['student_count'] == group['class_count'] == 0
    shared = next(row for row in payload['subjects'] if row['id'] == 'math')
    assert shared['profession_count'] == 2
    assert group['published_count'] == sum(row['published_count'] for row in group['subjects'])
    after = call('GET', '/management/bank/summary').json()
    assert after['total'] == before['total']
    assert [row for row in after['by_subject'] if row['subject_id'] != created['id']] == before['by_subject']
    with core.db() as conn:
        old = core.one(conn, "SELECT subject_ids FROM groups WHERE id='group-mechanics'")
        assert created['id'] not in json.loads(old['subject_ids'])
    for role in ['teacher', 'student']:
        assert c.get('/api/management/professions', headers=headers(login(c, role))).status_code == 403


def test_profession_disable_protects_active_users_and_classes_but_keeps_history(c):
    call = admin_call(c)
    student = activate(c)
    assert call('PATCH', '/management/groups/group-mechanics', json={'enabled': False}).status_code == 409
    assert call('PATCH', '/management/groups/group-mechanics', json={'subject_ids': ['math']}).status_code == 409
    with core.db() as conn:
        conn.execute("UPDATE classes SET archived=1 WHERE subject_group_id='group-mechanics'")
    # Even without active classes, an enabled student still protects the group.
    assert call('PATCH', '/management/groups/group-mechanics', json={'enabled': False}).status_code == 409
    assert call('PATCH', '/management/users/' + student['user']['id'], json={'enabled': False}).status_code == 200
    assert call('PATCH', '/management/groups/group-mechanics', json={'enabled': False}).status_code == 200
    assert call('PATCH', '/management/users/' + student['user']['id'], json={'enabled': True}).status_code == 422
    assert not c.get('/api/public/config').json()['subject_groups']
    with core.db() as conn:
        assert core.one(conn, 'SELECT subject_group_id FROM users WHERE id=?', (student['user']['id'],))['subject_group_id'] == 'group-mechanics'
        assert core.allowed_subjects(conn, {'subject_group_id': 'group-mechanics'}) == []


def test_school_assigned_profession_cannot_be_changed_during_activation(c):
    call = admin_call(c)
    gid = new_profession(call, ['math', 'english'])
    created = call('POST', '/management/users', json={'username': 'assigned-student', 'name': '测试学生',
        'role': 'student', 'password': 'InitialStudent123!', 'subject_group_id': gid})
    assert created.status_code == 200, created.text
    assert created.json()['subject_group_id'] == gid
    tokens = login(c, 'assigned-student', 'InitialStudent123!')
    auth = headers(tokens)
    c.post('/api/auth/password', headers=auth, json={'old_password': 'InitialStudent123!', 'new_password': 'NewStudent123!'})
    cfg = c.get('/api/public/config').json()
    body = {'birth_year': 2008, 'name': '测试学生', 'subject_group_id': 'group-mechanics',
            'consent_version': cfg['agreement_version'], 'teacher_visibility_accepted': True}
    assert c.post('/api/student/activate', headers=auth, json=body).status_code == 403
    assert c.post('/api/student/activate', headers=auth, json={**body, 'subject_group_id': gid}).status_code == 200
    assert {q['id'] for q in c.get('/api/subjects', headers=auth).json()} == {'math', 'english'}


def test_class_enrollment_assigns_new_students_and_rejects_incompatible_professions(c):
    call = admin_call(c)
    classroom = call('GET', '/management/classes').json()[0]
    created = call('POST', '/management/users', json={'username': 'class-student', 'name': '测试学生',
        'role': 'student', 'password': 'InitialStudent123!', 'class_id': classroom['id']})
    assert created.status_code == 200 and created.json()['subject_group_id'] == 'group-mechanics'
    gid = new_profession(call, ['math', 'english'])
    invalid = call('POST', '/management/users', json={'username': 'wrong-class', 'name': '测试学生',
        'role': 'student', 'password': 'InitialStudent123!', 'subject_group_id': gid, 'class_id': classroom['id']})
    assert invalid.status_code == 409
    assert not any(row['username'] == 'wrong-class' for row in call('GET', '/management/users').json())
    teach = headers(login(c, 'teacher'))
    assert c.post('/api/management/users', headers=teach, json={'username': 'teacher-overreach', 'name': '测试学生',
        'role': 'student', 'password': 'InitialStudent123!', 'subject_group_id': gid, 'class_id': classroom['id']}).status_code == 403
    # A public-course class may be shared without moving the student's profession.
    common = new_profession(call, ['math'], name='公共课程测试组')
    public_class = call('POST', '/management/classes', json={'name': '共享数学班测试', 'term': '测试学期',
        'teacher_id': classroom['teacher_id'], 'subject_group_id': common}).json()
    assert call('POST', '/management/classes/' + public_class['id'] + '/members', json={'user_id': created.json()['id']}).status_code == 200
    with core.db() as conn:
        assert core.one(conn, 'SELECT subject_group_id FROM users WHERE id=?', (created.json()['id'],))['subject_group_id'] == 'group-mechanics'


def test_review_paginates_current_active_marks_and_never_leaks_other_profession(c):
    call = admin_call(c)
    auth = headers(activate(c))
    student_id = c.get('/api/auth/me', headers=auth).json()['id']
    foreign = call('POST', '/management/bank/subjects', json={'name': '其他专业测试'}).json()
    foreign_q = call('POST', '/management/questions', json={**question_payload(), 'subject_id': foreign['id'],
                    'knowledge_id': None, 'stem': '其他专业题', 'status': 'published'}).json()
    questions = c.get('/api/questions', headers=auth).json()
    with core.db() as conn:
        for q in questions + [foreign_q]:
            conn.execute('INSERT INTO marks VALUES(?,?,?,?,?)', (student_id, q['id'], 'doubt', 1, core.iso()))
        # A stale/inactive mark must not count.
        conn.execute("UPDATE marks SET active=0 WHERE user_id=? AND question_id=?", (student_id, questions[0]['id']))
        for q, active in [(questions[0], 0), (questions[1], 1), (foreign_q, 1)]:
            conn.execute('INSERT INTO wrong VALUES(?,?,?,?,?,?)', (student_id, q['id'], 1, core.iso(), 0, active))
    first = c.get('/api/student/review?kind=doubt&page_size=2', headers=auth).json()
    second = c.get('/api/student/review?kind=doubt&page_size=2&page=2', headers=auth).json()
    assert first['total'] == len(questions) - 1
    assert first['has_more'] and not ({q['id'] for q in first['items']} & {q['id'] for q in second['items']})
    assert foreign_q['id'] not in {q['id'] for q in first['items'] + second['items']}
    assert sum(row['count'] for row in first['subjects']) == first['total']
    math = c.get('/api/student/review?kind=doubt&subject_id=math', headers=auth).json()
    assert all(q['subject_id'] == 'math' for q in math['items'])
    assert math['subjects'] == first['subjects']
    empty = c.get('/api/student/review?kind=doubt&page=100', headers=auth).json()
    assert not empty['items'] and not empty['has_more'] and empty['total'] == first['total']
    assert c.get('/api/student/review?kind=doubt&subject_id=' + foreign['id'], headers=auth).status_code == 403
    wrong = c.get('/api/student/review?kind=wrong', headers=auth).json()
    assert wrong['total'] == 1 and wrong['items'][0]['id'] == questions[1]['id']
    for query in ['kind=all', 'page=0', 'page_size=0', 'page_size=51']:
        assert c.get('/api/student/review?' + query, headers=auth).status_code == 422
    for role in ['teacher', 'admin']:
        assert c.get('/api/student/review', headers=headers(login(c, role))).status_code == 403


def test_review_hides_unpublished_questions_and_requires_original_media_capability(c):
    call = admin_call(c)
    auth = headers(activate(c))
    digest, asset = image()
    rich = call('POST', '/management/questions', json={**question_payload(), 'stem': '原图 {{img:' + digest + '}}',
               'media': {digest: asset}, 'status': 'published'}).json()
    for kind in ['favorite', 'doubt']:
        assert c.put('/api/student/marks/' + rich['id'], headers=auth, json={'kind': kind, 'active': True, 'updated_at': core.iso()}).status_code == 200
    app = {**auth, 'X-Zhikaotong-Surface': 'app'}
    assert c.get('/api/student/review?kind=favorite', headers=app).status_code == 426
    current = c.get('/api/student/review?kind=favorite', headers={**app, 'X-Question-Content': 'media-v1'}).json()
    assert current['items'][0]['media'][digest] == asset
    call('POST', '/management/questions/batch', json={'action': 'offline', 'ids': [rich['id']]})
    assert c.get('/api/student/review?kind=favorite', headers=auth).json()['total'] == 0


def test_deleted_student_restore_does_not_enable_an_inactive_profession(c):
    call = admin_call(c)
    user = activate(c)['user']
    assert call('DELETE', '/management/users/' + user['id'], json={'confirm': user['username'], 'reason': '专业停用保护测试'}).status_code == 200
    with core.db() as conn:
        conn.execute("UPDATE classes SET archived=1 WHERE subject_group_id='group-mechanics'")
    assert call('PATCH', '/management/groups/group-mechanics', json={'enabled': False}).status_code == 200
    assert call('POST', '/management/users/' + user['id'] + '/restore', json={'reason': '恢复保护测试'}).status_code == 409
    assert call('PATCH', '/management/groups/group-mechanics', json={'enabled': True}).status_code == 200
    assert call('POST', '/management/users/' + user['id'] + '/restore', json={'reason': '恢复保护测试'}).status_code == 200
