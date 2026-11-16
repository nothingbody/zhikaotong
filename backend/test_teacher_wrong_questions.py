"""Teacher current wrong books and read-only submitted class-task snapshots."""
from . import app as core
from .teacher_analytics import WRONG_BOOK_SCOPE
from .test_api import question_payload
from .test_question_media import image
from .test_student_analytics import PRIVATE, assert_aggregate_only, seed_record
from .test_teacher_analytics import add_member
from .test_teaching import PASSWORD, answer_payload, assign, make_paper, school


def mistake(conn, student, question, active=1, errors=3):
    conn.execute('INSERT INTO wrong VALUES(?,?,?,?,?,?)', (student, question, errors, core.iso(), 1, active))


def assert_no_private_selection(value):
    if isinstance(value, dict):
        assert not {'selected', 'notes', 'question_snapshot', 'password_hash', 'access_token', 'birth_year', 'target'} & value.keys()
        for item in value.values():
            assert_no_private_selection(item)
    elif isinstance(value, list):
        for item in value:
            assert_no_private_selection(item)
    assert PRIVATE not in str(value)


def test_wrong_counts_roster_analytics_and_paging_share_current_profession_scope(school):
    _, call, tokens, cid = school
    sid = tokens['student']['user']['id']
    with core.db() as conn:
        _, bank = core.current_bank(conn)
        math = [question for question in bank if question['subject_id'] == 'math']
        english = next(question for question in bank if question['subject_id'] == 'english')
        mechanics = next(question for question in bank if question['subject_id'] == 'mechanics')
        conn.execute("INSERT INTO groups VALUES('wrong-personal','错题学生专业',1,'[\"math\",\"english\"]')")
        conn.execute("UPDATE users SET subject_group_id='wrong-personal' WHERE id=?", (sid,))
        direct = add_member(conn, cid, 'wrong-direct', visibility=0, direct=True)
        left = add_member(conn, cid, 'wrong-left', status='left')
        for question in [math[0], math[1], english, mechanics]:
            mistake(conn, sid, question['id'], errors=7)
        mistake(conn, sid, math[2]['id'], active=0)
        mistake(conn, sid, math[3]['id'])
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (math[3]['id'],))
        core.publish_bank(conn, tokens['admin']['user']['id'])
        mistake(conn, direct, math[0]['id'])
        mistake(conn, left, math[0]['id'])
        seed_record(conn, sid, math[0]['id'], core.iso(), 0, 15,
                    core.canonical({**math[0], 'selected': PRIVATE, 'notes': PRIVATE}))
    base = '/teaching/classes/' + cid + '/students'
    roster = call('GET', base).json()
    assert roster['wrong_summary'] == {'wrong_questions': 4, 'students_with_wrong': 2, 'student_count': 2}
    assert {student['id']: student['current_wrong_count'] for student in roster['students']} == {sid: 3, direct: 1}
    assert_aggregate_only(roster)
    analytics = call('GET', base + '/' + sid + '/analytics').json()
    assert analytics['summary']['wrong'] == 1 and analytics['wrong_book']['total'] == 3
    assert analytics['wrong_book']['scope'] == WRONG_BOOK_SCOPE
    assert_aggregate_only(analytics)
    path = base + '/' + sid + '/wrong-questions'
    first = call('GET', path + '?page_size=2').json()
    second = call('GET', path + '?page_size=2&page=2').json()
    assert first['scope'] == WRONG_BOOK_SCOPE and first['total'] == 3 and first['has_more']
    assert second['total'] == 3 and not second['has_more'] and len(second['items']) == 1
    pages = first['items'] + second['items']
    assert {item['question']['id'] for item in pages} == {math[0]['id'], math[1]['id'], english['id']}
    assert all(item['error_count'] == 7 and item['last_error_at'] and item['correct_streak'] == 1 for item in pages)
    assert all('answer' in item['question'] for item in pages)
    assert {item['id'] for item in first['available_subjects']} == {'math', 'english'}
    assert {row['subject_id']: row['total'] for row in first['subjects']} == {'math': 2, 'english': 1}
    filtered = call('GET', path + '?subject_id=math&page_size=1').json()
    assert filtered['total'] == 2 and filtered['subjects'] == first['subjects']
    filtered_summary = call('GET', base + '/' + sid + '/analytics?subject_id=math').json()['wrong_book']
    assert filtered_summary['total'] == 2 and filtered_summary['subjects'] == first['subjects']
    assert call('GET', path + '?subject_id=mechanics').status_code == 403
    assert call('GET', path + '?subject_id=foreign').status_code == 403
    empty = call('GET', path + '?page=99').json()
    assert empty['total'] == 3 and empty['items'] == [] and not empty['has_more']
    for query in ['page=0', 'page_size=0', 'page_size=51']:
        assert call('GET', path + '?' + query).status_code == 422
    for value in (first, second, filtered):
        assert_no_private_selection(value)
        assert not {'grade', 'birth_year', 'subject_group_id', 'target'} & value['student'].keys()
    with core.db() as conn:
        assert core.one(conn, "SELECT reason FROM audit WHERE action='teaching.student.wrong.view'")['reason'].endswith(cid)


def test_wrong_detail_roles_and_live_membership_class_and_profession_revocation(school):
    client, call, tokens, cid = school
    sid = tokens['student']['user']['id']
    path = '/teaching/classes/' + cid + '/students/' + sid + '/wrong-questions'
    assert client.get('/api' + path).status_code == 401
    for role in ('admin', 'student'):
        assert call('GET', path, role=role).status_code == 403
    with core.db() as conn:
        foreign = core.create_user(conn, 'wrong-other-teacher', '其他教师', 'teacher', PASSWORD, False, True)
        question = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' LIMIT 1")['id']
        mistake(conn, sid, question)
    token = client.post('/api/auth/login', json={'username': foreign['username'], 'password': PASSWORD}).json()
    assert client.get('/api' + path, headers={'Authorization': 'Bearer ' + token['access_token']}).status_code == 403
    assert call('GET', path).json()['total'] == 1
    for status in ('left', 'pending_confirmation', 'pending_approval', 'rejected'):
        with core.db() as conn:
            conn.execute('UPDATE memberships SET status=? WHERE class_id=? AND user_id=?', (status, cid, sid))
        assert call('GET', path).status_code == 404
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='active',visibility_accepted=0 WHERE class_id=? AND user_id=?", (cid, sid))
    assert call('GET', path).status_code == 404
    with core.db() as conn:
        conn.execute('UPDATE memberships SET admin_enrolled_by=?,admin_enrolled_at=? WHERE class_id=? AND user_id=?',
                     (tokens['admin']['user']['id'], core.iso(), cid, sid))
    assert call('GET', path).json()['total'] == 1
    for field in ('enabled', 'deleted_at'):
        with core.db() as conn:
            conn.execute('UPDATE users SET ' + field + '=? WHERE id=?', (0 if field == 'enabled' else core.iso(), sid))
        assert call('GET', path).status_code == 404
        with core.db() as conn:
            conn.execute('UPDATE users SET ' + field + '=? WHERE id=?', (1 if field == 'enabled' else None, sid))
    with core.db() as conn:
        conn.execute("INSERT INTO groups VALUES('wrong-disabled','已停用学生专业',0,'[\"math\"]')")
        conn.execute("UPDATE users SET subject_group_id='wrong-disabled' WHERE id=?", (sid,))
    assert call('GET', path).json()['items'] == []
    assert call('GET', path + '?subject_id=math').status_code == 403
    roster = call('GET', '/teaching/classes/' + cid + '/students').json()
    assert roster['students'][0]['current_wrong_count'] == 0 and roster['wrong_summary']['wrong_questions'] == 0
    with core.db() as conn:
        conn.execute("UPDATE users SET subject_group_id='group-mechanics' WHERE id=?", (sid,))
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (cid,))
    assert call('GET', path).status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=0,teacher_id=? WHERE id=?', (foreign['id'], cid))
    assert call('GET', path).status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET teacher_id=?,deleted_at=? WHERE id=?', (tokens['teacher']['user']['id'], core.iso(), cid))
    assert call('GET', path).status_code == 404


def test_wrong_details_use_published_snapshot_and_require_original_media_capability(school):
    client, call, tokens, cid = school
    sid = tokens['student']['user']['id']
    digest, asset = image()
    created = call('POST', '/management/questions', role='admin', json={
        **question_payload(), 'stem': '原图 {{img:' + digest + '}}', 'media': {digest: asset}})
    assert created.status_code == 200, created.text
    question = created.json()
    with core.db() as conn:
        mistake(conn, sid, question['id'])
        conn.execute("UPDATE questions SET explanation='' WHERE id=?", (question['id'],))
        core.publish_bank(conn, tokens['admin']['user']['id'])
        # Unpublished edits must not replace the released reference image.
        conn.execute("UPDATE questions SET stem='尚未发布的修订' WHERE id=?", (question['id'],))
    path = '/api/teaching/classes/' + cid + '/students/' + sid + '/wrong-questions'
    app = {'Authorization': 'Bearer ' + tokens['teacher']['access_token'], 'X-Zhikaotong-Surface': 'app'}
    assert client.get(path, headers=app).status_code == 426
    response = client.get(path, headers={**app, 'X-Question-Content': 'media-v1'})
    assert response.status_code == 200, response.text
    detail = response.json()['items'][0]['question']
    assert detail['id'] == question['id'] and detail['stem'] == question['stem']
    assert detail['media'][digest] == asset and detail['explanation'] == ''
    with core.db() as conn:
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (question['id'],))
        core.publish_bank(conn, tokens['admin']['user']['id'])
    assert client.get(path, headers=app).json()['total'] == 0


def test_teacher_task_result_is_exact_submitted_snapshot_and_never_creates_attempt(school):
    client, call, tokens, cid = school
    sid = tokens['student']['user']['id']
    with core.db() as conn:
        conn.execute("UPDATE memberships SET class_name='安全班内姓名' WHERE class_id=? AND user_id=?", (cid, sid))
    paper = make_paper(call)
    task = assign(call, paper, cid)
    path = '/teaching/assignments/' + task['id'] + '/students/' + sid + '/result'
    assert call('GET', path).status_code == 409
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_attempts').fetchone()[0] == 0
    attempt = call('GET', '/student/assignments/' + task['id'], role='student').json()
    with core.db() as conn:
        before_unsubmitted = core.rows(conn, 'SELECT * FROM teaching_attempts')
    assert call('GET', path).status_code == 409
    with core.db() as conn:
        assert before_unsubmitted == core.rows(conn, 'SELECT * FROM teaching_attempts')
    grade = call('POST', '/student/assignments/' + task['id'] + '/submit', role='student',
                 json=answer_payload(paper, attempt, correct=False)).json()
    with core.db() as conn:
        before = {table: core.rows(conn, 'SELECT * FROM ' + table + ' ORDER BY rowid')
                  for table in ('teaching_attempts', 'records', 'wrong', 'teaching_recipients')}
        conn.execute("UPDATE questions SET stem='已改题且已下线',status='offline' WHERE id=?", (paper['questions'][0]['id'],))
        core.publish_bank(conn, tokens['admin']['user']['id'])
    result = call('GET', path)
    assert result.status_code == 200, result.text
    data = result.json()
    assert data['result'] == grade
    assert data['student']['name'] == '安全班内姓名'
    assert all('selected' in question and 'answer' in question and 'correct' in question for question in data['result']['questions'])
    assert not {'birth_year', 'grade', 'target', 'subject_group_id'} & data['student'].keys()
    for role in ('admin', 'student'):
        assert call('GET', path, role=role).status_code == 403
    assert client.get('/api' + path).status_code == 401
    with core.db() as conn:
        late = add_member(conn, cid, 'task-not-recipient')
    assert call('GET', path.replace(sid, late)).status_code == 404
    with core.db() as conn:
        assert before == {table: core.rows(conn, 'SELECT * FROM ' + table + ' ORDER BY rowid') for table in before}
        assert core.one(conn, "SELECT reason FROM audit WHERE action='teaching.student.result.view'")['reason'].endswith(task['id'])


def test_teacher_task_result_live_revocation_and_media_remain_scoped_to_original_task(school):
    client, call, tokens, cid = school
    sid = tokens['student']['user']['id']
    digest, asset = image()
    question = call('POST', '/management/questions', role='admin', json={
        **question_payload(), 'stem': '原卷题图 {{img:' + digest + '}}', 'media': {digest: asset}, 'difficulty': 5}).json()
    paper = make_paper(call, rules=[{'subject_id': 'math', 'type': 'single', 'count': 1, 'difficulty': 5}])
    task = assign(call, paper, cid)
    attempt = call('GET', '/student/assignments/' + task['id'], role='student').json()
    grade = call('POST', '/student/assignments/' + task['id'] + '/submit', role='student',
                 json=answer_payload(paper, attempt)).json()
    path = '/api/teaching/assignments/' + task['id'] + '/students/' + sid + '/result'
    app = {'Authorization': 'Bearer ' + tokens['teacher']['access_token'], 'X-Zhikaotong-Surface': 'app'}
    assert client.get(path, headers=app).status_code == 426
    with core.db() as conn:
        conn.execute("UPDATE questions SET media='{}',status='offline' WHERE id=?", (question['id'],))
        core.publish_bank(conn, tokens['admin']['user']['id'])
    current = client.get(path, headers={**app, 'X-Question-Content': 'media-v1'})
    assert current.status_code == 200 and current.json()['result'] == grade
    assert current.json()['result']['questions'][0]['media'][digest] == asset
    for status in ('left', 'pending_confirmation', 'rejected'):
        with core.db() as conn:
            conn.execute('UPDATE memberships SET status=? WHERE class_id=? AND user_id=?', (status, cid, sid))
        assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 404
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='active',visibility_accepted=0 WHERE class_id=? AND user_id=?", (cid, sid))
    assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 404
    with core.db() as conn:
        conn.execute('UPDATE memberships SET admin_enrolled_by=?,admin_enrolled_at=? WHERE class_id=? AND user_id=?',
                     (tokens['admin']['user']['id'], core.iso(), cid, sid))
    assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 200
    for field in ('enabled', 'deleted_at'):
        with core.db() as conn:
            conn.execute('UPDATE users SET ' + field + '=? WHERE id=?', (0 if field == 'enabled' else core.iso(), sid))
        assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 404
        with core.db() as conn:
            conn.execute('UPDATE users SET ' + field + '=? WHERE id=?', (1 if field == 'enabled' else None, sid))
    with core.db() as conn:
        conn.execute("UPDATE groups SET enabled=0 WHERE id='group-mechanics'")
    assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE groups SET enabled=1 WHERE id='group-mechanics'")
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (cid,))
    assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=0 WHERE id=?', (cid,))
        other = core.create_user(conn, 'task-wrong-other', '其他教师', 'teacher', PASSWORD, False, True)
    other_token = client.post('/api/auth/login', json={'username': other['username'], 'password': PASSWORD}).json()
    assert client.get(path, headers={'Authorization': 'Bearer ' + other_token['access_token']}).status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET teacher_id=? WHERE id=?', (other['id'], cid))
    assert client.get(path, headers={**app, 'X-Question-Content': 'media-v1'}).status_code == 403
    assert call('GET', '/student/assignments/' + task['id'], role='student').json()['result'] == grade
