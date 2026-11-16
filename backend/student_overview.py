"""Class-first account pages and administrator aggregate learning overviews.

Reads project historical subject identifiers in SQLite. No record selections,
question text, answer keys, source images or private profile fields are returned.
"""
import csv
from datetime import date, datetime, timedelta, timezone
import io
import re
from urllib.parse import quote

from fastapi import Body, Depends, Query
from fastapi.responses import Response

from .student_analytics import SHANGHAI, _metrics, _utc_order

STATUSES = ('active', 'pending_confirmation', 'pending_approval')
FORMAL = "m.status='active' AND (m.visibility_accepted=1 OR (m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL))"
STUDENT_FIELDS = '''u.id,u.username,u.name,u.role,u.enabled,u.activated,u.must_change_password,
 u.subject_group_id,u.exam_year,u.grade,u.created_at,u.last_login_at,g.name subject_group_name'''
PRACTICE_FIELDS = ('answered', 'correct', 'wrong', 'accuracy', 'unique_questions',
                   'study_seconds', 'active_days', 'last_answered_at')
OVERVIEW_SORTS = {'name', 'username', 'answered', 'accuracy', 'study_seconds', 'active_days', 'last_answered_at'}
ACCOUNT_SORTS = {'name', 'username', 'created_at', 'last_login_at'}


def _like(value):
    return '%' + value.replace('\\', '\\\\').replace('%', '\\%').replace('_', '\\_') + '%'


def _page(total, requested, size):
    pages = max(1, (total + size - 1) // size)
    actual = min(requested, pages)
    return actual, pages, (actual - 1) * size


def _sort(core, key, order, allowed):
    if key not in allowed or order not in ('asc', 'desc'):
        core.fail(422, '排序字段或方向无效')
    collation = ' COLLATE NOCASE' if key in ('name', 'username') else ''
    return f'{key} IS NULL ASC,{key}{collation} {order.upper()},username COLLATE NOCASE ASC,id ASC'


def _period(core, first=None, last=None):
    today = core.now().astimezone(SHANGHAI).date()

    def parse(value):
        if not isinstance(value, str) or not re.fullmatch(r'\d{4}-\d{2}-\d{2}', value):
            core.fail(422, '日期须使用YYYY-MM-DD格式')
        try:
            return date.fromisoformat(value)
        except ValueError:
            core.fail(422, '日期无效')

    end = parse(last) if last else today
    try:
        start = parse(first) if first else end - timedelta(days=29)
    except OverflowError:
        core.fail(422, '日期超出支持范围')
    if end < start or (end - start).days >= 366:
        core.fail(422, '开始日期不能晚于结束日期，统计范围最多366天')
    try:
        following = end + timedelta(days=1)
    except OverflowError:
        core.fail(422, '结束日期超出支持范围')
    try:
        utc_start = datetime.combine(start, datetime.min.time(), SHANGHAI).astimezone(timezone.utc).isoformat(timespec='seconds')[:19]
        utc_end = datetime.combine(following, datetime.min.time(), SHANGHAI).astimezone(timezone.utc).isoformat(timespec='seconds')[:19]
    except OverflowError:
        core.fail(422, '日期超出支持范围')
    return {'date_from': start.isoformat(), 'date_to': end.isoformat(), 'timezone': 'Asia/Shanghai'}, utc_start, utc_end


def _ids(core, value):
    if value is None or value == '':
        return None
    if isinstance(value, str):
        value = value.split(',')
    if (not isinstance(value, list) or not 1 <= len(value) <= 500
            or any(not isinstance(v, str) for v in value) or len(set(value)) != len(value)):
        core.fail(422, '请选择1至500名不同学生')
    return [core.identifier(v) for v in value]


def _unassigned_where():
    return '''NOT EXISTS(SELECT 1 FROM memberships mx JOIN classes cx ON cx.id=mx.class_id
     WHERE mx.user_id=u.id AND mx.status IN ('active','pending_confirmation','pending_approval')
     AND cx.deleted_at IS NULL AND cx.archived=0)'''


def _roster_counts(conn, core, class_id):
    if class_id == 'unassigned':
        count = core.one(conn, "SELECT COUNT(*) n FROM users u WHERE u.role='student' AND u.deleted_at IS NULL AND " + _unassigned_where())['n']
        return {'student_count': count, 'formal_student_count': count, 'pending_student_count': 0}
    row = core.one(conn, f'''SELECT COUNT(u.id) student_count,
      COALESCE(SUM(CASE WHEN u.id IS NOT NULL AND {FORMAL} THEN 1 ELSE 0 END),0) formal_student_count
      FROM memberships m JOIN users u ON u.id=m.user_id AND u.role='student' AND u.deleted_at IS NULL
      WHERE m.class_id=? AND m.status IN ('active','pending_confirmation','pending_approval')''', (class_id,))
    return {**row, 'pending_student_count': row['student_count'] - row['formal_student_count']}


def _classroom(conn, core, class_id, actor):
    if class_id == 'unassigned':
        if actor['role'] != 'admin':
            core.fail(403, '仅管理员可查看未分班学生')
        return {'id': 'unassigned', 'name': '未分班学生', 'archived': False,
                'teacher_name': None, 'subject_group_name': None,
                **_roster_counts(conn, core, class_id)}
    value = core.class_scope(conn, class_id, actor)
    if actor['role'] == 'teacher' and value['archived']:
        core.fail(403, '教师只能查看本人当前班级的学生账号')
    extra = core.one(conn, '''SELECT t.name teacher_name,g.name subject_group_name FROM classes c
      JOIN users t ON t.id=c.teacher_id LEFT JOIN groups g ON g.id=c.subject_group_id WHERE c.id=?''', (class_id,))
    return {key: value[key] for key in ('id', 'name', 'term')} | {
        'archived': bool(value['archived']), **extra, **_roster_counts(conn, core, class_id)}


def _cohort(conn, core, class_id, actor, formal=False):
    classroom = _classroom(conn, core, class_id, actor)
    if class_id == 'unassigned':
        query = f'''SELECT {STUDENT_FIELDS},'' class_name,'unassigned' membership_status,1 visibility_confirmed
          FROM users u LEFT JOIN groups g ON g.id=u.subject_group_id
          WHERE u.role='student' AND u.deleted_at IS NULL AND {_unassigned_where()}'''
        return classroom, query, []
    query = f'''SELECT {STUDENT_FIELDS},m.class_name,m.status membership_status,
      CASE WHEN m.visibility_accepted=1 OR (m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL) THEN 1 ELSE 0 END visibility_confirmed
      FROM memberships m JOIN users u ON u.id=m.user_id LEFT JOIN groups g ON g.id=u.subject_group_id
      WHERE m.class_id=? AND u.role='student' AND u.deleted_at IS NULL AND '''
    query += FORMAL if formal else "m.status IN ('active','pending_confirmation','pending_approval')"
    return classroom, query, [class_id]


def _filter_cohort(core, query, args, q='', enabled=None, student_ids=None):
    if not isinstance(q, str) or len(q) > 100:
        core.fail(422, '姓名或账号搜索最多100字')
    if enabled is not None and not isinstance(enabled, bool):
        core.fail(422, '账号状态须为布尔值')
    if q:
        query += " AND (u.name LIKE ? ESCAPE '\\' OR u.username LIKE ? ESCAPE '\\')"
        args += [_like(q), _like(q)]
    if enabled is not None:
        query += ' AND u.enabled=?'
        args.append(int(enabled))
    if student_ids:
        query += ' AND u.id IN (' + ','.join('?' for _ in student_ids) + ')'
        args += student_ids
    return query, args


def _account(item, actor):
    # Keep the account summary deliberately smaller than public_user/profile.
    keys = ('id', 'username', 'name', 'role', 'enabled', 'created_at', 'class_name',
            'membership_status', 'visibility_confirmed')
    if actor['role'] == 'admin':
        keys += ('activated', 'must_change_password', 'subject_group_id', 'subject_group_name',
                 'exam_year', 'grade', 'last_login_at')
    value = {key: item[key] for key in keys}
    for key in ('enabled', 'activated', 'must_change_password', 'visibility_confirmed'):
        if key in value:
            value[key] = bool(value[key])
    return value


def _learning_sql(cohort, cohort_args, start, end, subject_id):
    safe = "CASE WHEN json_valid(r.question_snapshot) THEN r.question_snapshot ELSE '{}' END"
    subject = f"json_extract({safe},'$.subject_id')"
    sql = f'''WITH cohort AS ({cohort}),historical AS (
      SELECT r.user_id,r.question_id,r.correct,r.duration_seconds,r.answered_at,
       {_utc_order('r.answered_at')} answered_order,
       date(substr(r.answered_at,1,19),'+8 hours') local_date,
       CASE WHEN json_type({safe},'$.subject_id')='text' AND length(trim({subject}))>0
            THEN {subject} ELSE q.subject_id END subject_id
      FROM cohort c JOIN records r ON r.user_id=c.id LEFT JOIN questions q ON q.id=r.question_id
      WHERE r.answered_at>=? AND r.answered_at<?
    ),scoped AS (SELECT * FROM historical'''
    args = [*cohort_args, start, end]
    if subject_id:
        sql += ' WHERE subject_id=?'
        args.append(subject_id)
    sql += '''),aggregated AS (
      SELECT user_id,COUNT(*) answered,COALESCE(SUM(correct),0) correct,
       COUNT(DISTINCT question_id) unique_questions,COALESCE(SUM(duration_seconds),0) study_seconds,
       COUNT(DISTINCT local_date) active_days,MAX(answered_order) last_answered_at
      FROM scoped GROUP BY user_id
    ),learning AS (
      SELECT c.*,COALESCE(a.answered,0) answered,COALESCE(a.correct,0) correct,
       COALESCE(a.answered,0)-COALESCE(a.correct,0) wrong,
       CASE WHEN a.answered>0 THEN round(a.correct*100.0/a.answered,1) ELSE NULL END accuracy,
       COALESCE(a.unique_questions,0) unique_questions,COALESCE(a.study_seconds,0) study_seconds,
       COALESCE(a.active_days,0) active_days,a.last_answered_at
      FROM cohort c LEFT JOIN aggregated a ON a.user_id=c.id
    ) '''
    return sql, args


def _overview(conn, core, actor, class_id, q='', subject_id=None, date_from=None,
              date_to=None, enabled=None, student_ids=None, sort_by='answered', order='desc',
              page=1, page_size=20, export=False):
    period, start, end = _period(core, date_from, date_to)
    subject_id = core.identifier(subject_id) if subject_id else None
    selected = _ids(core, student_ids)
    ordering = _sort(core, sort_by, order, OVERVIEW_SORTS)
    classroom, cohort, args = _cohort(conn, core, class_id, actor, formal=True)
    cohort, args = _filter_cohort(core, cohort, args, q, enabled, selected)
    if selected:
        allowed = {item['id'] for item in core.rows(conn, 'SELECT id FROM (' + cohort + ')', args)}
        if allowed != set(selected):
            core.fail(409, '所选学生已不符合当前班级或筛选条件，请刷新后重新选择')
    sql, values = _learning_sql(cohort, args, start, end, subject_id)
    available = {s['id']: s['name'] for s in core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid')}
    # DISTINCT + ORDER BY on this JSON-derived expression makes SQLite retain
    # the full image-bearing snapshot in each sorter record. Deduplicate only
    # the projected ID here, then sort the small metadata result in Python.
    historical_subjects = core.rows(conn, sql + 'SELECT DISTINCT subject_id FROM historical WHERE subject_id IS NOT NULL', values)
    for row in sorted(historical_subjects, key=lambda item: item['subject_id']):
        available.setdefault(row['subject_id'], row['subject_id'])
    if subject_id and subject_id not in available:
        core.fail(404, '科目不存在于当前目录或所选历史记录中')
    summary = core.one(conn, sql + '''SELECT COUNT(*) student_count,
      COALESCE(SUM(answered>0),0) active_students,COALESCE(SUM(answered),0) answered,
      COALESCE(SUM(correct),0) correct,COALESCE(SUM(study_seconds),0) study_seconds,
      COALESCE(SUM(unique_questions),0) student_question_pairs FROM learning''', values)
    summary['wrong'] = summary['answered'] - summary['correct']
    summary['accuracy'] = round(summary['correct'] * 100 / summary['answered'], 1) if summary['answered'] else None
    summary['eligible_roster_count'] = classroom['formal_student_count']
    summary['pending_student_count'] = classroom['pending_student_count']
    total = summary['student_count']
    actual, pages, offset = _page(total, page, page_size)
    if export:
        if total > 5000:
            core.fail(422, '筛选结果超过5000名学生，请缩小范围后导出，不会截断数据')
        selected_rows = core.rows(conn, sql + 'SELECT * FROM learning ORDER BY ' + ordering, values)
    else:
        selected_rows = core.rows(conn, sql + 'SELECT * FROM learning ORDER BY ' + ordering + ' LIMIT ? OFFSET ?', values + [page_size, offset])
    items = []
    for row in selected_rows:
        account = _account(row, actor)
        account['practice'] = _metrics({key: row[key] for key in PRACTICE_FIELDS})
        items.append(account)
    return {'classroom': classroom, 'period': period,
            'filters': {'q': q, 'subject_id': subject_id, 'enabled': enabled, 'student_ids': selected},
            'available_subjects': [{'id': key, 'name': name} for key, name in available.items()],
            'summary': summary, 'items': items, 'total': total, 'page': actual,
            'page_size': page_size, 'pages': pages,
            'scope': 'current_class_formal_students_historical_practice'}


def _csv_text(value):
    text = '' if value is None else str(value)
    # Excel interprets a formula even after leading tabs, spaces or line breaks.
    if text.lstrip().startswith(('=', '+', '-', '@')) or text.startswith(('\t', '\r', '\n')):
        return "'" + text
    return text


def register_student_overview(app, core):
    core.SCHEMA += '''
    CREATE INDEX IF NOT EXISTS memberships_class_status_user ON memberships(class_id,status,user_id);
    CREATE INDEX IF NOT EXISTS memberships_user_status_class ON memberships(user_id,status,class_id);
    CREATE INDEX IF NOT EXISTS users_role_deleted_name ON users(role,deleted_at,name,id);
    '''

    @app.get('/api/management/student-classes')
    def student_classes(q: str = Query('', max_length=100), class_status: str = 'active',
                        page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100),
                        actor=Depends(core.manager)):
        if class_status not in ('active', 'archived', 'all'):
            core.fail(422, '班级状态无效')
        if actor['role'] == 'teacher' and class_status != 'active':
            core.fail(403, '教师只能查看本人当前班级')
        with core.db() as conn:
            conn.execute('BEGIN')
            where, args = ['c.deleted_at IS NULL'], []
            if class_status != 'all':
                where.append('c.archived=?')
                args.append(int(class_status == 'archived'))
            if actor['role'] == 'teacher':
                where.append('c.teacher_id=?')
                args.append(actor['id'])
            if q:
                where.append("(c.name LIKE ? ESCAPE '\\' OR c.term LIKE ? ESCAPE '\\' OR t.name LIKE ? ESCAPE '\\' OR g.name LIKE ? ESCAPE '\\')")
                args.extend([_like(q)] * 4)
            prefix = f'''WITH directory AS (SELECT c.id,c.name,c.term,c.archived,t.name teacher_name,g.name subject_group_name,
              COUNT(u.id) student_count,COALESCE(SUM(CASE WHEN u.id IS NOT NULL AND {FORMAL} THEN 1 ELSE 0 END),0) formal_student_count
              FROM classes c JOIN users t ON t.id=c.teacher_id LEFT JOIN groups g ON g.id=c.subject_group_id
              LEFT JOIN memberships m ON m.class_id=c.id AND m.status IN ('active','pending_confirmation','pending_approval')
              LEFT JOIN users u ON u.id=m.user_id AND u.role='student' AND u.deleted_at IS NULL
              WHERE {' AND '.join(where)} GROUP BY c.id) '''
            total = core.one(conn, prefix + 'SELECT COUNT(*) n FROM directory', args)['n']
            actual, pages, offset = _page(total, page, page_size)
            items = core.rows(conn, prefix + 'SELECT * FROM directory ORDER BY archived,name COLLATE NOCASE,id LIMIT ? OFFSET ?', args + [page_size, offset])
            for item in items:
                item['archived'] = bool(item['archived'])
                item['pending_student_count'] = item['student_count'] - item['formal_student_count']
            unassigned = _classroom(conn, core, 'unassigned', actor) if actor['role'] == 'admin' else None
            conn.commit()
            core.audit(conn, actor['id'], 'students.classes.list', '', f'{len(items)} classes; {class_status}')
            return {'items': items, 'unassigned': unassigned, 'total': total, 'page': actual, 'page_size': page_size, 'pages': pages}

    @app.get('/api/management/students/page')
    def student_accounts(class_id: str = Query(..., min_length=1, max_length=128),
                         q: str = Query('', max_length=100), enabled: bool | None = None,
                         membership_status: str = 'all', sort_by: str = 'name', order: str = 'asc',
                         page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100),
                         actor=Depends(core.manager)):
        ordering = _sort(core, sort_by, order, ACCOUNT_SORTS)
        if actor['role'] != 'admin' and sort_by == 'last_login_at':
            core.fail(403, '教师仅可按姓名、账号或开通时间排序')
        if membership_status not in ('all', 'active', 'pending'):
            core.fail(422, '成员状态无效')
        with core.db() as conn:
            conn.execute('BEGIN')
            classroom, cohort, args = _cohort(conn, core, class_id, actor)
            cohort, args = _filter_cohort(core, cohort, args, q, enabled)
            if class_id != 'unassigned':
                if membership_status == 'active':
                    cohort += ' AND (' + FORMAL + ')'
                elif membership_status == 'pending':
                    cohort += ' AND NOT (' + FORMAL + ')'
            elif membership_status == 'pending':
                cohort += ' AND 0=1'
            prefix = 'WITH cohort AS (' + cohort + ') '
            total = core.one(conn, prefix + 'SELECT COUNT(*) n FROM cohort', args)['n']
            actual, pages, offset = _page(total, page, page_size)
            records = core.rows(conn, prefix + 'SELECT * FROM cohort ORDER BY ' + ordering + ' LIMIT ? OFFSET ?', args + [page_size, offset])
            items = [_account(item, actor) for item in records]
            conn.commit()
            core.audit(conn, actor['id'], 'students.accounts.page', class_id, f'{len(items)} of {total} accounts')
            return {'classroom': classroom, 'items': items, 'total': total, 'page': actual, 'page_size': page_size, 'pages': pages}

    @app.get('/api/management/students/overview')
    def student_overview(class_id: str = Query(..., min_length=1, max_length=128),
                         q: str = Query('', max_length=100), subject_id: str | None = Query(None, max_length=128),
                         date_from: str | None = Query(None, max_length=10), date_to: str | None = Query(None, max_length=10),
                         enabled: bool | None = None, student_ids: str | None = Query(None, max_length=65536),
                         sort_by: str = 'answered', order: str = 'desc',
                         page: int = Query(1, ge=1), page_size: int = Query(20, ge=1, le=100),
                         actor=Depends(core.admin)):
        with core.db() as conn:
            conn.execute('BEGIN')
            result = _overview(conn, core, actor, class_id, q, subject_id, date_from, date_to,
                               enabled, student_ids, sort_by, order, page, page_size)
            conn.commit()
            core.audit(conn, actor['id'], 'students.learning.overview', class_id,
                       core.canonical({'from': result['period']['date_from'], 'to': result['period']['date_to'],
                                       'subject_id': subject_id, 'rows': len(result['items']), 'total': result['total']}))
            return result

    @app.post('/api/management/students/overview/export')
    def export_student_overview(data: dict = Body(...), actor=Depends(core.admin)):
        supported = {'class_id', 'q', 'subject_id', 'date_from', 'date_to', 'enabled', 'student_ids', 'sort_by', 'order'}
        if set(data) - supported or not isinstance(data.get('class_id'), str) or not 1 <= len(data['class_id']) <= 128:
            core.fail(422, '导出筛选字段无效，请先选择班级')
        if any(data.get(k) is not None and not isinstance(data[k], str) for k in ('subject_id', 'date_from', 'date_to', 'sort_by', 'order')):
            core.fail(422, '导出筛选字段格式无效')
        if data.get('student_ids') is not None and not isinstance(data['student_ids'], list):
            core.fail(422, '批量导出学生须使用学生编号列表')
        with core.db() as conn:
            conn.execute('BEGIN')
            result = _overview(conn, core, actor, **data, export=True)
            conn.commit()
            core.audit(conn, actor['id'], 'students.learning.export', data['class_id'],
                       core.canonical({'from': result['period']['date_from'], 'to': result['period']['date_to'],
                                       'subject_id': result['filters']['subject_id'], 'rows': len(result['items'])}))
        output = io.StringIO(newline='')
        writer = csv.writer(output, lineterminator='\r\n')
        writer.writerow(['班级', '姓名', '账号', '班内姓名', '专业', '账号状态', '开始日期', '结束日期', '科目',
                         '答题次数', '答对次数', '答错次数', '正确率(%)', '不同题目数', '学习秒数', '活跃天数', '最近作答(UTC)'])
        subject = next((s['name'] for s in result['available_subjects'] if s['id'] == result['filters']['subject_id']), '全部科目')
        for item in result['items']:
            p = item['practice']
            writer.writerow([_csv_text(value) for value in (
                result['classroom']['name'], item['name'], item['username'], item['class_name'], item['subject_group_name'],
                '启用' if item['enabled'] else '停用', result['period']['date_from'], result['period']['date_to'], subject,
                p['answered'], p['correct'], p['wrong'], p['accuracy'], p['unique_questions'], p['study_seconds'],
                p['active_days'], p['last_answered_at'])])
        return Response('\ufeff' + output.getvalue(), media_type='text/csv; charset=utf-8', headers={
            'Content-Disposition': "attachment; filename=student-learning-summary.csv; filename*=UTF-8''" + quote('学生学习汇总.csv'),
            'Cache-Control': 'no-store', 'X-Export-Count': str(len(result['items']))})
