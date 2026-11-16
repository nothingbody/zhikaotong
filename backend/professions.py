"""Configurable study professions and current-bank student review scopes.

The legacy groups table is the profession-to-subject relation. Subjects remain
independent bank directories and may be shared by more than one profession.
"""
from collections import Counter

from fastapi import Depends, Query, Request


def group_usage(conn, core, group_id):
    students = core.one(conn, '''SELECT COUNT(*) total,
      COALESCE(SUM(enabled=1),0) active FROM users
      WHERE role='student' AND subject_group_id=? AND deleted_at IS NULL''', (group_id,))
    classes = core.one(conn, '''SELECT COUNT(*) total,
      COALESCE(SUM(archived=0),0) active FROM classes
      WHERE subject_group_id=? AND deleted_at IS NULL''', (group_id,))
    return {'student_count': students['total'], 'active_student_count': students['active'],
            'class_count': classes['total'], 'active_class_count': classes['active']}


def ensure_enabled_group(conn, core, group_id):
    group = core.one(conn, 'SELECT * FROM groups WHERE id=? AND enabled=1', (core.identifier(group_id),))
    if not group:
        core.fail(422, '专业不存在或已停用，请选择启用专业')
    return group


def ensure_class_profession(conn, core, classroom, student):
    """Assign a new student's profession or validate compatible shared subjects."""
    group = ensure_enabled_group(conn, core, classroom['subject_group_id'])
    if not student['subject_group_id']:
        conn.execute('UPDATE users SET subject_group_id=? WHERE id=?', (group['id'], student['id']))
        return
    assigned = ensure_enabled_group(conn, core, student['subject_group_id'])
    required = set(core.json.loads(group['subject_ids']))
    available = set(core.json.loads(assigned['subject_ids']))
    if not required.issubset(available):
        core.fail(409, '学生专业与班级科目范围不兼容，请先核对学校分配的专业')


def register_professions(app, core):
    @app.get('/api/management/professions')
    def profession_summary(actor=Depends(core.admin)):
        with core.db() as conn:
            version, bank = core.current_bank(conn)
            counts = Counter(question['subject_id'] for question in bank)
            subjects = core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid')
            by_id = {subject['id']: subject for subject in subjects}
            professions = []
            memberships = Counter()
            for group in core.rows(conn, 'SELECT * FROM groups ORDER BY rowid'):
                ids = core.json.loads(group['subject_ids'])
                memberships.update(ids)
                linked = [{**by_id[sid], 'published_count': counts[sid]} for sid in ids if sid in by_id]
                professions.append({**group, 'enabled': bool(group['enabled']), 'subject_ids': ids,
                    'subjects': linked, 'subject_count': len(linked),
                    'published_count': sum(subject['published_count'] for subject in linked),
                    **group_usage(conn, core, group['id'])})
            return {'items': professions, 'bank_version': version,
                    'subjects': [{**subject, 'published_count': counts[subject['id']],
                                  'profession_count': memberships[subject['id']]} for subject in subjects]}

    @app.get('/api/student/review')
    def student_review(request: Request, kind: str = 'wrong', subject_id: str | None = None,
                       page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=50),
                       actor=Depends(core.student)):
        if kind not in ('wrong', 'favorite', 'doubt'):
            core.fail(422, '复习类型须为错题、收藏或存疑')
        with core.db() as conn:
            allowed = set(core.allowed_subjects(conn, actor))
            if subject_id is not None and subject_id not in allowed:
                core.fail(403, '该科目不属于当前专业范围')
            version, bank = core.current_bank(conn)
            if kind == 'wrong':
                marked = {row['question_id'] for row in core.rows(conn,
                    'SELECT question_id FROM wrong WHERE user_id=? AND active=1', (actor['id'],))}
            else:
                marked = {row['question_id'] for row in core.rows(conn,
                    'SELECT question_id FROM marks WHERE user_id=? AND kind=? AND active=1', (actor['id'], kind))}
            pool = [question for question in bank
                    if question['id'] in marked and question['subject_id'] in allowed]
            counts = Counter(question['subject_id'] for question in pool)
            filtered = sorted((question for question in pool
                               if subject_id is None or question['subject_id'] == subject_id), key=lambda q: q['id'])
            offset = (page - 1) * page_size
            selected = filtered[offset:offset + page_size]
            core.require_media_capability(request, selected)
            return {'items': selected, 'total': len(filtered), 'page': page, 'page_size': page_size,
                    'has_more': offset + len(selected) < len(filtered), 'bank_version': version,
                    'subjects': [{**subject, 'count': counts[subject['id']]} for subject in
                        core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid') if subject['id'] in allowed]}
