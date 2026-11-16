"""Current-class summaries and scoped wrong books, without private selections."""
from collections import Counter
import json
from datetime import datetime, timedelta, timezone

from fastapi import Depends, Query, Request

from .student_analytics import METRICS_SQL, SHANGHAI, _metrics, _practice_scope, _utc_order

WRONG_BOOK_SCOPE = 'current_class_and_student_subjects_active_wrong_published'


def active_student_clause(member='m', user='u'):
    return (f"{member}.status='active' AND ({member}.visibility_accepted=1 OR "
            f"({member}.admin_enrolled_by IS NOT NULL AND {member}.admin_enrolled_at IS NOT NULL)) "
            f"AND {user}.role='student' AND {user}.enabled=1 AND {user}.deleted_at IS NULL")


def _class_scope(conn, core, class_id, actor):
    if actor['role'] != 'teacher':
        core.fail(403, '此入口仅供任课教师查看本人班级')
    classroom = core.class_scope(conn, class_id, actor)
    if classroom['archived']:
        core.fail(403, '归档班级不提供当前学生学习分析')
    group = core.one(conn, 'SELECT enabled,subject_ids FROM groups WHERE id=?', (classroom['subject_group_id'],))
    if not group or not group['enabled']:
        core.fail(403, '班级科目组已停用')
    try:
        values = json.loads(group['subject_ids'])
    except (ValueError, TypeError):
        values = None
    if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
        core.fail(403, '班级科目范围无效，请联系管理员')
    allowed = list(dict.fromkeys(values))
    return classroom, allowed


def _roster(conn, core, class_id, student_id=None):
    query = '''SELECT u.id,u.username,u.name,u.role,u.enabled,u.created_at,m.class_name,m.status
      FROM memberships m JOIN users u ON u.id=m.user_id WHERE m.class_id=? AND ''' + active_student_clause()
    args = [class_id]
    if student_id is not None:
        query += ' AND u.id=?'
        args.append(core.identifier(student_id))
    result = []
    for item in core.rows(conn, query + ' ORDER BY u.name,u.id', args):
        item['name'] = item['class_name'].strip() or item['name']
        result.append({**core.roster_user(item), 'status': item['status']})
    return result


def _wrong_books(conn, core, class_id, allowed, student_id=None):
    """One current-bank set powers roster counts, summaries and paged details."""
    _, bank = core.current_bank(conn)
    published = {question['id']: question for question in bank if question['subject_id'] in allowed}
    restriction, args = 'm.class_id=? AND ' + active_student_clause(), [class_id]
    if student_id is not None:
        restriction += ' AND u.id=?'
        args.append(core.identifier(student_id))
    members = core.rows(conn, '''SELECT u.id,g.subject_ids FROM memberships m
      JOIN users u ON u.id=m.user_id JOIN groups g ON g.id=u.subject_group_id AND g.enabled=1
      WHERE ''' + restriction, args)
    available = {}
    for member in members:
        try:
            assigned = json.loads(member['subject_ids'])
            if not isinstance(assigned, list) or any(not isinstance(sid, str) for sid in assigned):
                continue
        except (ValueError, TypeError):
            continue
        available[member['id']] = [sid for sid in allowed if sid in assigned]
    books = {user_id: [] for user_id in available}
    for mistake in core.rows(conn, '''SELECT w.user_id,w.question_id,w.error_count,w.last_error_at,w.correct_streak
      FROM wrong w JOIN memberships m ON m.user_id=w.user_id JOIN users u ON u.id=w.user_id
      WHERE w.active=1 AND ''' + restriction + ' ORDER BY ' + _utc_order('w.last_error_at') + ' DESC,w.question_id', args):
        question = published.get(mistake['question_id'])
        if question and question['subject_id'] in available.get(mistake['user_id'], []):
            books[mistake['user_id']].append({'question': question,
                **{key: mistake[key] for key in ('error_count', 'last_error_at', 'correct_streak')}})
    return available, books


def _wrong_summary(book, allowed, names, subject_id=None):
    counts = Counter(item['question']['subject_id'] for item in book)
    return {'scope': WRONG_BOOK_SCOPE,
            'total': counts[subject_id] if subject_id else len(book),
            'subjects': [{'subject_id': sid, 'name': names.get(sid, sid), 'total': counts[sid]} for sid in allowed]}


def _classwork(conn, core, class_id, teacher_id, student_id):
    base = ''' FROM teaching_recipients r JOIN teaching_assignments a ON a.id=r.assignment_id
      JOIN teaching_papers p ON p.id=a.paper_id LEFT JOIN teaching_attempts t
      ON t.assignment_id=r.assignment_id AND t.user_id=r.user_id
      WHERE r.user_id=? AND a.class_id=? AND p.teacher_id=?'''
    args = (student_id, class_id, teacher_id)
    counts = core.one(conn, 'SELECT COUNT(*) assigned,SUM(CASE WHEN t.submitted_at IS NOT NULL THEN 1 ELSE 0 END) submitted' + base, args)
    safe = "CASE WHEN json_valid(t.result) THEN t.result ELSE '{}' END"
    fields = ','.join(f"json_extract({safe},'$.{key}') {key}" for key in ('score', 'full_score', 'correct', 'total'))
    valid = ' AND '.join(f"json_type({safe},'$.{key}') IN ('integer','real')" for key in ('score', 'full_score', 'correct', 'total'))
    results = core.rows(conn, 'SELECT a.id assignment_id,p.title,a.class_name,t.submitted_at,' + fields + base +
                        f' AND t.submitted_at IS NOT NULL AND {valid} ORDER BY {_utc_order("t.submitted_at")} DESC,a.id DESC LIMIT 20', args)
    submitted = counts['submitted'] or 0
    return {'scope': 'lifetime_current_class_all_subjects', 'pending_includes_unavailable': True,
            'assigned': counts['assigned'], 'submitted': submitted, 'pending': counts['assigned'] - submitted, 'results': results}


def register_teacher_analytics(app, core):
    @app.get('/api/teaching/classes/{class_id}/students')
    def learning_students(class_id: str, actor=Depends(core.manager)):
        with core.db() as conn:
            conn.execute('BEGIN')
            classroom, allowed = _class_scope(conn, core, class_id, actor)
            students = _roster(conn, core, class_id)
            _, books = _wrong_books(conn, core, class_id, allowed)
            for student in students:
                student['current_wrong_count'] = len(books.get(student['id'], []))
            wrong_summary = {'wrong_questions': sum(student['current_wrong_count'] for student in students),
                             'students_with_wrong': sum(student['current_wrong_count'] > 0 for student in students),
                             'student_count': len(students)}
            conn.commit()
            core.audit(conn, actor['id'], 'teaching.students.view', class_id, '教师查看当前班级正式学生')
            return {'class': {'id': classroom['id'], 'name': classroom['name']}, 'students': students,
                    'wrong_summary': wrong_summary}

    @app.get('/api/teaching/classes/{class_id}/students/{student_id}/wrong-questions')
    def learning_wrong_questions(request: Request, class_id: str, student_id: str,
                                 subject_id: str | None = Query(None, max_length=128),
                                 page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=50),
                                 actor=Depends(core.manager)):
        subject_id = subject_id or None
        with core.db() as conn:
            conn.execute('BEGIN')
            classroom, allowed = _class_scope(conn, core, class_id, actor)
            matches = _roster(conn, core, class_id, student_id)
            if not matches:
                core.fail(404, '学生当前不在本班正式学习名单中')
            available, books = _wrong_books(conn, core, class_id, allowed, student_id)
            visible = available.get(student_id, [])
            if subject_id and subject_id not in visible:
                core.fail(403, '只能查看当前班级与学生专业共同允许科目的错题')
            names = {item['id']: item['name'] for item in core.rows(conn, 'SELECT id,name FROM subjects')}
            book = books.get(student_id, [])
            summary = _wrong_summary(book, visible, names, subject_id)
            filtered = [item for item in book if subject_id is None or item['question']['subject_id'] == subject_id]
            offset = (page - 1) * page_size
            items = [{**item, 'question': core.question_public(item['question'], item['question'].get('version', 0))}
                     for item in filtered[offset:offset + page_size]]
            core.require_media_capability(request, [item['question'] for item in items])
            conn.commit()
            core.audit(conn, actor['id'], 'teaching.student.wrong.view', student_id,
                       '教师查看当前在班学生错题；班级' + class_id)
            return {'class': {'id': classroom['id'], 'name': classroom['name']}, 'student': matches[0],
                    'available_subjects': [{'id': sid, 'name': names.get(sid, sid)} for sid in visible],
                    **summary, 'page': page, 'page_size': page_size,
                    'has_more': offset + len(items) < summary['total'], 'items': items}

    @app.get('/api/teaching/classes/{class_id}/students/{student_id}/analytics')
    def learning_analytics(class_id: str, student_id: str, days: int = Query(30),
                           subject_id: str | None = Query(None, max_length=128), actor=Depends(core.manager)):
        if days not in (7, 30, 90):
            core.fail(422, '统计周期仅支持7、30或90天')
        subject_id = subject_id or None
        today = core.now().astimezone(SHANGHAI).date()
        first = today - timedelta(days=days - 1)
        start = datetime.combine(first, datetime.min.time(), SHANGHAI).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
        end = datetime.combine(today + timedelta(days=1), datetime.min.time(), SHANGHAI).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
        period_where = ' WHERE answered_at>=? AND answered_at<?'
        with core.db() as conn:
            conn.execute('BEGIN')
            classroom, allowed = _class_scope(conn, core, class_id, actor)
            matches = _roster(conn, core, class_id, student_id)
            if not matches:
                core.fail(404, '学生当前不在本班正式学习名单中')
            if subject_id and subject_id not in allowed:
                core.fail(403, '只能查看当前班级科目范围内的学习汇总')
            names = {item['id']: item['name'] for item in core.rows(conn, 'SELECT id,name FROM subjects')}
            scoped, args = _practice_scope(student_id, subject_id)
            restriction = 'subject_id IN (' + ','.join('?' for _ in allowed) + ')' if allowed else '0'
            scoped += ', visible AS (SELECT * FROM scoped WHERE ' + restriction + ') '
            args += allowed
            lifetime = _metrics(core.one(conn, scoped + 'SELECT ' + METRICS_SQL + ' FROM visible', args))
            summary = _metrics(core.one(conn, scoped + 'SELECT ' + METRICS_SQL + ' FROM visible' + period_where, args + [start, end]))
            subjects = [_metrics(item) for item in core.rows(conn, scoped + 'SELECT subject_id,' + METRICS_SQL + ' FROM visible' + period_where + ' GROUP BY subject_id ORDER BY answered DESC,subject_id', args + [start, end])]
            for item in subjects:
                item['name'] = names.get(item['subject_id'], item['subject_id'])
            types = [_metrics(item) for item in core.rows(conn, scoped + 'SELECT type,' + METRICS_SQL + ' FROM visible' + period_where + ' GROUP BY type ORDER BY type', args + [start, end])]
            buckets = {item['date']: _metrics(item) for item in core.rows(conn, scoped + '''SELECT local_date date,
              COUNT(*) answered,SUM(CASE WHEN correct=1 THEN 1 ELSE 0 END) correct,
              COUNT(DISTINCT question_id) unique_questions,COALESCE(SUM(duration_seconds),0) study_seconds
              FROM visible''' + period_where + ' GROUP BY local_date ORDER BY local_date', args + [start, end])}
            daily = []
            for offset in range(days):
                date = (first + timedelta(days=offset)).isoformat()
                daily.append(buckets.get(date) or _metrics({'date': date, 'answered': 0, 'correct': 0, 'unique_questions': 0, 'study_seconds': 0}))
            classwork = _classwork(conn, core, class_id, actor['id'], student_id)
            available, books = _wrong_books(conn, core, class_id, allowed, student_id)
            wrong_book = _wrong_summary(books.get(student_id, []), available.get(student_id, []), names, subject_id)
            conn.commit()
            core.audit(conn, actor['id'], 'teaching.student.analytics.view', student_id, '教师查看在班学生学习汇总与错误分布；班级' + class_id)
            return {'class': {'id': classroom['id'], 'name': classroom['name']}, 'student': matches[0],
                    'scope': {'class_id': class_id, 'subject_ids': allowed, 'practice': 'current_class_subjects'},
                    'period': {'days': days, 'start': first.isoformat(), 'end': today.isoformat(), 'timezone': 'Asia/Shanghai'},
                    'filters': {'subject_id': subject_id}, 'available_subjects': [{'id': key, 'name': names.get(key, key)} for key in allowed],
                    'lifetime': lifetime, 'summary': summary, 'subjects': subjects, 'types': types, 'daily': daily,
                    'classwork': classwork, 'wrong_book': wrong_book}
