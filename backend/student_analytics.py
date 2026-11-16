"""Administrator student profiles and aggregate-only practice analytics."""
from datetime import datetime, timedelta, timezone

from fastapi import Depends, Query


SHANGHAI = timezone(timedelta(hours=8), 'Asia/Shanghai')
METRICS_SQL = '''COUNT(*) answered,
 SUM(CASE WHEN correct=1 THEN 1 ELSE 0 END) correct,
 COUNT(DISTINCT question_id) unique_questions,
 COALESCE(SUM(duration_seconds),0) study_seconds,
 COUNT(DISTINCT local_date) active_days,
 MAX(answered_order) last_answered_at'''


def _utc_order(column):
    """Stored uploads are UTC ISO; pad fractions so whole seconds sort first."""
    fraction = f"replace(replace(substr({column},21),'Z',''),'+00:00','')"
    return f"substr({column},1,19)||'.'||CASE WHEN substr({column},20,1)='.' THEN substr({fraction}||'000000',1,6) ELSE '000000' END||'Z'"


def _metrics(row):
    value = dict(row)
    answered = int(value.get('answered') or 0)
    correct = int(value.get('correct') or 0)
    value.update(answered=answered, correct=correct, wrong=answered - correct,
                 unique_questions=int(value.get('unique_questions') or 0),
                 study_seconds=int(value.get('study_seconds') or 0),
                 accuracy=round(correct * 100 / answered, 1) if answered else None)
    if 'active_days' in value:
        value['active_days'] = int(value['active_days'] or 0)
    if value.get('last_answered_at'):
        value['last_answered_at'] = value['last_answered_at'].replace('.000000Z', 'Z')
    return value


def _student(conn, core, user_id):
    target = core.one(conn, 'SELECT * FROM users WHERE id=? AND deleted_at IS NULL', (core.identifier(user_id),))
    if not target:
        core.fail(404, '学生账号不存在或已移除')
    if target['role'] != 'student':
        core.fail(422, '该功能仅查看学生账号')
    return target


def _practice_scope(user_id, subject_id):
    # JSON is projected in SQLite, never returned as a media-bearing snapshot.
    safe = "CASE WHEN json_valid(r.question_snapshot) THEN r.question_snapshot ELSE '{}' END"
    subject = f"json_extract({safe},'$.subject_id')"
    kind = f"json_extract({safe},'$.type')"
    # Keep only the narrow projection across this optimization boundary.
    # Otherwise GROUP BY subject/type can carry the original image-heavy JSON
    # into sorter records for deferred evaluation, filling the bounded /tmp.
    query = f'''WITH historical AS MATERIALIZED (
      SELECT r.question_id,r.correct,r.duration_seconds,r.answered_at,
       {_utc_order('r.answered_at')} answered_order,
       date(substr(r.answered_at,1,19),'+8 hours') local_date,
       CASE WHEN json_type({safe},'$.subject_id')='text' AND length(trim({subject}))>0
            THEN {subject} ELSE q.subject_id END subject_id,
       CASE WHEN {kind} IN ('single','multiple','judge','fill')
            THEN {kind} ELSE COALESCE(q.type,'unknown') END type
      FROM records r LEFT JOIN questions q ON q.id=r.question_id WHERE r.user_id=?
    ), scoped AS (SELECT * FROM historical'''
    values = [user_id]
    if subject_id:
        query += ' WHERE subject_id=?'
        values.append(subject_id)
    return query + ') ', values


def _classwork(conn, core, user_id):
    counts = core.one(conn, '''SELECT COUNT(*) assigned,
      SUM(CASE WHEN t.submitted_at IS NOT NULL THEN 1 ELSE 0 END) submitted
      FROM teaching_recipients r LEFT JOIN teaching_attempts t
      ON t.assignment_id=r.assignment_id AND t.user_id=r.user_id WHERE r.user_id=?''', (user_id,))
    safe = "CASE WHEN json_valid(t.result) THEN t.result ELSE '{}' END"
    fields = ','.join(f"json_extract({safe},'$.{key}') {key}" for key in ('score', 'full_score', 'correct', 'total'))
    valid = ' AND '.join(f"json_type({safe},'$.{key}') IN ('integer','real')" for key in ('score', 'full_score', 'correct', 'total'))
    results = core.rows(conn, f'''SELECT a.id assignment_id,p.title,a.class_name,t.submitted_at,{fields}
      FROM teaching_recipients r JOIN teaching_assignments a ON a.id=r.assignment_id
      JOIN teaching_papers p ON p.id=a.paper_id
      JOIN teaching_attempts t ON t.assignment_id=r.assignment_id AND t.user_id=r.user_id
      WHERE r.user_id=? AND t.submitted_at IS NOT NULL AND {valid}
      ORDER BY {_utc_order('t.submitted_at')} DESC,a.id DESC LIMIT 20''', (user_id,))
    assigned, submitted = counts['assigned'], counts['submitted'] or 0
    return {'scope': 'lifetime_all_subjects', 'pending_includes_unavailable': True,
            'assigned': assigned, 'submitted': submitted, 'pending': assigned - submitted, 'results': results}


def register_student_analytics(app, core):
    @app.get('/api/management/users/{user_id}/profile')
    def student_profile(user_id: str, actor=Depends(core.admin)):
        with core.db() as conn:
            conn.execute('BEGIN')
            target = _student(conn, core, user_id)
            group = core.one(conn, 'SELECT name FROM groups WHERE id=?', (target['subject_group_id'],))
            user = {**core.public_user(target), 'subject_group_name': group['name'] if group else None}
            classes = core.rows(conn, '''SELECT c.id,c.name,c.teacher_id,t.name teacher_name,m.status,
              c.archived,c.term,c.deleted_at,m.class_name,m.created_at joined_at,
              m.visibility_accepted,m.admin_enrolled_by,m.admin_enrolled_at
              FROM memberships m JOIN classes c ON c.id=m.class_id JOIN users t ON t.id=c.teacher_id
              WHERE m.user_id=? ORDER BY m.created_at DESC,c.id DESC''', (user_id,))
            for item in classes:
                item['archived'] = bool(item['archived'])
                item['visibility_accepted'] = bool(item['visibility_accepted'])
                enrolled_by, enrolled_at = item.pop('admin_enrolled_by'), item.pop('admin_enrolled_at')
                item['admin_enrolled'] = bool(enrolled_by and enrolled_at)
            conn.commit()
            core.audit(conn, actor['id'], 'user.profile.view', user_id, '账号管理查看基础资料')
            return {'user': user, 'classes': classes}

    @app.get('/api/management/users/{user_id}/analytics')
    def student_analytics(user_id: str, days: int = Query(30),
                          subject_id: str | None = Query(None, max_length=128), actor=Depends(core.admin)):
        if days not in (7, 30, 90):
            core.fail(422, '统计周期仅支持7、30或90天')
        subject_id = subject_id or None
        now = core.now().astimezone(SHANGHAI)
        first = now.date() - timedelta(days=days - 1)
        # Uploads normalize answered_at to UTC ISO. Second-only UTC prefixes
        # compare exactly with both whole-second and fractional ISO values;
        # SQLite date/julianday otherwise rounds .999999 across midnight.
        start = datetime.combine(first, datetime.min.time(), SHANGHAI).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
        end = datetime.combine(now.date() + timedelta(days=1), datetime.min.time(), SHANGHAI).astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S')
        period_where = ' WHERE answered_at>=? AND answered_at<?'
        with core.db() as conn:
            conn.execute('BEGIN')
            _student(conn, core, user_id)
            all_scoped, all_args = _practice_scope(user_id, None)
            available = {item['id']: item['name'] for item in core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid')}
            # Sort the extracted IDs after DISTINCT so SQLite never spools
            # image-bearing snapshot payloads for this metadata directory.
            historical_subjects = core.rows(conn, all_scoped + 'SELECT DISTINCT subject_id FROM scoped WHERE subject_id IS NOT NULL', all_args)
            for item in sorted(historical_subjects, key=lambda row: row['subject_id']):
                available.setdefault(item['subject_id'], item['subject_id'])
            if subject_id and core.identifier(subject_id) not in available:
                core.fail(404, '科目不存在')
            scoped, args = _practice_scope(user_id, subject_id)
            lifetime = _metrics(core.one(conn, scoped + 'SELECT ' + METRICS_SQL + ' FROM scoped', args))
            summary = _metrics(core.one(conn, scoped + 'SELECT ' + METRICS_SQL + ' FROM scoped' + period_where, args + [start, end]))
            subjects = [_metrics(item) for item in core.rows(conn, scoped + '''SELECT subject_id,
              COALESCE((SELECT name FROM subjects s WHERE s.id=scoped.subject_id),subject_id,'未知科目') name,
              ''' + METRICS_SQL + ' FROM scoped' + period_where + ' GROUP BY subject_id ORDER BY answered DESC,subject_id', args + [start, end])]
            types = [_metrics(item) for item in core.rows(conn, scoped + 'SELECT type,' + METRICS_SQL + ' FROM scoped' + period_where + ' GROUP BY type ORDER BY type', args + [start, end])]
            buckets = {item['date']: _metrics(item) for item in core.rows(conn, scoped + '''SELECT local_date date,
              COUNT(*) answered,SUM(CASE WHEN correct=1 THEN 1 ELSE 0 END) correct,
              COUNT(DISTINCT question_id) unique_questions,COALESCE(SUM(duration_seconds),0) study_seconds
              FROM scoped''' + period_where + ' GROUP BY local_date ORDER BY local_date', args + [start, end])}
            daily = []
            for offset in range(days):
                date = (first + timedelta(days=offset)).isoformat()
                daily.append(buckets.get(date) or _metrics({'date': date, 'answered': 0, 'correct': 0, 'unique_questions': 0, 'study_seconds': 0}))
            classwork = _classwork(conn, core, user_id)
            conn.commit()
            core.audit(conn, actor['id'], 'user.analytics.view', user_id, '账号管理查看学习分析')
            return {'period': {'days': days, 'start': first.isoformat(), 'end': now.date().isoformat(), 'timezone': 'Asia/Shanghai'},
                    'filters': {'subject_id': subject_id}, 'available_subjects': [{'id': key, 'name': name} for key, name in available.items()],
                    'lifetime': lifetime, 'summary': summary,
                    'subjects': subjects, 'types': types, 'daily': daily, 'classwork': classwork}
