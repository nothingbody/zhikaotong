"""Unknown Word subjects require explicit mapping without bypassing content checks."""
from pathlib import Path

import pytest

from . import app as core
from .test_word_import_api import api, make_docx, preview
from .word_import import content_hash
from .word_parser import parse_docx


def target_subject(call):
    result = call('POST', '/management/bank/subjects', json={'name': '新专业真实科目测试'})
    assert result.status_code == 200, result.text
    return result.json()['id']


def commit(call, parsed, **extra):
    return call('POST', '/management/imports/word/commit', json={
        'preview_id': parsed['preview_id'], 'source_keys': [q['source_key'] for q in parsed['questions']],
        'authorization': '本地测试原文人工归类', **extra})


def test_unknown_subject_requires_explicit_existing_target_and_keeps_known_mapping(api):
    core, call, _ = api
    sid = target_subject(call)
    parsed = preview(call, make_docx(['单选题', '1. 未标明科目的题目。', 'A.甲 B.乙', '答案：A',
                                    '《数学》练习卷（1）', '单选题', '1. 计算结果是？', 'A.1 B.2', '答案：B']))
    assert len(parsed['questions']) == 2
    assert {q['subject_hint'] for q in parsed['questions']} == {'unknown', 'math'}
    missing = commit(call, parsed)
    assert missing.status_code == 200 and missing.json()['created'] == 0 and missing.json()['errors']
    for invalid in ['nonexistent-target', 123, '']:
        assert commit(call, parsed, default_subject_id=invalid).status_code == 422
    result = commit(call, parsed, default_subject_id=sid)
    assert result.status_code == 200, result.text
    assert result.json()['created'] == 2 and not result.json()['errors']
    with core.db() as conn:
        rows = core.rows(conn, "SELECT subject_id,status FROM questions WHERE source LIKE '校内题库.docx%'")
        assert {q['subject_id'] for q in rows} == {sid, 'math'}
        assert all(q['status'] == 'published' for q in rows)
        assert core.one(conn, "SELECT subject_ids FROM groups WHERE id='group-mechanics'")['subject_ids'].find(sid) == -1


def test_manual_subject_does_not_supply_missing_answers_or_media(api):
    _, call, _ = api
    sid = target_subject(call)
    missing = preview(call, make_docx(['单选题', '1. 原文没有答案。', 'A.甲 B.乙']))
    q = missing['questions'][0]
    assert q['subject_hint'] == 'unknown' and not q['eligible']
    rejected = commit(call, missing, default_subject_id=sid).json()
    assert rejected['created'] == 0 and rejected['errors']
    corrected = commit(call, missing, default_subject_id=sid, overrides={q['source_key']: {'answer': ['A']}}).json()
    assert corrected['created'] == 1 and not corrected['errors']
    image = preview(call, make_docx(['单选题', '1. 如图所示的结果。', '<w:p><w:r><w:drawing/></w:r></w:p>', 'A.甲 B.乙', '答案：A']))
    q = image['questions'][0]
    rejected = commit(call, image, default_subject_id=sid, overrides={q['source_key']: {'answer': ['A']}}).json()
    assert rejected['created'] == 0 and rejected['errors']


def test_mapping_does_not_import_drawing_tasks(api):
    _, call, _ = api
    sid = target_subject(call)
    parsed = preview(call, make_docx(['单选题', '1. 未标明科目的题。', 'A.甲 B.乙', '答案：A',
                                    '二、绘图题', '2. 请绘制零件的三视图。', '答案：略']))
    assert len(parsed['questions']) == 1 and parsed['excluded']
    assert commit(call, parsed, default_subject_id=sid).json()['created'] == 1
