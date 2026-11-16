"""Subject-first bank operations preserve status, visibility and historical data."""
import base64
import copy
import json

from . import app as core
from .test_api import activate, c, headers, login, question_payload, record
from .test_teaching import answer_payload, assign, make_paper, school
from .test_word_import_api import make_docx


def admin_api(client):
    session = login(client)
    return lambda method, path, **kwargs: client.request(method, '/api' + path, headers=headers(session), **kwargs)


def test_classification_counts_exclude_removed_and_include_empty_subjects(c):
    call = admin_api(c)
    with core.db() as conn:
        original = core.rows(conn, 'SELECT * FROM questions ORDER BY id')
        conn.execute("UPDATE questions SET status='deleted' WHERE id=?", (original[0]['id'],))
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (original[1]['id'],))
        core.publish_bank(conn, core.one(conn, "SELECT id FROM users WHERE username='admin'")['id'])
    created = call('POST', '/management/bank/subjects', json={'name': '新科目'}).json()
    result = call('GET', '/management/bank/classifications').json()
    assert result['total'] == len(original) - 1 and result['published'] == len(original) - 2
    assert sum(subject['total'] for subject in result['subjects']) == result['total']
    assert sum(subject['offline'] for subject in result['subjects']) == 1
    assert all(sum(subject['by_type'].values()) == subject['total'] for subject in result['subjects'])
    assert next(subject for subject in result['subjects'] if subject['id'] == created['id'])['total'] == 0


def test_standalone_subject_creation_and_rename_do_not_change_visibility_or_release(c):
    call = admin_api(c)
    with core.db() as conn:
        groups = core.rows(conn, 'SELECT * FROM groups')
        version = core.current_bank(conn)[0]
    created = call('POST', '/management/bank/subjects', json={'name': '　数控技术  '})
    assert created.status_code == 200, created.text
    subject = created.json()
    assert subject['name'] == '数控技术' and subject['group_id'] is None
    assert call('POST', '/management/bank/subjects', json={'name': '数控技术'}).status_code == 409
    renamed = call('PATCH', '/management/bank/subjects/' + subject['id'], json={'name': '数控基础'})
    assert renamed.status_code == 200 and renamed.json()['name'] == '数控基础'
    assert call('PATCH', '/management/bank/subjects/' + subject['id'], json={'name': '数学'}).status_code == 409
    assert call('POST', '/management/bank/subjects', json={'name': ' ', 'group_id': 'anything'}).status_code == 422
    assert call('POST', '/management/subjects', json={'name': '　数学　', 'group_id': 'group-mechanics'}).status_code == 409
    with core.db() as conn:
        assert core.rows(conn, 'SELECT * FROM groups') == groups
        assert core.current_bank(conn)[0] == version


def test_batch_move_atomic_and_status_preserving_with_one_new_snapshot(c):
    call = admin_api(c)
    with core.db() as conn:
        questions = core.rows(conn, "SELECT * FROM questions WHERE subject_id='math' ORDER BY id")
        conn.execute("UPDATE questions SET status='offline' WHERE id=?", (questions[1]['id'],))
        actor = core.one(conn, "SELECT id FROM users WHERE username='admin'")['id']
        core.publish_bank(conn, actor)
        previous = copy.deepcopy(core.current_bank(conn))
        old_knowledge = core.rows(conn, 'SELECT * FROM knowledge ORDER BY id')
    payload = {'ids': [question['id'] for question in questions[:2]], 'subject_id': 'english'}
    failed = call('POST', '/management/questions/classify', json={**payload, 'ids': payload['ids'] + ['missing']})
    assert failed.status_code == 404
    with core.db() as conn:
        assert core.current_bank(conn) == previous
        assert core.rows(conn, 'SELECT * FROM knowledge ORDER BY id') == old_knowledge
    result = call('POST', '/management/questions/classify', json=payload)
    assert result.status_code == 200, result.text
    assert result.json()['changed'] == 2 and result.json()['published_changed'] == 1
    assert result.json()['version'] == previous[0] + 1
    with core.db() as conn:
        changed = [core.one(conn, 'SELECT * FROM questions WHERE id=?', (identifier,)) for identifier in payload['ids']]
        assert [question['status'] for question in changed] == ['published', 'offline']
        assert all(question['subject_id'] == 'english' for question in changed)
        assert len({question['knowledge_id'] for question in changed}) == 1
        assert json.loads(conn.execute('SELECT questions FROM bank_releases WHERE version=?', (previous[0],)).fetchone()[0]) == previous[1]
    assert call('POST', '/management/questions/classify', json=payload).json() == {**result.json(), 'changed': 0, 'published_changed': 0}


def test_same_subject_preserves_knowledge_offline_only_move_does_not_release(c):
    call = admin_api(c)
    with core.db() as conn:
        question = core.one(conn, "SELECT * FROM questions WHERE subject_id='math'")
        version = core.current_bank(conn)[0]
    same = call('POST', '/management/questions/classify', json={'ids': [question['id']], 'subject_id': 'math'})
    assert same.json()['changed'] == 0 and same.json()['version'] == version
    with core.db() as conn:
        assert core.one(conn, 'SELECT knowledge_id FROM questions WHERE id=?', (question['id'],))['knowledge_id'] == question['knowledge_id']
    version = call('POST', '/management/questions/batch', json={'action': 'offline', 'ids': [question['id']]}).json()['version']
    moved = call('POST', '/management/questions/classify', json={'ids': [question['id']], 'subject_id': 'chinese'})
    assert moved.json()['changed'] == 1 and moved.json()['published_changed'] == 0 and moved.json()['version'] == version


def test_classification_permissions_target_validation_and_optional_knowledge(c):
    call = admin_api(c)
    question = call('GET', '/management/questions').json()[0]
    for role in ('teacher', 'student'):
        session = login(c, role)
        for method, path, body in [('GET', '/management/bank/classifications', None), ('POST', '/management/bank/subjects', {'name': '无权科目'}), ('POST', '/management/questions/classify', {'ids': [question['id']], 'subject_id': 'math'})]:
            kwargs = {'json': body} if body is not None else {}
            assert c.request(method, '/api' + path, headers=headers(session), **kwargs).status_code == 403
    for knowledge in ([], {}, True, 'not-a-node'):
        response = call('POST', '/management/questions/classify', json={'ids': [question['id']], 'subject_id': 'math', 'knowledge_id': knowledge})
        assert response.status_code == 422, response.text
    assert call('POST', '/management/questions/classify', json={'ids': [question['id']], 'subject_id': 'math', 'knowledge_id': 'english-basic'}).status_code == 422
    payload = question_payload()
    payload.pop('knowledge_id')
    created = call('POST', '/management/questions', json=payload)
    assert created.status_code == 200, created.text
    original_knowledge = created.json()['knowledge_id']
    edited = call('PUT', '/management/questions/' + created.json()['id'], json={**payload, 'stem': '省略知识点编辑'})
    assert edited.status_code == 200
    with core.db() as conn:
        assert core.one(conn, 'SELECT knowledge_id FROM questions WHERE id=?', (created.json()['id'],))['knowledge_id'] == original_knowledge
    with core.db() as conn:
        count = conn.execute('SELECT COUNT(*) FROM knowledge').fetchone()[0]
    invalid_import = call('POST', '/management/questions/import', json={'rows': [{**payload, 'subject_id': 'english'}, {**payload, 'answer': ['Z']}]})
    assert invalid_import.json()['created'] == 0 and invalid_import.json()['errors']
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM knowledge').fetchone()[0] == count


def test_manual_move_preserves_original_word_dedup_and_resists_old_preview(c):
    call = admin_api(c)
    raw = make_docx(['《语文》练习卷（1）', '一、选择题', '1. 人工调整后仍保留原始来源？', 'A.甲 B.乙', '答案：A'])
    def preview(document):
        response = call('POST', '/management/imports/word/preview', json={'filename': '分类测试.docx', 'content_base64': base64.b64encode(document).decode()})
        assert response.status_code == 200, response.text
        return response.json()
    first = preview(raw)
    def commit(parsed, subject='chinese'):
        return call('POST', '/management/imports/word/commit', json={'preview_id': parsed['preview_id'], 'source_keys': [question['source_key'] for question in parsed['questions']], 'authorization': '校内分类验证', 'subject_map': {'chinese': subject}})
    assert commit(first).json()['created'] == 1
    question = next(item for item in call('GET', '/management/questions').json() if item['source'].startswith('分类测试.docx'))
    with core.db() as conn:
        before_sources = core.rows(conn, 'SELECT * FROM word_import_items')
    assert call('POST', '/management/questions/classify', json={'ids': [question['id']], 'subject_id': 'math'}).json()['changed'] == 1
    with core.db() as conn:
        assert core.rows(conn, 'SELECT * FROM word_import_items') == before_sources
        # A canonical subject renamed after manual sorting must not produce a false conflict.
        conn.execute("UPDATE subjects SET name='文学阅读' WHERE id='chinese'")
        stored = core.one(conn, 'SELECT payload FROM word_import_previews WHERE id=?', (first['preview_id'],))
        payload = json.loads(stored['payload'])
        payload['questions'][0]['subject_hint'] = 'unmatched'
        conn.execute('UPDATE word_import_previews SET payload=? WHERE id=?', (core.canonical(payload), first['preview_id']))
    reconciled = call('POST', '/management/imports/word/classify', json={'preview_id': first['preview_id'], 'apply': True}).json()
    assert reconciled['changed'] == 0 and reconciled['protected'] == 1 and reconciled['conflicts'] == []
    second = preview(raw + b'changed-document')
    old_subject = commit(second)
    assert old_subject.json()['created'] == 0 and old_subject.json()['duplicates'] == 1
    third = preview(raw + b'another-document')
    current_subject = commit(third, 'math')
    assert current_subject.json()['created'] == 0 and current_subject.json()['duplicates'] == 1
    with core.db() as conn:
        assert core.one(conn, 'SELECT subject_id FROM questions WHERE id=?', (question['id'],))['subject_id'] == 'math'


def test_manual_put_category_change_is_protected_from_word_reconciliation(c):
    call = admin_api(c)
    created = call('POST', '/management/questions', json=question_payload()).json()
    updated = call('PUT', '/management/questions/' + created['id'], json={**question_payload(), 'subject_id': 'english', 'knowledge_id': None})
    assert updated.status_code == 200
    with core.db() as conn:
        marker = core.one(conn, 'SELECT * FROM question_classification_overrides WHERE question_id=?', (created['id'],))
        assert marker['subject_id'] == 'english'
        assert core.one(conn, "SELECT action FROM audit WHERE action='question.classify' AND target=?", (created['id'],))


def test_renamed_import_created_subject_keeps_word_mapping_and_cross_document_dedup(c):
    call = admin_api(c)
    # Exercise a legacy school's missing-subject import, independently of the
    # current five-subject development default.
    with core.db() as conn:
        conn.execute("DELETE FROM knowledge WHERE subject_id='politics'")
        conn.execute("DELETE FROM subjects WHERE id='politics'")
    raw = make_docx(['《思想政治》练习卷（1）', '一、选择题', '1. 职业精神要求什么？', 'A.认真 B.敷衍', '答案：A'])
    def preview(document):
        return call('POST', '/management/imports/word/preview', json={'filename': '思政分类.docx', 'content_base64': base64.b64encode(document).decode()}).json()
    def commit(parsed):
        return call('POST', '/management/imports/word/commit', json={'preview_id': parsed['preview_id'], 'source_keys': [question['source_key'] for question in parsed['questions']], 'authorization': '校内分类验证'}).json()
    first = preview(raw)
    assert commit(first)['created'] == 1
    original = next(subject for subject in call('GET', '/management/subjects').json() if subject['name'] == '思想政治')
    assert original['id'] != 'politics'
    assert call('PATCH', '/management/bank/subjects/' + original['id'], json={'name': '时政与职业道德'}).status_code == 200
    second = preview(raw + b'new-document-hash')
    assert second['subject_map']['politics'] == original['id']
    repeated = commit(second)
    assert repeated['created'] == 0 and repeated['duplicates'] == 1
    subjects = call('GET', '/management/subjects').json()
    assert not any(subject['name'] == '思想政治' for subject in subjects)
    assert any(subject['id'] == original['id'] and subject['name'] == '时政与职业道德' for subject in subjects)
    classified = call('POST', '/management/imports/word/classify', json={'preview_id': first['preview_id'], 'apply': True}).json()
    assert classified['changed'] == 0 and classified['conflicts'] == []


def test_cross_subject_move_retains_old_answer_sync_and_original_subject_scope(c):
    call = admin_api(c)
    student = headers(activate(c))
    question = c.get('/api/questions?subject_id=math', headers=student).json()[0]
    subject = call('POST', '/management/bank/subjects', json={'name': '独立科目'}).json()
    old_record = record(question)
    assert call('POST', '/management/questions/classify', json={'ids': [question['id']], 'subject_id': subject['id']}).status_code == 200
    assert question['id'] not in c.get('/api/bank/manifest', headers=student).json()['question_ids']
    synced = c.post('/api/student/records/batch', headers=student, json={'records': [old_record]})
    assert synced.status_code == 200 and synced.json()['results'][0]['correct'] is True
    with core.db() as conn:
        stored = core.one(conn, 'SELECT question_snapshot FROM records WHERE question_id=?', (question['id'],))
        assert json.loads(stored['question_snapshot'])['subject_id'] == 'math'


def test_moved_question_blocks_new_old_paper_assignment_but_preserves_existing_history(school):
    _, call, tokens, class_id = school
    paper = make_paper(call)
    existing = assign(call, paper, class_id)
    # Prepare a second class before changing the bank.
    second = call('POST', '/management/classes', role='admin', json={'name': '另一教学班', 'teacher_id': tokens['teacher']['user']['id'], 'subject_group_id': 'group-mechanics', 'term': '2027'}).json()
    assert call('POST', '/management/classes/' + second['id'] + '/members', role='admin', json={'user_id': tokens['student']['user']['id']}).status_code == 200
    moved = call('POST', '/management/questions/classify', role='admin', json={'ids': [paper['questions'][0]['id']], 'subject_id': 'english'})
    assert moved.status_code == 200
    assert call('POST', '/teaching/papers/' + paper['id'] + '/assign', json={'class_ids': [second['id']]}).status_code == 409
    assert assign(call, paper, class_id)['id'] == existing['id']
    attempt = call('GET', '/student/assignments/' + existing['id'], role='student').json()
    result = call('POST', '/student/assignments/' + existing['id'] + '/submit', role='student', json=answer_payload(paper, attempt))
    assert result.status_code == 200 and result.json()['correct'] == len(paper['questions'])
