"""Content categories keep subject permissions, cursor scopes and old snapshots."""
import copy
import hashlib
import json

import pytest

from . import app as core
from .content_categories import ENGLISH, annotate_questions, category_catalog, category_for
from .test_api import activate, c, headers, login


@pytest.fixture
def categorized(c):
    session = activate(c)
    auth = headers(session)
    with core.db() as conn:
        template = core.one(conn, "SELECT * FROM questions WHERE subject_id='english' LIMIT 1")
        conn.execute("UPDATE questions SET status='offline' WHERE subject_id='english'")
        ids = {}
        for category, name in ENGLISH:
            kinds = ('single', 'judge') if category == 'reading' else ('single',)
            for index, kind in enumerate(kinds):
                row = {**template, 'id': core.uid(), 'type': kind, 'stem': f'{name}-{index}',
                       'source': f'学校原题.docx · {name} · 第{index + 1}题', 'status': 'published'}
                if kind == 'judge':
                    row.update(options='[]', answer='["true"]')
                conn.execute('INSERT INTO questions(' + ','.join(row) + ') VALUES(' + ','.join('?' for _ in row) + ')', list(row.values()))
                ids.setdefault(category, []).append(row['id'])
        core.publish_bank(conn, session['user']['id'])
    return {'auth': auth, 'ids': ids, 'session': session}


def test_strict_source_sections_and_safe_explicit_metadata():
    for identifier, name in ENGLISH:
        question = {'subject_id': 'english', 'source': f'题库.docx · {name} · 第1题', 'type': 'single'}
        original = copy.deepcopy(question)
        result = annotate_questions([question])[0]
        assert (result['category_id'], result['category_name']) == (identifier, name)
        assert question == original
    for source in ('完形填空.docx · 第1题', '老师认为这道是完形填空', '练习.docx · 完形填空 · 阅读理解 · 第1题'):
        assert category_for({'subject_id': 'english', 'source': source, 'stem': '阅读理解'}) == ('general', '综合练习')
    assert category_for({'subject_id': 'chinese', 'source': '原文 · 三、古代诗文阅读（本大题共4小题） · 第17题'}) == ('classical-reading', '古代诗文阅读')
    assert category_for({'subject_id': 'renamed-english-id', 'source': '原文 | 阅读理解 | 第1题'}, '英语') == ('reading', '阅读理解')
    assert category_for({'subject_id': 'computer', 'source': '原文 | 阅读理解 | 第1题'}) == ('general', '综合练习')
    assert category_for({'subject_id': 'future-course', 'category_id': 'new-topic', 'category_name': '未来明确章节'}) == ('new-topic', '未来明确章节')
    assert category_for({'subject_id': 'english', 'category_id': 'reading', 'category_name': '错误别名'}) == ('reading', '阅读理解')
    assert category_for({'subject_id': 'english', 'category_id': 'bad/id', 'category_name': '任意', 'source': '原文 · 完形填空 · 第1题'}) == ('cloze', '完形填空')


def test_seven_content_categories_are_shared_across_professions(c, categorized):
    auth = categorized['auth']
    subjects = c.get('/api/subjects', headers=auth).json()
    english = next(s for s in subjects if s['id'] == 'english')
    assert [item['id'] for item in english['categories']] == [identifier for identifier, _ in ENGLISH]
    assert english['total'] == 8 and english['by_type'] == {'single': 7, 'multiple': 0, 'judge': 1, 'fill': 0}
    assert sum(category['total'] for category in english['categories']) == english['total']
    reading = next(category for category in english['categories'] if category['id'] == 'reading')
    assert reading['total'] == 2 and reading['by_type'] == {'single': 1, 'multiple': 0, 'judge': 1, 'fill': 0}
    mathematics = next(s for s in subjects if s['id'] == 'math')
    assert mathematics['categories'] == [{'id': 'general', 'name': '综合练习', 'total': 3,
                                         'by_type': {'single': 2, 'multiple': 1, 'judge': 0, 'fill': 0}}]
    with core.db() as conn:
        conn.execute("INSERT INTO groups(id,name,subject_ids) VALUES('computer-fixture','计算机专业测试',?)", (core.canonical(['english', 'math']),))
        conn.execute("UPDATE users SET subject_group_id='computer-fixture' WHERE id=?", (categorized['session']['user']['id'],))
    dashboard = c.get('/api/student/dashboard', headers=auth).json()
    shared = next(s for s in dashboard['subjects'] if s['id'] == 'english')
    assert shared['categories'] == english['categories']
    assert {s['id'] for s in dashboard['subjects']} == {'english', 'math'}


def test_category_filters_intersect_type_and_respect_review_membership(c, categorized):
    auth = categorized['auth']
    response = c.get('/api/questions?subject_id=english&category_id=reading&type=judge', headers=auth)
    assert response.status_code == 200, response.text
    assert len(response.json()) == 1 and response.json()[0]['type'] == 'judge'
    assert response.json()[0]['category_id'] == 'reading'
    assert c.get('/api/questions?subject_id=english&category_id=reading&type=multiple', headers=auth).json() == []
    selected = categorized['ids']['cloze'][0]
    with core.db() as conn:
        conn.execute('INSERT INTO marks VALUES(?,?,?,?,?)', (categorized['session']['user']['id'], selected, 'favorite', 1, core.iso()))
    favorites = c.get('/api/questions?subject_id=english&category_id=cloze&mode=favorite', headers=auth).json()
    assert [q['id'] for q in favorites] == [selected]
    assert c.get('/api/questions?subject_id=english&category_id=reading&mode=favorite', headers=auth).json() == []


def test_category_cursor_cannot_cross_content_scope_and_old_cursors_stay_valid(c, categorized):
    auth = categorized['auth']
    initial = c.get('/api/questions/continuous?subject_id=english&category_id=reading&limit=1', headers=auth).json()
    assert initial['total'] == 2 and initial['has_more']
    cursor = {'subject_id': 'english', 'category_id': 'reading', 'offset': initial['next_offset'],
              'seed': initial['seed'], 'version': initial['version'], 'pool_hash': initial['pool_hash'], 'limit': 1}
    second = c.get('/api/questions/continuous', params=cursor, headers=auth)
    assert second.status_code == 200 and second.json()['questions'][0]['id'] != initial['questions'][0]['id']
    assert c.get('/api/questions/continuous', params={**cursor, 'category_id': 'cloze'}, headers=auth).status_code == 409
    assert c.get('/api/questions/continuous', params={**cursor, 'category_id': ''}, headers=auth).status_code == 409
    ordinary = c.get('/api/questions/continuous?subject_id=english&limit=1', headers=auth).json()
    old_scope = core.canonical({'ids': sorted(i for ids in categorized['ids'].values() for i in ids),
                                'subject_id': 'english', 'type': '', 'difficulty': None, 'shuffle': False})
    assert ordinary['pool_hash'] == hashlib.sha256(old_scope.encode()).hexdigest()
    resume_old = {**cursor, 'category_id': '', 'pool_hash': ordinary['pool_hash'], 'seed': ordinary['seed']}
    assert c.get('/api/questions/continuous', params=resume_old, headers=auth).status_code == 200
    empty = c.get('/api/questions/continuous?subject_id=english&category_id=reading&type=multiple', headers=auth).json()
    assert empty['questions'] == [] and empty['total'] == 0 and empty['has_more'] is False


def test_manifest_and_packages_add_category_metadata_without_rewriting_history(c, categorized):
    auth = categorized['auth']
    with core.db() as conn:
        before = core.rows(conn, 'SELECT * FROM bank_releases ORDER BY version')
        current_version, current = core.current_bank(conn)
        assert json.loads(before[-1]['questions']) == current
        assert all('category_id' not in question for question in current)
    manifest = c.get('/api/bank/manifest', headers=auth).json()
    entries = {q['id']: q for q in manifest['questions']}
    for category, ids in categorized['ids'].items():
        assert all(entries[identifier]['category_id'] == category for identifier in ids)
    package = c.get('/api/bank/package?subject_id=english', headers=auth).json()
    assert package['version'] == manifest['version'] == current_version
    assert hashlib.sha256(core.canonical(package['questions']).encode()).hexdigest() == package['checksum']
    assert all(q['category_name'] == entries[q['id']]['category_name'] for q in package['questions'])
    assert all(set(q) == {'id', 'subject_id', 'category_id', 'category_name'} for q in manifest['questions'])
    with core.db() as conn:
        assert core.rows(conn, 'SELECT * FROM bank_releases ORDER BY version') == before


def test_category_validation_permissions_and_unavailable_subjects(c, categorized):
    auth = categorized['auth']
    for endpoint in ('/api/questions', '/api/questions/continuous'):
        assert c.get(endpoint + '?category_id=reading', headers=auth).status_code == 422
        assert c.get(endpoint + '?subject_id=english&category_id=missing', headers=auth).status_code == 404
        assert c.get(endpoint + '?subject_id=math&category_id=reading', headers=auth).status_code == 404
        assert c.get(endpoint + '?subject_id=english&category_id=bad/id', headers=auth).status_code == 422
        assert c.get(endpoint + '?subject_id=english&category_id=reading').status_code == 401
        for role in ('teacher', 'admin'):
            assert c.get(endpoint + '?subject_id=english&category_id=reading', headers=headers(login(c, role))).status_code == 403
    with core.db() as conn:
        conn.execute("UPDATE groups SET subject_ids=? WHERE id='group-mechanics'", (core.canonical(['math']),))
    for endpoint in ('/api/questions', '/api/questions/continuous'):
        assert c.get(endpoint + '?subject_id=english&category_id=reading', headers=auth).status_code == 403
    manifest = c.get('/api/bank/manifest', headers=auth).json()
    assert {q['subject_id'] for q in manifest['questions']} == {'math'}


def test_catalog_does_not_turn_unknown_sources_or_types_into_guessed_topics():
    questions = [{'subject_id': 'english', 'type': 'single', 'source': '手动录入，暂无章节'},
                 {'subject_id': 'new-computer', 'type': 'multiple', 'source': 'PDF | 数据库技术 | 第1题'}]
    assert category_catalog(questions, 'english') == [{'id': 'general', 'name': '综合练习', 'total': 1,
                                                     'by_type': {'single': 1, 'multiple': 0, 'judge': 0, 'fill': 0}}]
    assert category_catalog(questions, 'empty-subject') == []
    assert annotate_questions(questions)[1]['category_id'] == 'general'
