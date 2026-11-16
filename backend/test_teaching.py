"""Class-practice integrity, ownership, grading and immutable-order regressions."""
import copy
import json
import uuid
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta

import pytest

from . import app as core
from .teaching import OPTION_REFERENCE, shuffled_questions
from .test_api import Client

PASSWORD = 'FixtureTeaching9A!'


@pytest.fixture
def school(tmp_path, monkeypatch):
    monkeypatch.setattr(core, 'DB_PATH', str(tmp_path / 'teaching.db'))
    monkeypatch.setattr(core, 'APP_ENV', 'development')
    monkeypatch.setenv('DEV_SEED', 'true')
    monkeypatch.setenv('DEV_SEED_QUESTIONS', 'true')
    monkeypatch.delenv('ADMIN_TOTP_SECRET', raising=False)
    for name in ('ADMIN', 'REVIEWER', 'TEACHER', 'STUDENT'):
        monkeypatch.setenv('BOOTSTRAP_' + name + '_PASSWORD', PASSWORD)
    core.initialize()
    with core.db() as conn:
        cfg = core.settings(conn)
        conn.execute("UPDATE users SET must_change_password=0,activated=1,consent_version=?,subject_group_id='group-mechanics' WHERE role='student'", (cfg['agreement_version'],))
        conn.execute("UPDATE memberships SET status='active',visibility_accepted=1")
        seed = core.one(conn, 'SELECT * FROM questions LIMIT 1')
        for number, (kind, answer, difficulty) in enumerate((('fill', [['CNC', '数控'], ['机床']], 1), ('single', ['A'], 2), ('single', ['A'], 3))):
            question = {**seed, 'id': 'fixture-extra-' + str(number), 'subject_id': 'math', 'knowledge_id': 'math-basic', 'type': kind,
                        'stem': '填入两个正确词语' if kind == 'fill' else '独立选项示例 ' + str(number), 'difficulty': difficulty,
                        'options': '[]' if kind == 'fill' else core.canonical([{'key': 'A', 'text': '正确值'}, {'key': 'B', 'text': '错误值'}]),
                        'answer': core.canonical(answer), 'explanation': '固定的参考解析'}
            columns = list(question)
            conn.execute('INSERT INTO questions(' + ','.join(columns) + ') VALUES(' + ','.join('?' for _ in columns) + ')', [question[column] for column in columns])
        core.publish_bank(conn, seed['creator_id'])
    client = Client()
    tokens = {}
    for name in ('admin', 'teacher', 'student'):
        response = client.post('/api/auth/login', json={'username': name, 'password': PASSWORD})
        assert response.status_code == 200, response.text
        tokens[name] = response.json()
    def call(method, path, role='teacher', **kwargs):
        response = client.request(method, '/api' + path, headers={'Authorization': 'Bearer ' + tokens[role]['access_token']}, **kwargs)
        return response
    classes = call('GET', '/teaching/catalog').json()['classes']
    return client, call, tokens, classes[0]['id']


def make_paper(call, **overrides):
    payload = {'title': '校内班级练习', 'rules': [{'subject_id': 'math', 'type': 'single', 'count': 2, 'score': 2}],
               'shuffle_questions': True, 'shuffle_options': True, **overrides}
    response = call('POST', '/teaching/papers', json=payload)
    assert response.status_code == 200, response.text
    return response.json()


def assign(call, paper, class_id):
    response = call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [class_id]})
    assert response.status_code == 200, response.text
    return response.json()['assignments'][0]


def answer_payload(paper, attempt, correct=True):
    questions = {question['id']: question for question in paper['questions']}
    return {'client_uuid': str(uuid.uuid4()), 'answers': [
        {'question_id': question['id'], 'selected': ([slot[0] for slot in questions[question['id']]['answer']] if question['type'] == 'fill' else questions[question['id']]['answer']) if correct else []}
        for question in attempt['questions']]}


def test_full_practice_scoring_stable_orders_and_idempotent_submission(school):
    _, call, tokens, class_id = school
    paper = make_paper(call, rules=[{'subject_id': 'math', 'type': 'single', 'count': 2, 'score': 2},
                                   {'subject_id': 'math', 'type': 'fill', 'count': 1, 'score': 4},
                                   {'subject_id': 'mechanics', 'type': 'judge', 'count': 1, 'score': 3}])
    task = assign(call, paper, class_id)
    assert task['question_count'] == 4 and task['full_score'] == 11
    assert assign(call, paper, class_id)['id'] == task['id']
    path = '/student/assignments/' + task['id']
    attempt = call('GET', path, role='student').json()
    assert attempt['result'] is None and not attempt['submitted']
    assert all('answer' not in question and 'explanation' not in question for question in attempt['questions'])
    assert next(question for question in attempt['questions'] if question['type'] == 'fill')['blank_count'] == 2
    assert call('GET', path, role='student').json()['questions'] == attempt['questions']
    payload = answer_payload(paper, attempt)
    assert call('POST', path + '/submit', role='student', json={**payload, 'score': 999}).status_code == 422
    result = call('POST', path + '/submit', role='student', json=payload).json()
    assert (result['score'], result['full_score'], result['correct'], result['total']) == (11, 11, 4, 4)
    assert all('answer' in question and 'explanation' in question for question in result['questions'])
    assert call('POST', path + '/submit', role='student', json={**payload, 'answers': payload['answers'][::-1]}).json() == result
    changed = copy.deepcopy(payload)
    changed['answers'][0]['selected'] = []
    assert call('POST', path + '/submit', role='student', json=changed).status_code == 409
    assert call('POST', path + '/submit', role='student', json={**payload, 'client_uuid': str(uuid.uuid4())}).status_code == 409
    roster = call('GET', '/teaching/assignments/' + task['id'] + '/results').json()
    assert roster['assignment']['submitted_count'] == 1
    assert roster['results'][0]['score'] == 11
    assert 'questions' not in roster['results'][0]
    assert call('GET', path, role='student').json()['result'] == result
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM records WHERE user_id=?', (tokens['student']['user']['id'],)).fetchone()[0] == 0


def test_student_cannot_write_banks_or_teacher_papers_and_teacher_cannot_cross_class(school):
    client, call, tokens, class_id = school
    paper = make_paper(call)
    question_id = paper['questions'][0]['id']
    for method, path in [('POST', '/management/questions'), ('PUT', '/management/questions/' + question_id),
                         ('POST', '/management/questions/' + question_id + '/review'), ('POST', '/management/bank/publish'),
                         ('POST', '/management/questions/import'), ('POST', '/management/imports/word/preview'),
                         ('POST', '/management/imports/word/commit'), ('POST', '/management/subjects')]:
        for role in ('student', 'teacher'):
            assert call(method, path, role=role, json={}).status_code == 403, (role, path)
    for method, path in [('GET', '/teaching/catalog'), ('POST', '/teaching/papers'),
                         ('POST', '/teaching/papers/' + paper['id'] + '/assign')]:
        assert call(method, path, role='student', **({'json': {}} if method != 'GET' else {})).status_code == 403, path
    with core.db() as conn:
        other = core.create_user(conn, 'teacher_other', '其他教师', 'teacher', PASSWORD, False, True)
        other_class = core.uid()
        conn.execute("INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,created_at) VALUES(?,?,?,'group-mechanics','2027',?,?)", (other_class, '其他班级', other['id'], core.uid(), core.iso()))
    login = client.post('/api/auth/login', json={'username': 'teacher_other', 'password': PASSWORD}).json()
    foreign_header = {'Authorization': 'Bearer ' + login['access_token']}
    assert client.get('/api/teaching/papers/' + paper['id'], headers=foreign_header).status_code == 403
    assert call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [other_class]}).status_code == 403
    task = assign(call, paper, class_id)
    assert client.get('/api/teaching/assignments/' + task['id'] + '/results', headers=foreign_header).status_code == 403
    assert client.get('/api/teaching/assignments', headers=foreign_header).json() == []
    assert call('GET', '/student/assignments/' + task['id'], role='teacher').status_code == 403
    with core.db() as conn:
        conn.execute('UPDATE classes SET teacher_id=? WHERE id=?', (other['id'], class_id))
    assert call('GET', '/teaching/assignments/' + task['id'] + '/results').status_code == 403
    assert call('GET', '/teaching/assignments').json() == []


def test_papers_use_published_snapshots_and_matching_overlapping_rules(school):
    _, call, _, _ = school
    paper = make_paper(call, rules=[{'subject_id': 'math', 'type': 'single', 'count': 3},
                                   {'subject_id': 'math', 'type': 'single', 'count': 1, 'difficulty': 3, 'score': 5}])
    assert len({question['id'] for question in paper['questions']}) == 4
    assert paper['questions'][-1]['difficulty'] == 3
    original = copy.deepcopy(paper['questions'])
    with core.db() as conn:
        conn.execute("UPDATE questions SET stem='新草稿内容',status='draft',answer='[\"B\"]' WHERE id=?", (original[0]['id'],))
        core.publish_bank(conn, 'test-admin')
    assert call('GET', '/teaching/papers/' + paper['id']).json()['questions'] == original
    assert call('POST', '/teaching/papers', json={'title': '不得自定义', 'questions': original, 'rules': paper['rules']}).status_code == 422
    too_many = {'title': '不足', 'rules': [{'subject_id': 'math', 'type': 'single', 'count': 99}]}
    assert call('POST', '/teaching/papers', json=too_many).status_code == 422
    for rule in ({'subject_id': 'unavailable', 'type': 'single', 'count': 1},
                 {'subject_id': 'math', 'type': 'single', 'count': True},
                 {'subject_id': 'math', 'type': 'single', 'count': 1, 'difficulty': 6},
                 {'subject_id': 'math', 'type': 'single', 'count': 1, 'score': 0},
                 {'subject_id': 'math', 'type': 'single', 'count': 1, 'knowledge_id': 'mechanics-basic'}):
        assert call('POST', '/teaching/papers', json={'title': '校验', 'rules': [rule]}).status_code == 422


def test_withdrawn_questions_block_new_assignment_but_keep_existing_history(school):
    _, call, tokens, class_id = school
    paper = make_paper(call)
    # Until a new snapshot is published, assignments consistently use the
    # current release rather than partially edited live question rows.
    with core.db() as conn:
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (paper['questions'][0]['id'],))
    task = assign(call, paper, class_id)
    withdrawal = call('POST', '/management/questions/batch', role='admin', json={'action': 'delete', 'ids': [paper['questions'][0]['id']]})
    assert withdrawal.status_code == 200, withdrawal.text
    assert assign(call, paper, class_id)['id'] == task['id']
    attempt = call('GET', '/student/assignments/' + task['id'], role='student')
    assert attempt.status_code == 200
    submitted = call('POST', '/student/assignments/' + task['id'] + '/submit', role='student', json=answer_payload(paper, attempt.json()))
    assert submitted.status_code == 200 and submitted.json()['correct'] == 2
    classroom = call('POST', '/management/classes', json={'name': '新接收班级', 'subject_group_id': 'group-mechanics', 'term': '2027'}).json()
    assert call('POST', '/management/classes/' + classroom['id'] + '/members', role='admin', json={'user_id': tokens['student']['user']['id']}).status_code == 200
    assert call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [classroom['id']]}).status_code == 409
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_assignments WHERE paper_id=?', (paper['id'],)).fetchone()[0] == 1


def test_fixed_roster_and_pending_scope_changes_preserve_completed_grade(school):
    client, call, tokens, class_id = school
    paper = make_paper(call)
    first = assign(call, paper, class_id)
    path = '/student/assignments/' + first['id']
    attempt = call('GET', path, role='student').json()
    payload = answer_payload(paper, attempt)
    with core.db() as conn:
        late = core.create_user(conn, 'late_student', '后加入学生', 'student', PASSWORD, False, True)
        conn.execute("UPDATE users SET subject_group_id='group-mechanics',consent_version=? WHERE id=?", (core.settings(conn)['agreement_version'], late['id']))
        conn.execute("INSERT INTO memberships(id,class_id,user_id,status,visibility_accepted,class_name,created_at) VALUES(?,?,?,'active',1,'',?)", (core.uid(), class_id, late['id'], core.iso()))
        conn.execute("UPDATE memberships SET status='left' WHERE user_id=?", (tokens['student']['user']['id'],))
    late_login = client.post('/api/auth/login', json={'username': 'late_student', 'password': PASSWORD}).json()
    assert client.get('/api/student/assignments/' + first['id'], headers={'Authorization': 'Bearer ' + late_login['access_token']}).status_code == 404
    assert call('GET', '/student/assignments', role='student').json()[0]['available'] is False
    assert call('GET', path, role='student').status_code == 403
    assert call('POST', path + '/submit', role='student', json=payload).status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='active' WHERE user_id=?", (tokens['student']['user']['id'],))
    result = call('POST', path + '/submit', role='student', json=payload).json()
    with core.db() as conn:
        conn.execute("UPDATE memberships SET status='left' WHERE user_id=?", (tokens['student']['user']['id'],))
    assert call('GET', path, role='student').json()['result'] == result
    assert call('POST', path + '/submit', role='student', json=payload).json() == result
    hidden = call('GET', '/teaching/assignments/' + first['id'] + '/results').json()
    assert hidden['results'] == []
    assert hidden['assignment']['recipient_count'] == hidden['assignment']['submitted_count'] == 0
    with core.db() as conn:
        assert json.loads(core.one(conn, 'SELECT result FROM teaching_attempts WHERE assignment_id=? AND user_id=?', (first['id'], tokens['student']['user']['id']))['result']) == result


def test_submission_rejects_forged_ids_keys_duplicates_and_grades_blanks_zero(school):
    _, call, _, class_id = school
    paper = make_paper(call, rules=[{'subject_id': 'math', 'type': 'single', 'count': 1},
                                   {'subject_id': 'math', 'type': 'fill', 'count': 1}])
    task = assign(call, paper, class_id)
    path = '/student/assignments/' + task['id']
    attempt = call('GET', path, role='student').json()
    valid = answer_payload(paper, attempt)
    variants = []
    missing = copy.deepcopy(valid); missing['answers'].pop(); variants.append(missing)
    duplicate = copy.deepcopy(valid); duplicate['answers'][1] = duplicate['answers'][0]; variants.append(duplicate)
    forged = copy.deepcopy(valid); forged['answers'][0]['question_id'] = 'not-in-paper'; variants.append(forged)
    invalid = copy.deepcopy(valid)
    next(answer for answer in invalid['answers'] if answer['question_id'] == next(question['id'] for question in attempt['questions'] if question['type'] == 'single'))['selected'] = ['Z']
    variants.append(invalid)
    for payload in variants:
        assert call('POST', path + '/submit', role='student', json=payload).status_code == 422
    blanks = answer_payload(paper, attempt, False)
    result = call('POST', path + '/submit', role='student', json=blanks).json()
    assert result['score'] == 0 and result['correct'] == 0


def test_archive_subject_changes_and_atomic_assignment_validation(school):
    _, call, tokens, class_id = school
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    student_id = tokens['student']['user']['id']
    with core.db() as conn:
        conn.execute("UPDATE users SET subject_group_id=NULL WHERE id=?", (student_id,))
    assert call('GET', '/student/assignments/' + task['id'], role='student').status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE users SET subject_group_id='group-mechanics' WHERE id=?", (student_id,))
        conn.execute('UPDATE classes SET archived=1 WHERE id=?', (class_id,))
    assert call('GET', '/student/assignments/' + task['id'], role='student').status_code == 403
    assert call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [class_id]}).status_code == 409
    with core.db() as conn:
        conn.execute('UPDATE classes SET archived=0 WHERE id=?', (class_id,))
        conn.execute("UPDATE groups SET enabled=0 WHERE id='group-mechanics'")
    assert call('GET', '/student/assignments/' + task['id'], role='student').status_code == 403
    assert call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [class_id]}).status_code == 422
    with core.db() as conn:
        conn.execute("UPDATE groups SET enabled=1 WHERE id='group-mechanics'")
        conn.execute("INSERT INTO groups VALUES('only-chinese','仅语文',1,'[\"chinese\"]')")
        conn.execute("UPDATE classes SET subject_group_id='only-chinese' WHERE id=?", (class_id,))
    assert call('GET', '/student/assignments/' + task['id'], role='student').status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE classes SET subject_group_id='group-mechanics' WHERE id=?", (class_id,))
        conn.execute("INSERT INTO groups VALUES('student-disabled','已停用学生方向',0,'[\"math\"]')")
        conn.execute("UPDATE users SET subject_group_id='student-disabled' WHERE id=?", (student_id,))
    assert call('GET', '/student/assignments/' + task['id'], role='student').status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE users SET subject_group_id='group-mechanics' WHERE id=?", (student_id,))
        conn.execute("INSERT INTO classes(id,name,teacher_id,subject_group_id,term,invite_code,created_at) VALUES('other-scope','另一科目班',?,'only-chinese','2027',?,?)", (tokens['teacher']['user']['id'], core.uid(), core.iso()))
    new_paper = make_paper(call)
    assert call('POST', '/teaching/papers/' + new_paper['id'] + '/assign', json={'class_ids': [class_id, 'other-scope']}).status_code == 422
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_assignments WHERE paper_id=?', (new_paper['id'],)).fetchone()[0] == 0


def test_concurrent_start_and_submit_keep_one_order_and_grade(school):
    _, call, _, class_id = school
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    path = '/student/assignments/' + task['id']
    with ThreadPoolExecutor(max_workers=2) as workers:
        attempts = list(workers.map(lambda _: call('GET', path, role='student'), range(2)))
    assert all(response.status_code == 200 for response in attempts)
    assert attempts[0].json()['questions'] == attempts[1].json()['questions']
    payload = answer_payload(paper, attempts[0].json())
    with ThreadPoolExecutor(max_workers=2) as workers:
        results = list(workers.map(lambda _: call('POST', path + '/submit', role='student', json=payload), range(2)))
    assert all(response.status_code == 200 for response in results)
    assert results[0].json() == results[1].json()
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM teaching_attempts WHERE assignment_id=?', (task['id'],)).fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM audit WHERE target=? AND action='teaching.assignment.submit'", (task['id'],)).fetchone()[0] == 1


def test_deletion_anonymizes_roster_identity_but_keeps_grade(school):
    _, call, tokens, class_id = school
    paper = make_paper(call)
    task = assign(call, paper, class_id)
    path = '/student/assignments/' + task['id']
    attempt = call('GET', path, role='student').json()
    call('POST', path + '/submit', role='student', json=answer_payload(paper, attempt))
    with core.db() as conn:
        conn.execute("INSERT INTO deletions(user_id,status,requested_at,execute_at) VALUES(?,'pending',?,?)", (tokens['student']['user']['id'], core.iso(), core.iso(core.now() - timedelta(seconds=1))))
        assert core.execute_deletions(conn) == 1
    roster = call('GET', '/teaching/assignments/' + task['id'] + '/results').json()
    assert roster['results'] == []
    assert roster['assignment']['recipient_count'] == roster['assignment']['submitted_count'] == 0
    with core.db() as conn:
        retained = json.loads(core.one(conn, 'SELECT result FROM teaching_attempts WHERE assignment_id=? AND user_id=?', (task['id'], tokens['student']['user']['id']))['result'])
        assert retained['score'] == 4


def test_option_shuffle_policy_and_canonical_key_mapping(monkeypatch):
    class ReverseRandom:
        def shuffle(self, items):
            items.reverse()
    monkeypatch.setattr('backend.teaching.secrets.SystemRandom', ReverseRandom)
    common = {'id': 'q', 'type': 'single', 'stem': '下列说法正确的是', 'options': [{'key': key, 'text': '值' + str(index)} for index, key in enumerate('ABC')], 'answer': ['B']}
    assert not OPTION_REFERENCE.search(common['stem'])
    for text in ('A和B均正确', '选项 A', 'A项正确', '以上都正确', 'All of the above', 'Both A and B'):
        question = {**common, 'stem': text}
        result = shuffled_questions([question], False, True)[0]
        assert not result['options_shuffled'] and [option['key'] for option in result['options']] == list('ABC')
    result = shuffled_questions([common], False, True)[0]
    assert result['answer'] == ['B']
    assert [option['key'] for option in result['options']] == list('CBA')
    assert [option['display_key'] for option in result['options']] == list('ABC')
    assert next(option['text'] for option in result['options'] if option['key'] == 'B') == '值1'
    judge = {**common, 'type': 'judge', 'options': [{'key': 'A', 'text': '正确'}, {'key': 'B', 'text': '错误'}]}
    assert shuffled_questions([judge], True, True)[0]['options'] == [{'key': 'A', 'text': '正确', 'display_key': 'A'}, {'key': 'B', 'text': '错误', 'display_key': 'B'}]


def test_autonomous_shuffle_filters_whole_wrong_favorite_pool_before_limit(school, monkeypatch):
    _, call, tokens, _ = school
    class ReverseRandom:
        def shuffle(self, items):
            items.reverse()
    monkeypatch.setattr(core.secrets, 'SystemRandom', ReverseRandom)
    student_id = tokens['student']['user']['id']
    with core.db() as conn:
        _, bank = core.current_bank(conn)
        for question in bank:
            conn.execute('INSERT INTO wrong(user_id,question_id) VALUES(?,?)', (student_id, question['id']))
            conn.execute("INSERT INTO marks VALUES(?,?,'favorite',1,?)", (student_id, question['id'], core.iso()))
    expected = [question['id'] for question in bank if question['subject_id'] == 'math' and question['type'] == 'single']
    for mode in ('all', 'wrong', 'favorite'):
        query = '/questions?subject_id=math&type=single&limit=2&mode=' + mode
        assert [question['id'] for question in call('GET', query, role='student').json()] == expected[:2]
        assert [question['id'] for question in call('GET', query + '&shuffle=true', role='student').json()] == expected[::-1][:2]
