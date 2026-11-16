"""Administrator bank operations publish one immutable snapshot per transaction."""
from fastapi import Body, Depends
from .bank_pagination import release_summary


def register_bank_management(app, core):
    @app.get('/api/management/bank/summary')
    def bank_summary(actor=Depends(core.admin)):
        with core.db() as conn:
            version, published_count = release_summary(conn)
            counts = {status: 0 for status in ('published', 'draft', 'pending', 'rejected', 'offline', 'deleted')}
            counts.update({row['status']: row['count'] for row in core.rows(conn, 'SELECT status,COUNT(*) count FROM questions GROUP BY status')})
            subjects = core.rows(conn, "SELECT s.id subject_id,s.name,COUNT(q.id) count,SUM(CASE WHEN q.status='published' THEN 1 ELSE 0 END) published FROM subjects s LEFT JOIN questions q ON q.subject_id=s.id AND q.status<>'deleted' GROUP BY s.id ORDER BY s.rowid")
            by_type = {kind: 0 for kind in ('single', 'multiple', 'judge', 'fill')}
            by_type.update({row['type']: row['count'] for row in core.rows(conn, "SELECT type,COUNT(*) count FROM questions WHERE status<>'deleted' GROUP BY type")})
            return {'version': version, 'count': published_count, 'total': sum(count for status, count in counts.items() if status != 'deleted'), 'counts': counts, 'by_subject': subjects, 'by_type': by_type}

    @app.post('/api/management/questions/batch')
    def batch_questions(data: dict = Body(...), actor=Depends(core.admin)):
        action, identifiers = data.get('action'), data.get('ids')
        if action not in ('publish', 'offline', 'delete'):
            core.fail(422, '请选择发布、下线或移除操作')
        if not isinstance(identifiers, list) or not 1 <= len(identifiers) <= 5000 or not all(isinstance(value, str) and 1 <= len(value) <= 128 for value in identifiers) or len(set(identifiers)) != len(identifiers):
            core.fail(422, '请选择1至5000道不同题目')
        target = {'publish': 'published', 'offline': 'offline', 'delete': 'deleted'}[action]
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            questions = []
            for identifier in identifiers:
                question = core.one(conn, 'SELECT * FROM questions WHERE id=?', (identifier,))
                if not question or (question['status'] == 'deleted' and action != 'delete'):
                    core.fail(404, '题目不存在或已移除')
                if action == 'publish' and question['status'] != 'published':
                    core.validate_question(conn, {**core.question_public(question), 'authorization': question['authorization'], 'status': 'published'})
                questions.append(question)
            changed = 0
            for question in questions:
                if question['status'] == target:
                    continue
                conn.execute('UPDATE questions SET status=?,reviewer_id=NULL,updated_at=? WHERE id=?', (target, core.iso(), question['id']))
                core.audit(conn, actor['id'], 'question.' + action, question['id'])
                changed += 1
            if changed:
                release = core.publish_bank(conn, actor['id'])
            else:
                version, current = core.current_bank(conn)
                release = {'version': version, 'count': len(current)}
            return {'changed': changed, **release}

    @app.get('/api/bank/manifest')
    def bank_manifest(actor=Depends(core.student)):
        with core.db() as conn:
            version, bank = core.student_questions(conn, actor)
            subjects = {row['id']: row['name'] for row in core.rows(conn, 'SELECT id,name FROM subjects')}
            allowed = core.allowed_subjects(conn, actor)
            questions = [{key: question[key] for key in ('id', 'subject_id', 'category_id', 'category_name')} for question in bank]
            return {'version': version, 'questions': questions, 'question_ids': [question['id'] for question in bank],
                    'subjects': [{'id': subject, 'name': subjects.get(subject, subject), 'count': sum(question['subject_id'] == subject for question in bank)} for subject in allowed]}
