"""Direct publication, withdrawals and historical grading remain consistent."""
import json
from concurrent.futures import ThreadPoolExecutor

import pytest

from . import app as core
from .test_api import activate, c, headers, login, question_payload, record


def admin_call(client, session, method, path, **kwargs):
    return client.request(method, '/api' + path, headers=headers(session), **kwargs)


def test_save_and_edit_publish_immediately_without_review(c):
    admin = login(c)
    student = headers(activate(c))
    old_version = c.get('/api/bank/manifest', headers=student).json()['version']
    created = admin_call(c, admin, 'POST', '/management/questions', json=question_payload())
    assert created.status_code == 200, created.text
    question = created.json()
    assert question['status'] == 'published' and question['version'] == old_version + 1
    assert next(item for item in c.get('/api/questions', headers=student).json() if item['id'] == question['id'])['answer'] == ['A']
    assert admin_call(c, admin, 'POST', '/management/questions/' + question['id'] + '/review', json={'approve': True}).status_code == 410
    updated = admin_call(c, admin, 'PUT', '/management/questions/' + question['id'], json={**question_payload(), 'answer': ['B'], 'status': 'published'})
    assert updated.status_code == 200 and updated.json()['version'] == old_version + 2
    assert next(item for item in c.get('/api/questions', headers=student).json() if item['id'] == question['id'])['answer'] == ['B']
    with core.db() as conn:
        previous = json.loads(conn.execute('SELECT questions FROM bank_releases WHERE version=?', (old_version+1,)).fetchone()[0])
        assert next(item for item in previous if item['id'] == question['id'])['answer'] == ['A']


def test_batch_atomicity_idempotency_visibility_and_manifest(c):
    admin = login(c)
    student = headers(activate(c))
    q = c.get('/api/questions?subject_id=math', headers=student).json()[0]
    before = c.get('/api/bank/manifest', headers=student).json()
    result = admin_call(c, admin, 'POST', '/management/questions/batch', json={'action': 'delete', 'ids': [q['id'], 'missing-id']})
    assert result.status_code == 404
    assert c.get('/api/bank/manifest', headers=student).json() == before
    result = admin_call(c, admin, 'POST', '/management/questions/batch', json={'action': 'delete', 'ids': [q['id']]}).json()
    assert result['changed'] == 1 and result['version'] == before['version'] + 1
    assert q['id'] not in c.get('/api/bank/manifest', headers=student).json()['question_ids']
    assert q['id'] not in {item['id'] for item in admin_call(c, admin, 'GET', '/management/questions').json()}
    assert q['id'] in {item['id'] for item in admin_call(c, admin, 'GET', '/management/questions?status=deleted').json()}
    repeated = admin_call(c, admin, 'POST', '/management/questions/batch', json={'action': 'delete', 'ids': [q['id']]}).json()
    assert repeated['changed'] == 0 and repeated['version'] == result['version']
    assert admin_call(c, admin, 'POST', '/management/questions/batch', json={'action': 'publish', 'ids': [q['id']]}).status_code == 404
    summary = admin_call(c, admin, 'GET', '/management/bank/summary').json()
    assert summary['counts']['deleted'] == 1 and summary['count'] == len(before['question_ids']) - 1


def test_publish_legacy_drafts_skips_intentionally_withdrawn_and_validates_all(c):
    admin = login(c)
    bank = admin_call(c, admin, 'GET', '/management/questions').json()
    identifiers = [question['id'] for question in bank[:5]]
    with core.db() as conn:
        for identifier, status in zip(identifiers, ('draft', 'pending', 'rejected', 'offline', 'deleted')):
            conn.execute('UPDATE questions SET status=? WHERE id=?', (status, identifier))
        conn.execute("UPDATE questions SET answer='[\"Z\"]' WHERE id=?", (identifiers[0],))
        old_version = core.current_bank(conn)[0]
    assert admin_call(c, admin, 'POST', '/management/bank/publish').status_code == 422
    with core.db() as conn:
        assert core.current_bank(conn)[0] == old_version
        assert core.one(conn, 'SELECT status FROM questions WHERE id=?', (identifiers[1],))['status'] == 'pending'
        conn.execute('UPDATE questions SET answer=? WHERE id=?', (core.canonical(bank[0]['answer']), identifiers[0]))
    result = admin_call(c, admin, 'POST', '/management/bank/publish').json()
    assert result['changed'] == 2
    with core.db() as conn:
        assert [core.one(conn, 'SELECT status FROM questions WHERE id=?', (identifier,))['status'] for identifier in identifiers] == ['published', 'published', 'rejected', 'offline', 'deleted']


def test_withdrawal_preserves_old_record_sync_and_clears_only_allowed_marks(c):
    admin = login(c)
    student = headers(activate(c))
    question = c.get('/api/questions?subject_id=math', headers=student).json()[0]
    endpoint = '/api/student/marks/' + question['id']
    assert c.put(endpoint, headers=student, json={'kind': 'favorite', 'active': True, 'updated_at': core.iso()}).status_code == 200
    admin_call(c, admin, 'POST', '/management/questions/batch', json={'action': 'delete', 'ids': [question['id']]})
    assert c.get('/api/student/marks?kind=favorite', headers=student).json() == []
    assert c.post('/api/student/records/batch', headers=student, json={'records': [record(question)]}).json()['results'][0]['correct'] is True
    assert c.put(endpoint, headers=student, json={'kind': 'favorite', 'active': True, 'updated_at': core.iso()}).status_code == 404
    assert c.put(endpoint, headers=student, json={'kind': 'favorite', 'active': False, 'updated_at': core.iso()}).status_code == 200
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM questions WHERE id=?', (question['id'],)).fetchone()[0] == 1
        assert conn.execute('SELECT COUNT(*) FROM records WHERE question_id=?', (question['id'],)).fetchone()[0] == 1


def test_admin_only_bank_writes_and_manifest_subject_scope(c):
    admin = login(c)
    teacher = login(c, 'teacher')
    student = activate(c)
    for actor in (teacher, student):
        assert admin_call(c, actor, 'GET', '/management/bank/summary').status_code == 403
        assert admin_call(c, actor, 'POST', '/management/questions/batch', json={'action': 'delete', 'ids': ['anything']}).status_code == 403
        assert admin_call(c, actor, 'POST', '/management/questions', json=question_payload()).status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE groups SET subject_ids='[\"math\"]' WHERE id='group-mechanics'")
    manifest = c.get('/api/bank/manifest', headers=headers(student)).json()
    assert manifest['questions'] and all(item['subject_id'] == 'math' for item in manifest['questions'])
    assert [item['id'] for item in manifest['questions']] == manifest['question_ids']
    assert [item['id'] for item in manifest['subjects']] == ['math']


def test_import_auto_publishes_once_and_rollback_keeps_history(c):
    admin = login(c)
    student = headers(activate(c))
    start = c.get('/api/bank/manifest', headers=student).json()['version']
    rows = [{**question_payload(), 'stem': '直接导入测试' + str(index)} for index in range(2)]
    result = admin_call(c, admin, 'POST', '/management/questions/import', json={'rows': rows}).json()
    assert result['created'] == 2 and result['version'] == start + 1
    repeated = admin_call(c, admin, 'POST', '/management/questions/import', json={'rows': rows}).json()
    assert repeated['created'] == 0 and repeated['duplicates'] == 2 and repeated['version'] == result['version']
    question = next(item for item in c.get('/api/questions', headers=student).json() if item['stem'] == rows[0]['stem'])
    assert c.post('/api/student/records/batch', headers=student, json={'records': [record(question)]}).status_code == 200
    rollback = admin_call(c, admin, 'POST', '/management/questions/import/' + result['batch_id'] + '/rollback').json()
    assert rollback['rolled_back'] == 2 and rollback['version'] == result['version'] + 1
    with core.db() as conn:
        assert core.one(conn, 'SELECT status FROM questions WHERE id=?', (question['id'],))['status'] == 'deleted'
        assert conn.execute('SELECT COUNT(*) FROM records WHERE question_id=?', (question['id'],)).fetchone()[0] == 1
    assert c.post('/api/student/records/batch', headers=student, json={'records': [record(question)]}).json()['results'][0]['correct'] is True


def test_development_seed_has_no_implicit_demo_content(tmp_path, monkeypatch):
    monkeypatch.setattr(core, 'DB_PATH', str(tmp_path / 'without-demo.db'))
    monkeypatch.setattr(core, 'APP_ENV', 'development')
    monkeypatch.setenv('DEV_SEED', 'true')
    monkeypatch.delenv('DEV_SEED_QUESTIONS', raising=False)
    monkeypatch.delenv('ADMIN_TOTP_SECRET', raising=False)
    core.initialize()
    with core.db() as conn:
        assert conn.execute('SELECT COUNT(*) FROM questions').fetchone()[0] == 0
        assert core.current_bank(conn) == (0, [])


def test_concurrent_admin_saves_create_distinct_monotonic_releases(c):
    admin = login(c)
    with core.db() as conn:
        start = core.current_bank(conn)[0]
    def save(index):
        return admin_call(c, admin, 'POST', '/management/questions', json={**question_payload(), 'stem': '并发保存题目' + str(index)})
    with ThreadPoolExecutor(max_workers=2) as pool:
        responses = list(pool.map(save, (1, 2)))
    assert all(response.status_code == 200 for response in responses)
    assert {response.json()['version'] for response in responses} == {start+1, start+2}
    with core.db() as conn:
        _, bank = core.current_bank(conn)
        assert all(any(item['id'] == response.json()['id'] for item in bank) for response in responses)
