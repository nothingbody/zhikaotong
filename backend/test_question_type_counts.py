"""Published question-type counts stay scoped to the student's profession."""
import json

from . import app as core
from .test_api import activate, c, headers, login, record


TYPES = {'single', 'multiple', 'judge', 'fill'}


def insert_question(conn, subject_id, kind, label, status='published'):
    # Fixtures only: no production connections or external API calls.
    prototype = core.one(conn, 'SELECT * FROM questions ORDER BY id LIMIT 1')
    question = {**prototype, 'id': 'type-count-' + label, 'subject_id': subject_id,
                'knowledge_id': subject_id + '-basic', 'type': kind,
                'stem': '题型计数测试 ' + label, 'status': status,
                'options': core.canonical([] if kind == 'fill' else
                    [{'key': 'A', 'text': '甲'}, {'key': 'B', 'text': '乙'}]),
                'answer': core.canonical([['填空答案']] if kind == 'fill' else
                    ['A', 'B'] if kind == 'multiple' else ['A'])}
    columns = list(question)
    conn.execute('INSERT INTO questions(' + ','.join(columns) + ') VALUES(' +
                 ','.join('?' for _ in columns) + ')', [question[key] for key in columns])
    return question['id']


def subject_views(client, auth):
    response = client.get('/api/subjects', headers=auth)
    dashboard = client.get('/api/student/dashboard', headers=auth)
    assert response.status_code == dashboard.status_code == 200
    subjects = response.json()
    assert dashboard.json()['subjects'] == subjects
    for subject in subjects:
        assert set(subject['by_type']) == TYPES
        assert all(type(count) is int and count >= 0 for count in subject['by_type'].values())
        assert sum(subject['by_type'].values()) == subject['total']
        assert 'answered' in subject and 'accuracy' in subject
    return {subject['id']: subject for subject in subjects}


def test_counts_use_latest_published_snapshot_and_keep_learning_fields(c):
    auth = headers(activate(c))
    original = c.get('/api/questions?subject_id=math&type=single', headers=auth).json()[0]
    submitted = c.post('/api/student/records/batch', headers=auth, json={'records': [record(original)]})
    assert submitted.status_code == 200 and submitted.json()['accepted'] == 1
    with core.db() as conn:
        actor = core.one(conn, "SELECT id FROM users WHERE username='admin'")['id']
        previous_multiple = core.one(conn, "SELECT id FROM questions WHERE subject_id='math' AND type='multiple'")['id']
        insert_question(conn, 'math', 'multiple', 'new-multiple')
        insert_question(conn, 'math', 'judge', 'new-judge')
        insert_question(conn, 'math', 'fill', 'new-fill')
        older = core.publish_bank(conn, actor)
        old_snapshot = core.one(conn, 'SELECT questions FROM bank_releases WHERE version=?', (older['version'],))['questions']
        assert previous_multiple in {q['id'] for q in json.loads(old_snapshot)}
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (previous_multiple,))
        for status in ('draft', 'pending', 'offline', 'deleted'):
            insert_question(conn, 'math', 'multiple', 'hidden-' + status, status)
        latest = core.publish_bank(conn, actor)
        assert latest['version'] > older['version']
        assert core.one(conn, 'SELECT questions FROM bank_releases WHERE version=?', (older['version'],))['questions'] == old_snapshot
        # Even a staged row is unavailable until it joins the published snapshot.
        insert_question(conn, 'math', 'multiple', 'not-yet-released')
    math = subject_views(c, auth)['math']
    assert math['by_type'] == {'single': 2, 'multiple': 1, 'judge': 1, 'fill': 1}
    assert math['total'] == 5 and math['answered'] == 1 and math['accuracy'] == 100
    assert math['name'] == '数学' and math['full_score'] == 150
    assert math['duration_minutes'] == 120
    # Counts describe exactly the same current pool as the exercise endpoints.
    for kind, expected in math['by_type'].items():
        response = c.get('/api/questions/continuous', headers=auth,
                         params={'subject_id': 'math', 'type': kind})
        assert response.status_code == 200
        assert response.json()['total'] == expected
        assert all(q['type'] == kind for q in response.json()['questions'])


def test_shared_public_course_counts_and_empty_subject_do_not_expand_profession_scope(c):
    mechanical_auth = headers(activate(c))
    with core.db() as conn:
        actor = core.one(conn, "SELECT id FROM users WHERE username='admin'")['id']
        conn.execute("INSERT INTO subjects(id,name) VALUES('computer','计算机计数测试'),('empty','空科目计数测试')")
        conn.execute("INSERT INTO knowledge(id,name,subject_id) VALUES('computer-basic','科目题目','computer')")
        conn.execute("INSERT INTO groups(id,name,enabled,subject_ids) VALUES('group-computer','计算机计数专业',1,?)",
                     (core.canonical(['math', 'computer', 'empty']),))
        student_id = core.create_user(conn, 'type-count-computer', '计算机临时学生', 'student',
                                      'TypeCounts123!', must_change=False, activated=True)['id']
        conn.execute('UPDATE users SET subject_group_id=?,consent_version=? WHERE id=?',
                     ('group-computer', core.settings(conn)['agreement_version'], student_id))
        insert_question(conn, 'computer', 'single', 'computer-single')
        insert_question(conn, 'computer', 'multiple', 'computer-multiple')
        core.publish_bank(conn, actor)
        original_mechanical = core.one(conn, "SELECT * FROM groups WHERE id='group-mechanics'")
    computer_auth = headers(login(c, 'type-count-computer', 'TypeCounts123!'))
    mechanical = subject_views(c, mechanical_auth)
    computer = subject_views(c, computer_auth)
    assert set(mechanical) == set(json.loads(original_mechanical['subject_ids']))
    assert set(computer) == {'math', 'computer', 'empty'}
    assert mechanical['math']['by_type'] == computer['math']['by_type'] == {
        'single': 2, 'multiple': 1, 'judge': 0, 'fill': 0}
    assert computer['computer']['by_type'] == {'single': 1, 'multiple': 1, 'judge': 0, 'fill': 0}
    assert computer['empty']['by_type'] == dict.fromkeys(TYPES, 0)
    assert computer['empty']['total'] == 0
    assert 'mechanics' not in computer and 'computer' not in mechanical
    with core.db() as conn:
        assert core.one(conn, "SELECT * FROM groups WHERE id='group-mechanics'") == original_mechanical
        assert conn.execute("SELECT COUNT(*) FROM questions WHERE subject_id='math'").fetchone()[0] == 3
        conn.execute("UPDATE groups SET enabled=0 WHERE id='group-computer'")
    assert subject_views(c, computer_auth) == {}
