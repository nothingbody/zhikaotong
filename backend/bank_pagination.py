"""Subject-scoped bank reads fetch one bounded page or identifiers only."""
from fastapi import Depends, Query


def release_summary(conn):
    # SQLite counts the immutable JSON without materializing its images in Python.
    row = conn.execute('SELECT version,json_array_length(questions) FROM bank_releases ORDER BY version DESC LIMIT 1').fetchone()
    return (row[0], row[1]) if row else (0, 0)


def question_scope(conn, core, subject_id, query, kind, status):
    core.identifier(subject_id)
    if not core.one(conn, 'SELECT id FROM subjects WHERE id=?', (subject_id,)):
        core.fail(404, '科目不存在')
    if kind not in ('', 'single', 'multiple', 'judge', 'fill'):
        core.fail(422, '不支持的题型筛选')
    if status not in ('', 'published', 'offline', 'unpublished', 'draft', 'pending', 'rejected', 'deleted'):
        core.fail(422, '不支持的状态筛选')
    clauses, values = ['subject_id=?'], [subject_id]
    if status == 'unpublished':
        clauses.append("status IN ('draft','pending','rejected')")
    elif status:
        clauses.append('status=?')
        values.append(status)
    else:
        clauses.append("status<>'deleted'")
    if kind:
        clauses.append('type=?')
        values.append(kind)
    if query:
        # Search behaves like a literal substring, including percent/underscore.
        escaped = query.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_')
        clauses.append("(stem LIKE ? ESCAPE '\\' OR source LIKE ? ESCAPE '\\')")
        values.extend(['%' + escaped + '%'] * 2)
    return ' AND '.join(clauses), values


def register_bank_pagination(app, core):
    core.SCHEMA += '''
    CREATE INDEX IF NOT EXISTS questions_subject_page ON questions(subject_id,created_at DESC,id DESC);
    '''

    @app.get('/api/management/questions/page')
    def question_page(subject_id: str = Query(..., min_length=1, max_length=128),
                      page: int = Query(1, ge=1, le=1000000),
                      page_size: int = Query(20, ge=1, le=100),
                      q: str = Query('', max_length=100), type: str = '', status: str = '',
                      actor=Depends(core.admin)):
        with core.db() as conn:
            # COUNT and items must describe one read snapshot, even during edits.
            conn.execute('BEGIN')
            where, values = question_scope(conn, core, subject_id, q, type, status)
            total = conn.execute('SELECT COUNT(*) FROM questions WHERE ' + where, values).fetchone()[0]
            pages = max(1, (total + page_size - 1) // page_size)
            actual_page = min(page, pages)
            questions = core.rows(conn, 'SELECT * FROM questions WHERE ' + where + ' ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?', values + [page_size, (actual_page - 1) * page_size])
            version = conn.execute('SELECT COALESCE(MAX(version),0) FROM bank_releases').fetchone()[0]
            conn.commit()
            core.audit(conn, actor['id'], 'questions.page', subject_id)
            items = [{**core.question_public(item, version), **{key: item[key] for key in ('authorization', 'status', 'creator_id', 'reviewer_id', 'created_at', 'updated_at')}} for item in questions]
            return {'items': items, 'total': total, 'page': actual_page, 'page_size': page_size, 'pages': pages, 'subject_id': subject_id}

    @app.get('/api/management/questions/ids')
    def question_identifiers(subject_id: str = Query(..., min_length=1, max_length=128),
                             q: str = Query('', max_length=100), type: str = '', status: str = '',
                             actor=Depends(core.admin)):
        with core.db() as conn:
            conn.execute('BEGIN')
            where, values = question_scope(conn, core, subject_id, q, type, status)
            identifiers = [row[0] for row in conn.execute('SELECT id FROM questions WHERE ' + where + ' ORDER BY created_at DESC,id DESC LIMIT 5001', values)]
            if len(identifiers) > 5000:
                core.fail(422, '筛选结果超过5000道，请缩小筛选范围后再全选')
            conn.commit()
            core.audit(conn, actor['id'], 'questions.selection', subject_id)
            return {'ids': identifiers, 'total': len(identifiers), 'subject_id': subject_id}
