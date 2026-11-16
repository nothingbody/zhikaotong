"""One-time source repair is conservative, atomic and preserves old identities."""
import copy
import hashlib
import json

import pytest
from fastapi import HTTPException

from . import app as core
from .test_api import activate, c, headers, login, record
from .word_import import content_hash
from .word_reconcile import reconcile_word


DIGEST = hashlib.sha256(b'word-source-reconciliation-fixture').hexdigest()


def setup_source():
    with core.db() as conn:
        actor = core.one(conn, "SELECT id FROM users WHERE username='admin'")['id']
        identifier = 'legacy-word-question'
        payload = {'id': identifier, 'subject_id': 'math', 'knowledge_id': 'math-basic', 'type': 'single',
                   'stem': '原识别不完整题干', 'options': [{'key': 'A', 'text': '原选项甲'}, {'key': 'B', 'text': '原选项乙'}],
                   'answer': ['A'], 'explanation': '旧解析', 'difficulty': 3, 'source': 'source.docx · 第1题',
                   'authorization': '原导入校内使用记录', 'status': 'published', 'media': {}}
        conn.execute('INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at,media) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
                     (identifier, payload['subject_id'], payload['knowledge_id'], payload['type'], payload['stem'], core.canonical(payload['options']), core.canonical(payload['answer']), payload['explanation'], 3, payload['source'], payload['authorization'], 'published', actor, None, core.iso(), core.iso(), '{}'))
        conn.execute('INSERT INTO word_import_items VALUES(?,?,?,?)', ('source-old', DIGEST, identifier, content_hash(core, payload)))
        core.publish_bank(conn, actor)
        version = core.current_bank(conn)[0]
    repaired = {**payload, 'source_key': 'source-old', 'subject_hint': 'math', 'source_index': 1,
                'stem': '原文核对后的完整题干', 'answer': ['B'], 'explanation': '原文核对解析', 'eligible': True}
    extra = {**repaired, 'source_key': 'source-new', 'source_index': 2, 'stem': '原文遗漏的第二道题', 'source': 'source.docx · 第2题'}
    duplicate = {**extra, 'source_key': 'source-duplicate', 'source_index': 3, 'source': 'source.docx · 第3题'}
    return actor, payload, {'document_sha256': DIGEST, 'questions': [repaired, extra, duplicate]}, version


def snapshot(conn):
    names = ('questions', 'knowledge', 'word_import_items', 'question_import_batches', 'audit', 'bank_releases',
             'records', 'marks', 'wrong', 'teaching_papers', 'teaching_assignments', 'teaching_recipients', 'teaching_attempts')
    return {name: core.rows(conn, 'SELECT * FROM ' + name + ' ORDER BY rowid') for name in names}


def test_dry_run_is_read_only_even_when_new_default_knowledge_is_needed(c):
    actor, _, parsed, _ = setup_source()
    with core.db() as conn:
        before = snapshot(conn)
        assert not core.one(conn, "SELECT id FROM knowledge WHERE subject_id='math' AND name='科目题目'")
        result = reconcile_word(conn, core, parsed, actor, '用户要求原Word核对补齐')
        assert result['created'] == 1 and result['updated'] == 1
        assert result['source_occurrences'] == 3 and result['unique_questions'] == 2 and result['duplicate_occurrences'] == 1
        assert snapshot(conn) == before


def test_execute_repairs_in_place_preserves_old_grading_and_is_idempotent(c):
    actor, old_question, parsed, version = setup_source()
    student = activate(c)
    old_question['version'] = version
    answer = record(old_question)
    assert c.post('/api/student/records/batch', headers=headers(student), json={'records': [answer]}).json()['results'][0]['correct'] is True
    teacher = login(c, 'teacher')
    classroom = c.get('/api/student/classes', headers=headers(student)).json()[0]
    assert c.post('/api/student/classes/' + classroom['id'] + '/confirm', headers=headers(student), json={'accepted': True, 'class_name': '核对学生'}).status_code == 200
    paper = c.post('/api/teaching/papers', headers=headers(teacher), json={'title': '旧成绩快照', 'rules': [{'subject_id': 'math', 'type': 'single', 'count': 1, 'score': 1}]}).json()
    with core.db() as conn:
        fixed = {**core.question_public(core.one(conn, 'SELECT * FROM questions WHERE id=?', (old_question['id'],))), 'score': 1}
        conn.execute('UPDATE teaching_papers SET questions=? WHERE id=?', (core.canonical([fixed]), paper['id']))
        paper['questions'] = [fixed]
    assignment = c.post('/api/teaching/papers/' + paper['id'] + '/assign', headers=headers(teacher), json={'class_ids': [classroom['id']]}).json()['assignments'][0]
    attempt = c.get('/api/student/assignments/' + assignment['id'], headers=headers(student)).json()
    answers = {question['id']: question['answer'] for question in paper['questions']}
    submitted = c.post('/api/student/assignments/' + assignment['id'] + '/submit', headers=headers(student), json={'client_uuid': core.uid(), 'answers': [{'question_id': question['id'], 'selected': answers[question['id']]} for question in attempt['questions']]})
    assert submitted.status_code == 200, submitted.text
    with core.db() as conn:
        before = snapshot(conn)
        result = reconcile_word(conn, core, parsed, actor, '用户要求原Word核对补齐', execute=True)
        after = snapshot(conn)
        assert result['created'] == result['updated'] == 1
        assert result['existing_questions_preserved'] == 1 and result['version'] == version + 1
        repaired = core.one(conn, 'SELECT * FROM questions WHERE id=?', (old_question['id'],))
        assert repaired['stem'] == parsed['questions'][0]['stem'] and json.loads(repaired['answer']) == ['B']
        assert repaired['difficulty'] == 3 and repaired['authorization'] == old_question['authorization']
        assert core.one(conn, "SELECT question_id FROM word_import_items WHERE source_key='source-old'")['question_id'] == old_question['id']
        aliases = core.rows(conn, "SELECT question_id FROM word_import_items WHERE source_key IN ('source-new','source-duplicate')")
        assert len(aliases) == 2 and len({item['question_id'] for item in aliases}) == 1
        for table in ('records', 'marks', 'wrong', 'teaching_papers', 'teaching_assignments', 'teaching_recipients', 'teaching_attempts'):
            assert after[table] == before[table], table
        assert after['bank_releases'][:-1] == before['bank_releases']
        repeated = reconcile_word(conn, core, parsed, actor, '用户要求原Word核对补齐', execute=True)
        assert repeated['created'] == repeated['updated'] == 0 and repeated['version'] == result['version']
        assert snapshot(conn) == after
    # An old offline answer still grades against its original release after repair.
    retry = c.post('/api/student/records/batch', headers=headers(student), json={'records': [record(old_question)]})
    assert retry.status_code == 200 and retry.json()['results'][0]['correct'] is True
    admin = headers(login(c))
    second = c.post('/api/management/classes', headers=admin, json={'name': '修复后新班级', 'teacher_id': teacher['user']['id'], 'subject_group_id': 'group-mechanics', 'term': '2027'}).json()
    assert c.post('/api/management/classes/' + second['id'] + '/members', headers=admin, json={'user_id': student['user']['id']}).status_code == 200
    refused = c.post('/api/teaching/papers/' + paper['id'] + '/assign', headers=headers(teacher), json={'class_ids': [second['id']]})
    assert refused.status_code == 409 and '修订' in refused.text
    repeated_task = c.post('/api/teaching/papers/' + paper['id'] + '/assign', headers=headers(teacher), json={'class_ids': [classroom['id']]}).json()
    assert repeated_task['assignments'][0]['id'] == assignment['id']


@pytest.mark.parametrize('status', ['offline', 'deleted'])
def test_repair_never_reactivates_intentionally_withdrawn_existing_questions(c, status):
    actor, old, parsed, _ = setup_source()
    with core.db() as conn:
        conn.execute('UPDATE questions SET status=? WHERE id=?', (status, old['id']))
        core.publish_bank(conn, actor)
        reconcile_word(conn, core, parsed, actor, '来源核对', execute=True)
        assert core.one(conn, 'SELECT status FROM questions WHERE id=?', (old['id'],))['status'] == status
        assert old['id'] not in {question['id'] for question in core.current_bank(conn)[1]}


@pytest.mark.parametrize('manual', ['classification', 'content'])
def test_manual_admin_changes_block_automatic_source_repair(c, manual):
    actor, old, parsed, _ = setup_source()
    with core.db() as conn:
        if manual == 'classification':
            conn.execute('INSERT INTO question_classification_overrides VALUES(?,?,?,?,?)', (old['id'], 'math', 'math-basic', actor, core.iso()))
        else:
            core.audit(conn, actor, 'question.update', old['id'])
        before = snapshot(conn)
        with pytest.raises(HTTPException) as error:
            reconcile_word(conn, core, parsed, actor, '来源核对', execute=True)
        assert error.value.status_code == 409
        assert snapshot(conn) == before


@pytest.mark.parametrize('conflict', ['missing_source', 'split_alias', 'merge_identities'])
def test_ambiguous_source_identity_changes_are_rejected_atomically(c, conflict):
    actor, old, parsed, _ = setup_source()
    parsed = copy.deepcopy(parsed)
    with core.db() as conn:
        if conflict == 'missing_source':
            parsed['questions'] = parsed['questions'][1:]
        elif conflict == 'split_alias':
            conn.execute('INSERT INTO word_import_items VALUES(?,?,?,?)', ('source-new', DIGEST, old['id'], 'legacy-alias'))
        else:
            other = core.one(conn, "SELECT * FROM questions WHERE id<>? LIMIT 1", (old['id'],))
            conn.execute('INSERT INTO word_import_items VALUES(?,?,?,?)', ('source-new', DIGEST, other['id'], 'legacy-other'))
            parsed['questions'][1] = {**parsed['questions'][0], 'source_key': 'source-new'}
            parsed['questions'] = parsed['questions'][:2]
        before = snapshot(conn)
        with pytest.raises(HTTPException) as error:
            reconcile_word(conn, core, parsed, actor, '来源核对', execute=True)
        assert error.value.status_code == 409
        assert snapshot(conn) == before


def test_source_key_owned_by_another_document_is_not_rebound(c):
    actor, old, parsed, _ = setup_source()
    with core.db() as conn:
        conn.execute('INSERT INTO word_import_items VALUES(?,?,?,?)', ('source-new', hashlib.sha256(b'another-document').hexdigest(), old['id'], 'foreign-document-fingerprint'))
        before = snapshot(conn)
        with pytest.raises(HTTPException) as error:
            reconcile_word(conn, core, parsed, actor, '来源核对', execute=True)
        assert error.value.status_code == 409
        assert snapshot(conn) == before
