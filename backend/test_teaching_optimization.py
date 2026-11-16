"""Explicit task supplementation and current-member question aggregates."""
import json

from . import app as core
from .test_api import question_payload
from .test_teaching import school, make_paper, assign, answer_payload, PASSWORD


def member(school, name, *, status='active', enabled=True, group='group-mechanics', accepted=True):
    _, _, _, class_id = school
    with core.db() as conn:
        created = core.create_user(conn, name, name, 'student', PASSWORD, False, True)
        conn.execute('UPDATE users SET enabled=?,subject_group_id=?,consent_version=? WHERE id=?',
                     (int(enabled), group, core.settings(conn)['agreement_version'], created['id']))
        conn.execute('INSERT INTO memberships(id,class_id,user_id,status,visibility_accepted,class_name,created_at) VALUES(?,?,?,?,?,?,?)',
                     (core.uid(), class_id, created['id'], status, int(accepted), name, core.iso()))
    return created['id']


def test_supplement_is_explicit_idempotent_current_member_scoped_and_preserves_grades(school):
    client, call, tokens, class_id = school
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    attempt = call('GET', '/student/assignments/' + task['id'], role='student').json()
    graded = call('POST', '/student/assignments/' + task['id'] + '/submit', role='student',
                  json=answer_payload(paper, attempt)).json()
    late = member(school, 'late_active')
    excluded = {member(school, 'late_pending', status='pending_confirmation', accepted=False),
                member(school, 'late_left', status='left'), member(school, 'late_disabled', enabled=False)}
    # The original assign route intentionally keeps its immutable recipient set.
    assert assign(call, paper, class_id)['recipient_count'] == task['recipient_count']
    path = '/teaching/assignments/' + task['id'] + '/recipients/sync'
    first = call('POST', path)
    assert first.status_code == 200, first.text
    assert first.json()['added'] == 1
    assert first.json()['unchanged'] == 1
    assert first.json()['eligible'] == 2
    assert first.json()['assignment']['recipient_count'] == 2
    assert call('POST', path).json()['added'] == 0
    with core.db() as conn:
        recipients = {r['user_id'] for r in core.rows(conn, 'SELECT user_id FROM teaching_recipients WHERE assignment_id=?', (task['id'],))}
        assert late in recipients and not recipients & excluded
        stored = core.one(conn, 'SELECT result FROM teaching_attempts WHERE assignment_id=? AND user_id=?', (task['id'], tokens['student']['user']['id']))
        assert json.loads(stored['result']) == graded
    login = client.post('/api/auth/login', json={'username': 'late_active', 'password': PASSWORD}).json()
    response = client.get('/api/student/assignments/' + task['id'], headers={'Authorization': 'Bearer ' + login['access_token']})
    assert response.status_code == 200


def test_supplement_rejects_foreign_student_archived_and_changed_bank(school):
    client, call, _, class_id = school
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    path = '/teaching/assignments/' + task['id'] + '/recipients/sync'
    assert call('POST', path, role='student').status_code == 403
    with core.db() as conn:
        stranger = core.create_user(conn, 'other_teacher', '其他教师', 'teacher', PASSWORD, False, True)
    foreign = client.post('/api/auth/login', json={'username': 'other_teacher', 'password': PASSWORD}).json()
    assert client.post('/api' + path, headers={'Authorization': 'Bearer ' + foreign['access_token']}).status_code == 403
    member(school, 'late_after_retire')
    with core.db() as conn:
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (paper['questions'][0]['id'],))
        core.publish_bank(conn, 'test-admin')
    assert call('POST', path).status_code == 409
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_recipients WHERE assignment_id=?', (task['id'],)).fetchone()[0] == 1
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (class_id,))
    assert call('POST', path).status_code == 409


def test_question_analysis_uses_task_snapshot_and_current_submitted_members_only(school):
    _, call, tokens, class_id = school
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    path = '/teaching/assignments/' + task['id'] + '/question-analysis'
    empty = call('GET', path).json()
    assert empty['submitted_count'] == 0
    assert all(row['error_rate'] is None and row['answered'] == 0 for row in empty['questions'])
    attempt = call('GET', '/student/assignments/' + task['id'], role='student').json()
    call('POST', '/student/assignments/' + task['id'] + '/submit', role='student',
         json=answer_payload(paper, attempt, correct=False))
    result = call('GET', path)
    assert result.status_code == 200, result.text
    data = result.json()
    assert data['submitted_count'] == 1 and data['scope'] == 'current_members_task_only'
    assert all(row['answered'] == row['wrong'] == 1 and row['error_rate'] == 100 for row in data['questions'])
    assert all(not {'selected', 'answer', 'user_id', 'username', 'media'} & row.keys() for row in data['questions'])
    assert call('GET', path, role='student').status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='left' WHERE class_id=? AND user_id=?", (class_id, tokens['student']['user']['id']))
    departed = call('GET', path).json()
    assert departed['submitted_count'] == 0
    assert all(row['answered'] == 0 for row in departed['questions'])
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_attempts WHERE assignment_id=?', (task['id'],)).fetchone()[0] == 1


def test_question_analysis_denies_foreign_and_archived_classes(school):
    client, call, _, class_id = school
    task = assign(call, make_paper(call), class_id)
    path = '/teaching/assignments/' + task['id'] + '/question-analysis'
    with core.db() as conn:
        core.create_user(conn, 'analysis_other', '其他教师', 'teacher', PASSWORD, False, True)
    token = client.post('/api/auth/login', json={'username': 'analysis_other', 'password': PASSWORD}).json()
    assert client.get('/api' + path, headers={'Authorization': 'Bearer ' + token['access_token']}).status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (class_id,))
    assert call('GET', path).status_code == 403


def test_teacher_history_paging_search_and_counts_keep_legacy_list_shape(school):
    _, call, _, class_id = school
    papers = [make_paper(call, title='分页练习' + str(index)) for index in range(4)]
    for paper in papers[:3]:
        assign(call, paper, class_id)
    legacy = call('GET', '/teaching/papers').json()
    assert isinstance(legacy, list) and len(legacy) == 4
    page = call('GET', '/teaching/papers?limit=2&offset=1').json()
    assert [row['id'] for row in page] == [row['id'] for row in legacy[1:3]]
    assert [row['id'] for row in call('GET', '/teaching/papers?q=分页练习2').json()] == [papers[2]['id']]
    tasks = call('GET', '/teaching/assignments').json()
    assert len(tasks) == 3
    assert call('GET', '/teaching/assignments?limit=1&offset=1').json()[0]['id'] == tasks[1]['id']
    assert len(call('GET', '/teaching/assignments?class_id=' + class_id).json()) == 3
    catalog = call('GET', '/teaching/catalog').json()
    assert catalog['paper_count'] == 4 and catalog['assignment_count'] == 3
    assert call('GET', '/teaching/papers?limit=0').status_code == 422
    assert call('GET', '/teaching/assignments?offset=-1').status_code == 422


def test_admin_enrolled_member_is_supplemented_but_incompatible_group_is_not(school):
    _, call, tokens, class_id = school
    task = assign(call, make_paper(call), class_id)
    direct = member(school, 'admin_direct', accepted=False)
    with core.db() as conn:
        conn.execute('UPDATE memberships SET admin_enrolled_by=?,admin_enrolled_at=? WHERE class_id=? AND user_id=?',
                     (tokens['admin']['user']['id'], core.iso(), class_id, direct))
        conn.execute("INSERT INTO groups(id,name,enabled,subject_ids) VALUES('other-field','其他专业',1,'[]')")
    incompatible = member(school, 'wrong_field', group='other-field')
    response = call('POST', '/teaching/assignments/' + task['id'] + '/recipients/sync')
    assert response.status_code == 200 and response.json()['added'] == 1
    with core.db() as conn:
        found = {row['user_id'] for row in core.rows(conn, 'SELECT user_id FROM teaching_recipients WHERE assignment_id=?', (task['id'],))}
        assert direct in found and incompatible not in found


def test_task_list_exposes_started_status_without_leaking_answers(school):
    _, call, _, class_id = school
    task = assign(call, make_paper(call), class_id)
    before = call('GET', '/student/assignments', role='student').json()[0]
    assert before['started'] is False and before['started_at'] is None
    call('GET', '/student/assignments/' + task['id'], role='student')
    after = call('GET', '/student/assignments', role='student').json()[0]
    assert after['started'] is True and after['started_at']
    assert not {'questions', 'answers', 'result'} & after.keys()


def test_first_assignment_respects_professions_after_shared_class_gains_specialist_subject(school):
    _, call, tokens, _ = school
    # This state is reachable through normal management APIs: students with
    # different professions first join a shared public-course class; the school
    # then extends that class's subject range with a specialist subject.
    subject = call('POST', '/management/bank/subjects', role='admin', json={'name': '计算机基础回归'})
    assert subject.status_code == 200, subject.text
    sid = subject.json()['id']
    shared = call('POST', '/management/groups', role='admin', json={
        'name': '公共课回归范围', 'enabled': True, 'subject_ids': ['math']})
    specialist = call('POST', '/management/groups', role='admin', json={
        'name': '计算机回归专业', 'enabled': True, 'subject_ids': ['math', sid]})
    assert shared.status_code == specialist.status_code == 200
    classroom = call('POST', '/management/classes', role='admin', json={
        'name': '共享公共课回归班', 'term': '2027', 'teacher_id': tokens['teacher']['user']['id'],
        'subject_group_id': shared.json()['id']})
    assert classroom.status_code == 200, classroom.text
    cid = classroom.json()['id']
    assert call('POST', '/management/classes/' + cid + '/members', role='admin',
                json={'user_id': tokens['student']['user']['id']}).status_code == 200
    computing = call('POST', '/management/users', role='admin', json={
        'username': 'shared_computing', 'name': '计算机学生', 'role': 'student', 'password': PASSWORD,
        'subject_group_id': specialist.json()['id'], 'class_id': cid})
    assert computing.status_code == 200, computing.text
    original_paper = make_paper(call)
    original_task = assign(call, original_paper, cid)
    assert original_task['recipient_count'] == 2
    attempt = call('GET', '/student/assignments/' + original_task['id'], role='student').json()
    grade = call('POST', '/student/assignments/' + original_task['id'] + '/submit', role='student',
                 json=answer_payload(original_paper, attempt)).json()
    assert call('PATCH', '/management/groups/' + shared.json()['id'], role='admin',
                json={'subject_ids': ['math', sid]}).status_code == 200
    question = call('POST', '/management/questions', role='admin', json={
        **question_payload(), 'subject_id': sid, 'knowledge_id': None,
        'stem': '专业科目权限回归题', 'status': 'published'})
    assert question.status_code == 200, question.text
    paper = make_paper(call, rules=[{'subject_id': sid, 'type': 'single', 'count': 1}])
    task = assign(call, paper, cid)
    assert task['recipient_count'] == 1
    with core.db() as conn:
        recipients = {row['user_id'] for row in core.rows(conn,
            'SELECT user_id FROM teaching_recipients WHERE assignment_id=?', (task['id'],))}
        assert recipients == {computing.json()['id']}
        assert json.loads(core.one(conn, 'SELECT result FROM teaching_attempts WHERE assignment_id=? AND user_id=?',
                                  (original_task['id'], tokens['student']['user']['id']))['result']) == grade
    assert all(row['id'] != task['id'] for row in call('GET', '/student/assignments', role='student').json())
    sync = call('POST', '/teaching/assignments/' + task['id'] + '/recipients/sync')
    assert sync.status_code == 200 and sync.json()['added'] == 0 and sync.json()['eligible'] == 1
    assert assign(call, paper, cid)['id'] == task['id']


def test_first_assignment_excludes_disabled_missing_and_incompatible_professions_and_rejects_empty(school):
    _, call, tokens, cid = school
    with core.db() as conn:
        conn.execute("INSERT INTO groups VALUES('assignment-disabled','停用专业回归',0,'[\"math\"]')")
        conn.execute("INSERT INTO groups VALUES('assignment-other','其他专业回归',1,'[\"english\"]')")
        conn.execute("UPDATE users SET subject_group_id='assignment-disabled' WHERE id=?", (tokens['student']['user']['id'],))
    missing = member(school, 'assignment_missing_profession', group=None)
    incompatible = member(school, 'assignment_other_profession', group='assignment-other')
    valid = member(school, 'assignment_valid_profession')
    task = assign(call, make_paper(call), cid)
    assert task['recipient_count'] == 1
    with core.db() as conn:
        recipients = {row['user_id'] for row in core.rows(conn,
            'SELECT user_id FROM teaching_recipients WHERE assignment_id=?', (task['id'],))}
        assert recipients == {valid}
        assert not recipients & {missing, incompatible, tokens['student']['user']['id']}
        conn.execute("UPDATE memberships SET status='left' WHERE class_id=? AND user_id=?", (cid, valid))
    fresh = make_paper(call)
    rejected = call('POST', '/teaching/papers/' + fresh['id'] + '/assign', json={'class_ids': [cid]})
    assert rejected.status_code == 422
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_assignments WHERE paper_id=?', (fresh['id'],)).fetchone()[0] == 0
        assert conn.execute('SELECT COUNT(*) FROM teaching_recipients WHERE assignment_id=?', (task['id'],)).fetchone()[0] == 1
