import base64
import importlib
import io
import json
import uuid
import zipfile
from xml.sax.saxutils import escape

import pytest
from fastapi.testclient import TestClient

from backend.question_types import grade_question, normalize_fill_answer


def make_docx(lines):
    body = ''.join('<w:p><w:r><w:t xml:space="preserve">' + escape(line) + '</w:t></w:r></w:p>' if not line.startswith('<w:') else line for line in lines)
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('word/document.xml', '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>' + body + '</w:body></w:document>')
    return stream.getvalue()


def test_preview_distinguishes_source_occurrences_from_unique_questions(api):
    _,call,_=api
    raw=make_docx(['《语文》练习卷（1）','一、选择题','1. 相同的原文题目？','A.甲 B.乙','答案：A','2. 相同的原文题目？','A.甲 B.乙','答案：A'])
    response=call('POST','/management/imports/word/preview',json={'filename':'重复核对.docx','content_base64':base64.b64encode(raw).decode()})
    assert response.status_code==200,response.text
    summary=response.json()['summary']
    assert summary['eligible']==2 and summary['unique_eligible']==1 and summary['duplicate_eligible']==1
    assert summary['by_subject']['chinese']['total']==2
    assert summary['by_subject']['chinese']['unique_eligible']==1


@pytest.fixture
def api(tmp_path, monkeypatch):
    core = importlib.import_module('backend.app')
    monkeypatch.setattr(core, 'DB_PATH', str(tmp_path / 'word.db'))
    monkeypatch.setattr(core, 'APP_ENV', 'development')
    monkeypatch.setenv('DEV_SEED', 'true')
    monkeypatch.setenv('DEV_SEED_QUESTIONS', 'true')
    monkeypatch.delenv('ADMIN_TOTP_SECRET', raising=False)
    monkeypatch.setenv('WORD_BANK_DIR', str(tmp_path))
    for role in ['ADMIN', 'REVIEWER', 'TEACHER', 'STUDENT']:
        monkeypatch.setenv('BOOTSTRAP_' + role + '_PASSWORD', 'FixturePassword9A!')
    with TestClient(core.app) as client:
        headers = {}
        for username in ['admin', 'reviewer', 'teacher', 'student']:
            response = client.post('/api/auth/login', json={'username': username, 'password': 'FixturePassword9A!'})
            assert response.status_code == 200
            headers[username] = {'Authorization': 'Bearer ' + response.json()['access_token']}
        def call(method, path, role='admin', **kwargs):
            return client.request(method, '/api' + path, headers=headers[role], **kwargs)
        yield core, call, tmp_path


def preview(call, raw):
    response = call('POST', '/management/imports/word/preview', json={'filename': '校内题库.docx', 'content_base64': base64.b64encode(raw).decode()})
    assert response.status_code == 200, response.text
    return response.json()


def test_fill_normalization_order_repeated_and_no_expression_execution():
    assert normalize_fill_answer('　ＣＮＣ\u00a0 A　') == 'cnc a'
    question = {'type': 'fill', 'answer': [['输入轴'], ['输出轴']]}
    assert grade_question(question, ['输入轴', '输出轴'])
    assert not grade_question(question, ['输出轴', '输入轴'])
    assert grade_question({'type': 'fill', 'answer': [['齿轮'], ['齿轮']]}, ['齿轮', '齿轮'])
    assert not grade_question({'type': 'fill', 'answer': [['2']]}, ['1+1'])
    assert not grade_question({'type': 'fill', 'answer': [['x']]}, [''])


def test_word_scope_override_dedup_and_atomic_rollback(api):
    core, call, directory = api
    raw = make_docx(['《机械》练习卷（1）', '一、单项选择题', '1. 机械制图采用哪种投影？', 'A. 正投影', 'B. 透视', '答案：A', '2. 缺答案需要校对。', 'A. 甲', 'B. 乙', '二、填空题', '3. 两个部件为____和____。', '答案：输入轴；输出轴', '三、绘图题', '4. 请绘制零件的三视图。', '四、选择题', '5. 如图所示选什么？', '<w:p><w:r><w:drawing/></w:r></w:p>', 'A. 甲', 'B. 乙', '答案：A'])
    (directory / 'bank.docx').write_bytes(raw)
    assert call('GET', '/management/imports/word/local', role='teacher').status_code == 403
    files = call('GET', '/management/imports/word/local').json()['files']
    assert len(files) == 1
    assert call('POST', '/management/imports/word/preview', json={'local_file_id': '../bank.docx'}).status_code == 404
    local = call('POST', '/management/imports/word/preview', json={'local_file_id': files[0]['id']})
    assert local.status_code == 200
    parsed = local.json()
    assert parsed['summary']['single'] == 3 and parsed['summary']['fill'] == 1
    assert any('绘' in item['reason'] for item in parsed['excluded'])
    by_number = {q['source_label']: q for q in parsed['questions']}
    missing, image = by_number['第2题'], by_number['第5题']
    assert not missing['eligible'] and not image['eligible']
    payload = {'preview_id': parsed['preview_id'], 'source_keys': [q['source_key'] for q in parsed['questions'] if q['eligible']], 'authorization': '用户提供校内题库，测试导入', 'subject_map': {'mechanics': 'mechanics'}}
    assert call('POST', '/management/imports/word/commit', role='reviewer', json=payload).status_code == 404
    bad = call('POST', '/management/imports/word/commit', json={**payload, 'source_keys': [image['source_key']], 'overrides': {image['source_key']: {'answer': ['A']}}})
    assert bad.json()['created'] == 0 and bad.json()['errors']
    result = call('POST', '/management/imports/word/commit', json=payload).json()
    assert result['created'] == 2
    history = call('GET', '/management/questions/import/batches').json()
    assert history[0]['kind'] == 'word' and history[0]['created_count'] == 2
    assert call('GET', '/management/questions/import/batches', role='teacher').status_code == 403
    repeated = call('POST', '/management/imports/word/commit', json=payload).json()
    assert repeated['created'] == 0 and repeated['duplicates'] == 2
    completed = call('POST', '/management/imports/word/commit', json={**payload, 'source_keys': [missing['source_key']], 'overrides': {missing['source_key']: {'answer': ['B']}}}).json()
    assert completed['created'] == 1 and not completed['errors']
    rolled = call('POST', '/management/questions/import/' + result['batch_id'] + '/rollback')
    assert rolled.json()['rolled_back'] == 2
    assert next(item for item in call('GET', '/management/questions/import/batches').json() if item['id'] == result['batch_id'])['remaining_count'] == 0
    with core.db() as connection:
        assert connection.execute('SELECT COUNT(*) FROM word_import_items').fetchone()[0] == 3
    assert call('POST', '/management/imports/word/commit', json=payload).json()['duplicates'] == 2


def test_fill_real_records_preserve_slot_order_and_version_snapshot(api):
    core, call, _ = api
    raw = make_docx(['《机械》练习卷（1）', '一、填空题', '1. 两个部件为____和____。', '答案：输入轴；输出轴', '2. 控制系统简称____。', '答案：CNC'])
    parsed = preview(call, raw)
    result = call('POST', '/management/imports/word/commit', json={'preview_id': parsed['preview_id'], 'source_keys': [q['source_key'] for q in parsed['questions']], 'authorization': '校内题库验收', 'subject_map': {'mechanics': 'mechanics'}}).json()
    assert result['created'] == 2
    imported = [question for question in call('GET', '/management/questions').json() if question['type'] == 'fill']
    for question in imported:
        assert call('PUT', '/management/questions/' + question['id'], json={**question, 'status': 'pending'}).status_code == 200
        assert call('POST', '/management/questions/' + question['id'] + '/review', role='reviewer', json={'approve': True}).status_code == 410
    version = call('POST', '/management/bank/publish').json()['version']
    assert call('POST', '/auth/password', role='student', json={'old_password': 'FixturePassword9A!', 'new_password': 'ChangedFixture9A!'}).status_code == 200
    config = call('GET', '/public/config').json()
    assert call('POST', '/student/activate', role='student', json={'birth_year': 2008, 'name': '验收学生', 'subject_group_id': 'group-mechanics', 'exam_year': 2027, 'consent_version': config['agreement_version'], 'teacher_visibility_accepted': True}).status_code == 200
    question = next(item for item in imported if len(item['answer']) == 2)
    record = {'client_uuid': str(uuid.uuid4()), 'question_id': question['id'], 'question_version': version, 'selected': ['输入轴', '输出轴'], 'duration_seconds': 12, 'answered_at': core.iso()}
    result = call('POST', '/student/records/batch', role='student', json={'records': [record]})
    assert result.status_code == 200 and result.json()['results'][0]['correct'] is True
    assert call('POST', '/student/records/batch', role='student', json={'records': [record]}).json()['duplicates'] == 1
    swapped = {**record, 'selected': ['输出轴', '输入轴']}
    assert call('POST', '/student/records/batch', role='student', json={'records': [swapped]}).status_code == 409
    swapped['client_uuid'] = str(uuid.uuid4())
    assert call('POST', '/student/records/batch', role='student', json={'records': [swapped]}).json()['results'][0]['correct'] is False
    abbreviation = next(item for item in imported if len(item['answer']) == 1)
    assert call('POST', '/student/records/batch', role='student', json={'records': [{**record, 'client_uuid': str(uuid.uuid4()), 'question_id': abbreviation['id'], 'selected': ['　ｃｎｃ\u00a0']}]}).json()['results'][0]['correct'] is True
    assert call('PUT', '/management/questions/' + question['id'], json={**question, 'answer': [['新答案'], ['新答案']], 'status': 'pending'}).status_code == 200
    assert call('POST', '/management/questions/' + question['id'] + '/review', role='reviewer', json={'approve': True}).status_code == 410
    call('POST', '/management/bank/publish')
    historical = call('POST', '/student/records/batch', role='student', json={'records': [{**record, 'client_uuid': str(uuid.uuid4())}]})
    assert historical.json()['results'][0]['correct'] is True


def test_word_failed_commit_rolls_back_created_subjects_and_preview_expires(api):
    core, call, _ = api
    # This rollback case requires an actually missing legacy subject.
    with core.db() as connection:
        connection.execute("DELETE FROM knowledge WHERE subject_id='politics'")
        connection.execute("DELETE FROM subjects WHERE id='politics'")
    parsed = preview(call, make_docx(['《思想政治》练习卷（1）', '一、选择题', '1. 职业要求？', 'A. 认真', 'B. 敷衍', '答案：A', '2. 另一个职业要求？', 'A. 认真', 'B. 敷衍', '答案：A']))
    questions = parsed['questions']
    payload = {'preview_id': parsed['preview_id'], 'source_keys': [q['source_key'] for q in questions], 'authorization': '校内题库验收', 'create_missing_subjects': True, 'overrides': {questions[1]['source_key']: {'answer': []}}}
    failed = call('POST', '/management/imports/word/commit', json=payload)
    assert failed.json()['created'] == 0 and failed.json()['errors']
    with core.db() as connection:
        assert connection.execute("SELECT COUNT(*) FROM subjects WHERE name='思想政治'").fetchone()[0] == 0
        assert connection.execute("SELECT COUNT(*) FROM knowledge WHERE name='Word导入待归类'").fetchone()[0] == 0
        connection.execute("UPDATE word_import_previews SET expires_at='2000-01-01T00:00:00Z' WHERE id=?", (parsed['preview_id'],))
    assert call('POST', '/management/imports/word/commit', json=payload).status_code == 410


def test_judge_import_auto_subjects_and_false_answer_grading(api):
    core, call, _ = api
    parsed = preview(call, make_docx(['《机械》练习卷（1）', '一、判断题', '1. 传动装置不能传递动力。', '答案：错误', '2. 轴承能支承轴。', '答案：√', '《思想政治》练习卷（1）', '一、是非题（正确选A，错误选B）', '1. 职业道德没有意义。', '答案：B']))
    assert parsed['summary']['judge'] == 3
    assert parsed['summary']['by_subject']['mechanics']['judge'] == 2
    assert parsed['summary']['by_subject']['politics']['judge'] == 1
    imported = call('POST', '/management/imports/word/commit', json={'preview_id': parsed['preview_id'], 'source_keys': [q['source_key'] for q in parsed['questions']], 'authorization': '用户提供校内测试题库'}).json()
    assert imported['created'] == 3 and not imported['errors']
    questions = [q for q in call('GET', '/management/questions').json() if q['source'].startswith('校内题库.docx')]
    subjects = {subject['id']: subject['name'] for subject in call('GET', '/management/subjects').json()}
    assert sum(subjects[q['subject_id']] == '思想政治' for q in questions) == 1
    assert all(q['type'] == 'judge' and q['options'] == [{'key': 'A', 'text': '正确'}, {'key': 'B', 'text': '错误'}] for q in questions)
    for question in questions:
        assert call('PUT', '/management/questions/' + question['id'], json={**question, 'status': 'pending'}).status_code == 200
        assert call('POST', '/management/questions/' + question['id'] + '/review', role='reviewer', json={'approve': True}).status_code == 410
    version = call('POST', '/management/bank/publish').json()['version']
    call('POST', '/auth/password', role='student', json={'old_password': 'FixturePassword9A!', 'new_password': 'ChangedFixture9A!'})
    config = call('GET', '/public/config').json()
    call('POST', '/student/activate', role='student', json={'birth_year': 2008, 'name': '验收学生', 'subject_group_id': 'group-mechanics', 'exam_year': 2027, 'consent_version': config['agreement_version'], 'teacher_visibility_accepted': True})
    question = next(q for q in questions if q['subject_id'] == 'mechanics' and q['answer'] == ['B'])
    record = {'client_uuid': str(uuid.uuid4()), 'question_id': question['id'], 'question_version': version, 'selected': ['B'], 'duration_seconds': 10, 'answered_at': core.iso()}
    result = call('POST', '/student/records/batch', role='student', json={'records': [record]})
    assert result.status_code == 200 and result.json()['results'][0]['correct'] is True
    wrong = call('POST', '/student/records/batch', role='student', json={'records': [{**record, 'client_uuid': str(uuid.uuid4()), 'selected': ['A']}]})
    assert wrong.json()['results'][0]['correct'] is False
    assert call('POST', '/management/imports/word/commit', json={'preview_id': parsed['preview_id'], 'source_keys': [q['source_key'] for q in parsed['questions']], 'authorization': '用户提供校内测试题库'}).json()['duplicates'] == 3


def test_source_backed_classification_reconciles_published_and_preserves_releases(api):
    core, call, _ = api
    parsed = preview(call, make_docx(['《语文》练习卷（1）', '一、选择题', '1. 字词正确的是？', 'A.甲 B.乙', '答案：A']))
    assert call('POST', '/management/imports/word/commit', json={'preview_id': parsed['preview_id'], 'source_keys': [parsed['questions'][0]['source_key']], 'authorization': '校内自编验收题库'}).json()['created'] == 1
    question = next(q for q in call('GET', '/management/questions').json() if q['source'].startswith('校内题库.docx'))
    with core.db() as conn:
        conn.execute("UPDATE questions SET subject_id='math',knowledge_id='math-basic' WHERE id=?", (question['id'],))
    payload = {'preview_id': parsed['preview_id'], 'apply': False}
    assert call('POST', '/management/imports/word/classify', role='teacher', json=payload).status_code == 403
    assert call('POST', '/management/imports/word/classify', role='reviewer', json=payload).status_code == 404
    audited = call('POST', '/management/imports/word/classify', json=payload).json()
    assert audited['checked'] == 1 and audited['changed'] == 1 and not audited['applied']
    with core.db() as conn:
        assert conn.execute('SELECT subject_id FROM questions WHERE id=?', (question['id'],)).fetchone()[0] == 'math'
    applied = call('POST', '/management/imports/word/classify', json={**payload, 'apply': True}).json()
    assert applied['changed'] == 1 and applied['by_subject'] == {'语文': 1}
    fixed = next(q for q in call('GET', '/management/questions').json() if q['id'] == question['id'])
    assert fixed['subject_id'] == 'chinese'
    assert call('PUT', '/management/questions/' + question['id'], json={**fixed, 'status': 'pending'}).status_code == 200
    call('POST', '/management/questions/' + question['id'] + '/review', role='reviewer', json={'approve': True})
    call('POST', '/management/bank/publish')
    # A later manual move is authoritative; source classification does not
    # reverse it or change any earlier immutable release.
    call('PUT', '/management/questions/' + question['id'], json={**fixed, 'subject_id': 'math', 'knowledge_id': 'math-basic', 'status': 'draft'})
    protected = call('POST', '/management/imports/word/classify', json={**payload, 'apply': True}).json()
    assert protected['protected'] == 1 and protected['changed'] == 0
    with core.db() as conn:
        assert conn.execute('SELECT subject_id FROM questions WHERE id=?', (question['id'],)).fetchone()[0] == 'math'
        old = json.loads(conn.execute('SELECT questions FROM bank_releases WHERE version=?', (protected['version']-1,)).fetchone()[0])
        assert next(item for item in old if item['id']==question['id'])['subject_id']=='chinese'


def test_management_bank_lists_more_than_one_thousand_questions(api):
    core, call, _ = api
    with core.db() as conn:
        seed = core.one(conn, 'SELECT * FROM questions LIMIT 1')
        for _ in range(1001):
            conn.execute('INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at) SELECT ?,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at FROM questions WHERE id=?', (core.uid(), seed['id']))
    assert len(call('GET', '/management/questions').json()) == 1011
    assert len(call('GET', '/management/questions?limit=1000').json()) == 1000
    assert call('GET', '/management/questions?limit=5001').status_code == 422
