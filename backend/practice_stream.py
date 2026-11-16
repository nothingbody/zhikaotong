"""Bounded batches for repeatable, versioned continuous school practice."""
import hashlib
import secrets

from fastapi import Depends, Query, Request
from .content_categories import filter_category


def register_practice_stream(app, core):
    @app.get('/api/questions/continuous')
    def continuous_questions(request: Request,
                             subject_id: str | None = Query(None, max_length=128),
                             category_id: str | None = Query(None, max_length=64),
                             mode: str = 'all', type: str | None = None,
                             difficulty: int | None = Query(None, ge=1, le=5),
                             shuffle: bool = False,
                             seed: str | None = Query(None, pattern=r'^[a-zA-Z0-9_-]{8,64}$'),
                             offset: int = Query(0, ge=0, le=1000000),
                             limit: int = Query(20, ge=1, le=50),
                             version: int | None = Query(None, ge=0),
                             pool_hash: str | None = Query(None, pattern=r'^[a-f0-9]{64}$'),
                             actor=Depends(core.student)):
        if mode != 'all':
            core.fail(422, '持续刷题仅支持普通科目练习')
        if type not in (None, '', 'single', 'multiple', 'judge', 'fill'):
            core.fail(422, '题型筛选无效')
        if offset and (seed is None or version is None or pool_hash is None):
            core.fail(422, '继续练习需要原题库版本与续练标识')
        with core.db() as conn:
            conn.execute('BEGIN')
            if subject_id and subject_id not in core.allowed_subjects(conn, actor):
                core.fail(403, '该科目不在当前备考范围，请刷新首页')
            current_version, bank = core.student_questions(conn, actor, subject_id)
            if version is not None and current_version != version:
                core.fail(409, '题库已更新，请刷新后重新开始持续练习；已保存作答将继续同步')
            bank = filter_category(core, bank, subject_id, category_id)
            questions = [item for item in bank if (not type or item['type'] == type) and (difficulty is None or item['difficulty'] == difficulty)]
            # Also freeze the visible pool, since subject-group changes need not
            # publish a new bank. Cursor reuse can never silently skip a pool.
            identifiers = sorted(item['id'] for item in questions)
            scope = core.canonical({'ids': identifiers, 'subject_id': subject_id or '', 'type': type or '', 'difficulty': difficulty, 'shuffle': shuffle})
            if category_id:
                # Keep every old unclassified cursor fingerprint unchanged.
                scope = core.canonical({'pool': scope, 'category_id': category_id})
            fingerprint = hashlib.sha256(scope.encode()).hexdigest()
            if pool_hash is not None and pool_hash != fingerprint:
                core.fail(409, '可练题目范围已变化，请刷新后重新开始持续练习；已保存作答保留')
            if offset > len(questions):
                core.fail(422, '续练位置已超出当前题池，请重新开始')
            current_seed = seed or secrets.token_hex(16)
            if shuffle:
                questions.sort(key=lambda item: (hashlib.sha256((current_seed + ':' + item['id']).encode()).digest(), item['id']))
            else:
                questions.sort(key=lambda item: item['id'])
            selected = questions[offset:offset + limit]
            core.require_media_capability(request, selected)
            next_offset = offset + len(selected)
            return {'questions': selected, 'version': current_version, 'total': len(questions),
                    'offset': offset, 'next_offset': next_offset, 'has_more': next_offset < len(questions),
                    'seed': current_seed, 'pool_hash': fingerprint}
