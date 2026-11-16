"""Immutable published-bank papers and scoped, server-graded class practice."""
import copy
import hashlib
import json
import re
import secrets
import uuid

from fastapi import Body, Depends, Query, Request

from .question_types import grade_question
from .teacher_analytics import active_student_clause, _roster

QUESTION_TYPES = ('single', 'multiple', 'fill', 'judge')
OPTION_REFERENCE_PATTERN = r'(?:[A-JＡ-Ｊ]\s*(?:[、,，和及与或/／&]|\band\b|\bor\b)\s*[A-JＡ-Ｊ]|(?:选项|答案|选择|option|answer)\s*[:：]?\s*[A-JＡ-Ｊ]|[A-JＡ-Ｊ]\s*(?:项|选项)|以上|上述|上面|前述|前面|后面|均不|都不|全不|全都|都对|都正确|全部正确|全部错误|all\s+of|none\s+of|both\s+[A-J]|neither|above|below|former|latter)'
OPTION_REFERENCE = re.compile(OPTION_REFERENCE_PATTERN, re.IGNORECASE)

SCHEMA = '''
CREATE TABLE IF NOT EXISTS teaching_papers(
 id TEXT PRIMARY KEY,teacher_id TEXT NOT NULL REFERENCES users(id),title TEXT NOT NULL,
 rules TEXT NOT NULL,questions TEXT NOT NULL,shuffle_questions INTEGER NOT NULL,
 shuffle_options INTEGER NOT NULL,created_at TEXT NOT NULL);
CREATE INDEX IF NOT EXISTS teaching_papers_owner ON teaching_papers(teacher_id,created_at);
CREATE TABLE IF NOT EXISTS teaching_assignments(
 id TEXT PRIMARY KEY,paper_id TEXT NOT NULL REFERENCES teaching_papers(id),
 class_id TEXT NOT NULL REFERENCES classes(id),class_name TEXT NOT NULL,created_at TEXT NOT NULL,
 UNIQUE(paper_id,class_id));
CREATE TABLE IF NOT EXISTS teaching_recipients(
 assignment_id TEXT NOT NULL REFERENCES teaching_assignments(id),user_id TEXT NOT NULL REFERENCES users(id),
 PRIMARY KEY(assignment_id,user_id));
CREATE INDEX IF NOT EXISTS teaching_recipients_user ON teaching_recipients(user_id,assignment_id);
CREATE TABLE IF NOT EXISTS teaching_attempts(
 assignment_id TEXT NOT NULL,user_id TEXT NOT NULL,questions TEXT NOT NULL,created_at TEXT NOT NULL,
 client_uuid TEXT,payload_hash TEXT,result TEXT,submitted_at TEXT,
 PRIMARY KEY(assignment_id,user_id),
 FOREIGN KEY(assignment_id,user_id) REFERENCES teaching_recipients(assignment_id,user_id));
'''


def shuffled_questions(questions, shuffle_questions, shuffle_options):
    """Keep canonical keys/answers; only display_key follows the randomized order."""
    result = copy.deepcopy(questions)
    random = secrets.SystemRandom()
    if shuffle_questions:
        random.shuffle(result)
    for question in result:
        options = question['options']
        safe = question['type'] in ('single', 'multiple') and not question.get('media') and not any(
            OPTION_REFERENCE.search(text) for text in [question['stem'], *(option['text'] for option in options)]
        )
        if shuffle_options and safe:
            random.shuffle(options)
        question['options_shuffled'] = bool(shuffle_options and safe and any(option['key'] != chr(65 + index) for index, option in enumerate(options)))
        question['options'] = [{**option, 'display_key': chr(65 + index)} for index, option in enumerate(options)]
        question['blank_count'] = len(question['answer']) if question['type'] == 'fill' else 0
    return result


def register_teaching(app, core):
    core.SCHEMA += SCHEMA

    def strict(data, allowed):
        if set(data) - set(allowed):
            core.fail(422, '包含不支持的字段；学生和教师不能提交自定义题库内容')

    def owner(conn, paper_id, actor):
        core.identifier(paper_id)
        paper = core.one(conn, 'SELECT * FROM teaching_papers WHERE id=?', (paper_id,))
        if not paper:
            core.fail(404, '练习卷不存在')
        if paper['teacher_id'] != actor['id']:
            core.fail(403, '只能操作本人创建的练习卷')
        return paper

    def paper_summary(paper, detail=False):
        questions = json.loads(paper['questions'])
        value = {key: paper[key] for key in ('id', 'title', 'created_at')}
        value.update(question_count=len(questions), full_score=sum(question['score'] for question in questions),
                     shuffle_questions=bool(paper['shuffle_questions']), shuffle_options=bool(paper['shuffle_options']), rules=json.loads(paper['rules']))
        if detail:
            value['questions'] = questions
        return value

    def catalog_classes(conn, actor):
        query = 'SELECT c.*,g.subject_ids FROM classes c JOIN groups g ON g.id=c.subject_group_id WHERE c.archived=0 AND c.deleted_at IS NULL AND g.enabled=1'
        args = ()
        if actor['role'] == 'teacher':
            query += ' AND c.teacher_id=?'
            args = (actor['id'],)
        return [{**item, 'subject_ids': json.loads(item['subject_ids'])} for item in core.rows(conn, query, args)]

    def catalog_subjects(conn, actor):
        if actor['role'] == 'admin':
            return {item['id'] for item in core.rows(conn, 'SELECT id FROM subjects')}
        return {subject for item in catalog_classes(conn, actor) for subject in item['subject_ids']}

    def assignment(conn, assignment_id):
        core.identifier(assignment_id)
        item = core.one(conn, '''SELECT a.*,p.teacher_id,p.title paper_title,p.rules,p.questions,p.shuffle_questions,p.shuffle_options
          FROM teaching_assignments a JOIN teaching_papers p ON p.id=a.paper_id WHERE a.id=?''', (assignment_id,))
        if not item:
            core.fail(404, '班级练习不存在')
        return item

    def assignment_summary(conn, item, actor=None):
        questions = json.loads(item['questions'])
        teacher_filter = ''
        args = [item['id']]
        if actor and actor['role'] == 'teacher':
            teacher_filter = ''' AND EXISTS(SELECT 1 FROM memberships m JOIN users u ON u.id=m.user_id
              JOIN classes current_class ON current_class.id=m.class_id
              WHERE m.class_id=? AND m.user_id=r.user_id AND current_class.archived=0
              AND current_class.deleted_at IS NULL AND ''' + active_student_clause() + ')'
            args.append(item['class_id'])
        counts = core.one(conn, '''SELECT COUNT(*) recipient_count,
          SUM(CASE WHEN t.submitted_at IS NOT NULL THEN 1 ELSE 0 END) submitted_count
          FROM teaching_recipients r LEFT JOIN teaching_attempts t
          ON t.assignment_id=r.assignment_id AND t.user_id=r.user_id WHERE r.assignment_id=?''' + teacher_filter, args)
        return {**{key: item[key] for key in ('id', 'paper_id', 'paper_title', 'class_id', 'class_name', 'created_at')},
                'question_count': len(questions), 'full_score': sum(question['score'] for question in questions),
                'recipient_count': counts['recipient_count'], 'submitted_count': counts['submitted_count'] or 0}

    def assignment_owner(conn, assignment_id, actor):
        item = assignment(conn, assignment_id)
        if item['teacher_id'] != actor['id']:
            core.fail(403, '只能查看本人布置的练习')
        # Only immutable task grades remain readable after class removal.
        # Ordinary class/roster routes retain the default deleted-class denial.
        core.class_scope(conn, item['class_id'], actor, allow_deleted=True)
        return item

    def is_available(conn, item, student):
        membership = core.one(conn, '''SELECT m.id,g.subject_ids FROM memberships m JOIN classes c ON c.id=m.class_id
          JOIN groups g ON g.id=c.subject_group_id
          WHERE m.class_id=? AND m.user_id=? AND m.status='active'
          AND (m.visibility_accepted=1 OR (m.admin_enrolled_by IS NOT NULL AND m.admin_enrolled_at IS NOT NULL))
          AND c.archived=0 AND c.deleted_at IS NULL AND g.enabled=1''',
                              (item['class_id'], student['id']))
        required = {rule['subject_id'] for rule in json.loads(item['rules'])}
        student_group = core.one(conn, 'SELECT subject_ids FROM groups WHERE id=? AND enabled=1', (student['subject_group_id'],))
        return bool(membership and student_group) and required.issubset(set(json.loads(membership['subject_ids']))) and required.issubset(set(json.loads(student_group['subject_ids'])))

    def student_assignment(conn, assignment_id, actor, require_available=False):
        item = assignment(conn, assignment_id)
        if not core.one(conn, 'SELECT 1 FROM teaching_recipients WHERE assignment_id=? AND user_id=?', (assignment_id, actor['id'])):
            core.fail(404, '班级练习不存在')
        attempt = core.one(conn, 'SELECT * FROM teaching_attempts WHERE assignment_id=? AND user_id=?', (assignment_id, actor['id']))
        if require_available and not (attempt and attempt['submitted_at']) and not is_available(conn, item, actor):
            core.fail(403, '当前班级或科目权限已变更，不能继续此练习')
        return item, attempt

    def start_attempt(conn, item, actor, attempt):
        if attempt:
            return attempt
        questions = shuffled_questions(json.loads(item['questions']), item['shuffle_questions'], item['shuffle_options'])
        conn.execute('INSERT INTO teaching_attempts(assignment_id,user_id,questions,created_at) VALUES(?,?,?,?)',
                     (item['id'], actor['id'], core.canonical(questions), core.iso()))
        return core.one(conn, 'SELECT * FROM teaching_attempts WHERE assignment_id=? AND user_id=?', (item['id'], actor['id']))

    @app.get('/api/teaching/catalog')
    def get_catalog(actor=Depends(core.manager)):
        with core.db() as conn:
            allowed = catalog_subjects(conn, actor)
            _, bank = core.current_bank(conn)
            subjects = []
            for subject in core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid'):
                if subject['id'] in allowed:
                    subjects.append({**subject, 'available': {kind: sum(question['subject_id'] == subject['id'] and question['type'] == kind for question in bank) for kind in QUESTION_TYPES}})
            task_query = '''SELECT COUNT(*) FROM teaching_assignments a JOIN teaching_papers p ON p.id=a.paper_id
              JOIN classes c ON c.id=a.class_id WHERE p.teacher_id=?'''
            task_args = [actor['id']]
            if actor['role'] == 'teacher':
                task_query += ' AND c.teacher_id=?'
                task_args.append(actor['id'])
            return {'subjects': subjects, 'classes': [{key: item[key] for key in ('id', 'name', 'subject_ids')} for item in catalog_classes(conn, actor)],
                    'paper_count': conn.execute('SELECT COUNT(*) FROM teaching_papers WHERE teacher_id=?', (actor['id'],)).fetchone()[0],
                    'assignment_count': conn.execute(task_query, task_args).fetchone()[0]}

    @app.get('/api/teaching/papers')
    def get_papers(limit: int | None = Query(None, ge=1, le=100), offset: int = Query(0, ge=0),
                   q: str = Query('', max_length=100), actor=Depends(core.manager)):
        with core.db() as conn:
            query, args = 'SELECT * FROM teaching_papers WHERE teacher_id=?', [actor['id']]
            if q.strip():
                query += ' AND title LIKE ?'
                args.append('%' + q.strip() + '%')
            query += ' ORDER BY created_at DESC,id DESC LIMIT ? OFFSET ?'
            args.extend([limit if limit is not None else -1, offset])
            return [paper_summary(item) for item in core.rows(conn, query, args)]

    @app.post('/api/teaching/papers')
    def create_paper(request:Request,data: dict = Body(...), actor=Depends(core.manager)):
        strict(data, ('title', 'rules', 'shuffle_questions', 'shuffle_options'))
        title = data.get('title')
        rules = data.get('rules')
        if not isinstance(title, str) or not 1 <= len(title.strip()) <= 100:
            core.fail(422, '练习卷名称须为1至100字')
        if not isinstance(rules, list) or not 1 <= len(rules) <= 100:
            core.fail(422, '须设置1至100条抽题规则')
        for key in ('shuffle_questions', 'shuffle_options'):
            if not isinstance(data.get(key, True), bool):
                core.fail(422, '乱序设置须为布尔值')
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            allowed = catalog_subjects(conn, actor)
            normalized = []
            for rule in rules:
                if not isinstance(rule, dict):
                    core.fail(422, '抽题规则格式无效')
                strict(rule, ('subject_id', 'type', 'count', 'score', 'difficulty', 'knowledge_id'))
                subject_id, kind, count = rule.get('subject_id'), rule.get('type'), rule.get('count')
                if not isinstance(subject_id, str) or subject_id not in allowed or kind not in QUESTION_TYPES:
                    core.fail(422, '规则包含无权使用的科目或题型')
                score, difficulty, knowledge_id = rule.get('score', 1), rule.get('difficulty'), rule.get('knowledge_id')
                if type(count) is not int or not 1 <= count <= 100 or type(score) is not int or not 1 <= score <= 100:
                    core.fail(422, '题量须为1至100，单题分值须为1至100的整数')
                if difficulty is not None and (type(difficulty) is not int or not 1 <= difficulty <= 5):
                    core.fail(422, '难度范围为1至5')
                if knowledge_id is not None and (not isinstance(knowledge_id, str) or not core.one(conn, 'SELECT id FROM knowledge WHERE id=? AND subject_id=?', (knowledge_id, subject_id))):
                    core.fail(422, '知识点与科目不匹配')
                normalized.append({'subject_id': subject_id, 'type': kind, 'count': count, 'score': score,
                                   **({'difficulty': difficulty} if difficulty is not None else {}),
                                   **({'knowledge_id': knowledge_id} if knowledge_id is not None else {})})
            if sum(rule['count'] for rule in normalized) > 100:
                core.fail(422, '单卷最多100道题')
            _, bank = core.current_bank(conn)
            # Bipartite slot matching avoids duplicate questions even when rules overlap,
            # and finds a valid selection when greedy rule order would exhaust a pool.
            slots, candidates = [], []
            random = secrets.SystemRandom()
            for rule in normalized:
                pool = [index for index, question in enumerate(bank) if question['subject_id'] == rule['subject_id'] and question['type'] == rule['type']
                        and ('difficulty' not in rule or question['difficulty'] == rule['difficulty'])
                        and ('knowledge_id' not in rule or question['knowledge_id'] == rule['knowledge_id'])]
                random.shuffle(pool)
                for _ in range(rule['count']):
                    slots.append(rule)
                    candidates.append(pool)
            owned, chosen = {}, {}
            def match(slot, visited):
                for question_index in candidates[slot]:
                    if question_index in visited:
                        continue
                    visited.add(question_index)
                    if question_index not in owned or match(owned[question_index], visited):
                        owned[question_index] = slot
                        chosen[slot] = question_index
                        return True
                return False
            for slot in sorted(range(len(slots)), key=lambda index: len(candidates[index])):
                if not match(slot, set()):
                    core.fail(422, '已发布题库题量不足，或交叠规则无法避免重复用题；请调整题量或筛选条件')
            questions = [{**copy.deepcopy(bank[chosen[index]]), 'score': rule['score']} for index, rule in enumerate(slots)]
            core.require_media_capability(request,questions)
            paper_id = core.uid()
            conn.execute('INSERT INTO teaching_papers VALUES(?,?,?,?,?,?,?,?)',
                         (paper_id, actor['id'], title.strip(), core.canonical(normalized), core.canonical(questions),
                          int(data.get('shuffle_questions', True)), int(data.get('shuffle_options', True)), core.iso()))
            core.audit(conn, actor['id'], 'teaching.paper.create', paper_id)
            return paper_summary(owner(conn, paper_id, actor), True)

    @app.get('/api/teaching/papers/{paper_id}')
    def get_paper(request:Request,paper_id: str, actor=Depends(core.manager)):
        with core.db() as conn:
            result=paper_summary(owner(conn, paper_id, actor), True)
            core.require_media_capability(request,result['questions'])
            return result

    def eligible_recipients(conn, class_id, required):
        """Initial delivery and supplementation share the current subject scope."""
        members = core.rows(conn, '''SELECT u.id,g.enabled,g.subject_ids FROM memberships m
          JOIN users u ON u.id=m.user_id JOIN groups g ON g.id=u.subject_group_id
          WHERE m.class_id=? AND ''' + active_student_clause(), (class_id,))
        return [member for member in members
                if member['enabled'] and required.issubset(set(json.loads(member['subject_ids'])))]

    @app.post('/api/teaching/papers/{paper_id}/assign')
    def assign_paper(paper_id: str, data: dict = Body(...), actor=Depends(core.manager)):
        strict(data, ('class_ids',))
        class_ids = data.get('class_ids')
        if not isinstance(class_ids, list) or not 1 <= len(class_ids) <= 20 or not all(isinstance(value, str) and 1 <= len(value) <= 128 for value in class_ids) or len(set(class_ids)) != len(class_ids):
            core.fail(422, '请选择1至20个不同班级')
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            paper = owner(conn, paper_id, actor)
            required = {rule['subject_id'] for rule in json.loads(paper['rules'])}
            _, published = core.current_bank(conn)
            current_subjects = {question['id']: question['subject_id'] for question in published}
            current_questions = {question['id']:question for question in published}
            paper_questions = json.loads(paper['questions'])
            pending = []
            for class_id in class_ids:
                classroom = core.class_scope(conn, class_id, actor, True)
                group = core.one(conn, 'SELECT * FROM groups WHERE id=?', (classroom['subject_group_id'],))
                if not group or not group['enabled'] or not required.issubset(set(json.loads(group['subject_ids']))):
                    core.fail(422, '卷中科目与班级启用的科目组不兼容')
                existing = core.one(conn, 'SELECT id FROM teaching_assignments WHERE paper_id=? AND class_id=?', (paper_id, class_id))
                if existing:
                    pending.append((existing['id'], None, None))
                    continue
                if any(current_subjects.get(question['id']) != question['subject_id'] for question in paper_questions):
                    core.fail(409, '练习卷包含已下线、移除或调整科目的题目，请使用当前题库重新组卷')
                content_fields = ('type','stem','options','answer','explanation')
                if any(any(question.get(key) != current_questions[question['id']].get(key) for key in content_fields)
                       or question.get('media',{}) != current_questions[question['id']].get('media',{}) for question in paper_questions):
                    core.fail(409,'练习卷题目内容或原图已修订，请使用当前题库重新组卷；原已布置任务保留')
                recipients = eligible_recipients(conn, class_id, required)
                if not recipients:
                    core.fail(422, '班级暂无具备本卷科目权限的正式有效学生，不能布置空任务')
                pending.append((core.uid(), classroom, recipients))
            result = []
            for assignment_id, classroom, recipients in pending:
                if classroom:
                    conn.execute('INSERT INTO teaching_assignments VALUES(?,?,?,?,?)', (assignment_id, paper_id, classroom['id'], classroom['name'], core.iso()))
                    conn.executemany('INSERT INTO teaching_recipients VALUES(?,?)', [(assignment_id, recipient['id']) for recipient in recipients])
                    core.audit(conn, actor['id'], 'teaching.assignment.create', assignment_id)
                result.append(assignment_summary(conn, assignment(conn, assignment_id), actor))
            return {'assignments': result}

    @app.get('/api/teaching/assignments')
    def get_assignments(limit: int | None = Query(None, ge=1, le=100), offset: int = Query(0, ge=0),
                        q: str = Query('', max_length=100), class_id: str | None = None,
                        actor=Depends(core.manager)):
        with core.db() as conn:
            query = '''SELECT a.id FROM teaching_assignments a JOIN teaching_papers p ON p.id=a.paper_id
              JOIN classes c ON c.id=a.class_id WHERE p.teacher_id=?'''
            args = [actor['id']]
            if actor['role'] == 'teacher':
                query += ' AND c.teacher_id=?'
                args.append(actor['id'])
            if class_id is not None:
                core.class_scope(conn, class_id, actor, allow_deleted=True)
                query += ' AND a.class_id=?'
                args.append(class_id)
            if q.strip():
                query += ' AND (p.title LIKE ? OR a.class_name LIKE ?)'
                args.extend(['%' + q.strip() + '%'] * 2)
            query += ' ORDER BY a.created_at DESC,a.id DESC LIMIT ? OFFSET ?'
            args.extend([limit if limit is not None else -1, offset])
            return [assignment_summary(conn, assignment(conn, item['id']), actor) for item in core.rows(conn, query, args)]

    def current_task_class(conn, item, actor, writable=False):
        classroom = core.class_scope(conn, item['class_id'], actor, writable)
        group = core.one(conn, 'SELECT enabled,subject_ids FROM groups WHERE id=?', (classroom['subject_group_id'],))
        required = {rule['subject_id'] for rule in json.loads(item['rules'])}
        if classroom['archived'] or not group or not group['enabled'] or not required.issubset(set(json.loads(group['subject_ids']))):
            core.fail(403, '当前班级或科目范围已变更，不能处理此任务的当前成员')
        return classroom, required

    @app.post('/api/teaching/assignments/{assignment_id}/recipients/sync')
    def sync_recipients(assignment_id: str, actor=Depends(core.manager)):
        """Explicitly supplement an immutable task, without issuing duplicates."""
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            item = assignment_owner(conn, assignment_id, actor)
            _, required = current_task_class(conn, item, actor, True)
            eligible = {member['id'] for member in eligible_recipients(conn, item['class_id'], required)}
            existing = {row['user_id'] for row in core.rows(conn, 'SELECT user_id FROM teaching_recipients WHERE assignment_id=?', (assignment_id,))}
            added = sorted(eligible - existing)
            if added:
                # Newly delivered questions must still match the current school
                # bank. Existing attempts and submitted snapshots are untouched.
                _, bank = core.current_bank(conn)
                current = {question['id']: question for question in bank}
                fields = ('subject_id', 'type', 'stem', 'options', 'answer', 'explanation')
                for question in json.loads(item['questions']):
                    fresh = current.get(question['id'])
                    if not fresh or any(question.get(key) != fresh.get(key) for key in fields) or question.get('media', {}) != fresh.get('media', {}):
                        core.fail(409, '原卷题目已下线或修订，请用当前题库重新组卷；已交成绩保留')
                conn.executemany('INSERT INTO teaching_recipients(assignment_id,user_id) VALUES(?,?)', [(assignment_id, user_id) for user_id in added])
            core.audit(conn, actor['id'], 'teaching.assignment.supplement', assignment_id,
                       '新增正式成员补发' + str(len(added)) + '人')
            return {'assignment': assignment_summary(conn, item, actor), 'added': len(added),
                    'unchanged': len(eligible & existing), 'eligible': len(eligible)}

    @app.get('/api/teaching/assignments/{assignment_id}/question-analysis')
    def question_analysis(assignment_id: str, actor=Depends(core.manager)):
        """Task-only aggregates; no private autonomous answers or departed users."""
        with core.db() as conn:
            conn.execute('BEGIN')
            item = assignment_owner(conn, assignment_id, actor)
            current_task_class(conn, item, actor)
            attempts = core.rows(conn, '''SELECT t.result FROM teaching_attempts t
              JOIN memberships m ON m.class_id=? AND m.user_id=t.user_id
              JOIN users u ON u.id=t.user_id
              WHERE t.assignment_id=? AND t.submitted_at IS NOT NULL AND ''' + active_student_clause(),
                                 (item['class_id'], assignment_id))
            questions = json.loads(item['questions'])
            values = {question['id']: {'id': question['id'], 'index': index + 1,
                       'type': question['type'],
                       'stem': re.sub(r'\{\{img:[^{}]+\}\}', '[题图]', question['stem'])[:280],
                       'answered': 0, 'wrong': 0}
                      for index, question in enumerate(questions)}
            valid_submissions = 0
            for attempt in attempts:
                try:
                    result = json.loads(attempt['result'])
                    entries = result['questions']
                    if not isinstance(entries, list):
                        continue
                    selected = {}
                    for entry in entries:
                        if not isinstance(entry, dict):
                            raise ValueError('malformed grade')
                        question_id = entry.get('id')
                        if question_id in selected or question_id not in values or type(entry.get('correct')) is not bool:
                            raise ValueError('malformed grade')
                        selected[question_id] = entry['correct']
                    if set(selected) != set(values):
                        continue
                    for question_id, correct in selected.items():
                        values[question_id]['answered'] += 1
                        values[question_id]['wrong'] += int(not correct)
                    valid_submissions += 1
                except (ValueError, TypeError, KeyError, AttributeError):
                    continue
            output = [{**row, 'error_rate': round(row['wrong'] * 100 / row['answered'], 1) if row['answered'] else None}
                      for row in values.values()]
            summary = assignment_summary(conn, item, actor)
            conn.commit()
            core.audit(conn, actor['id'], 'teaching.questions.aggregate', assignment_id,
                       '本人任务当前在班学生逐题聚合')
            return {'assignment': summary, 'submitted_count': valid_submissions,
                    'scope': 'current_members_task_only', 'questions': output}

    @app.get('/api/teaching/assignments/{assignment_id}/results')
    def get_results(assignment_id: str, actor=Depends(core.manager)):
        with core.db() as conn:
            conn.execute('BEGIN')
            item = assignment_owner(conn, assignment_id, actor)
            summary = assignment_summary(conn, item, actor)
            results = []
            # Join current identity instead of retaining names in recipient snapshots,
            # so normal account deletion automatically anonymizes retained grades.
            teacher_filter = ''
            args = [assignment_id]
            if actor['role'] == 'teacher':
                teacher_filter = ''' AND EXISTS(SELECT 1 FROM memberships m JOIN users current_student ON current_student.id=m.user_id
                  JOIN classes current_class ON current_class.id=m.class_id
                  WHERE m.class_id=? AND m.user_id=r.user_id AND current_class.archived=0
                  AND current_class.deleted_at IS NULL AND ''' + active_student_clause('m', 'current_student') + ')'
                args.append(item['class_id'])
            for row in core.rows(conn, '''SELECT r.user_id,u.name,u.username,t.result,t.submitted_at
              FROM teaching_recipients r JOIN users u ON u.id=r.user_id LEFT JOIN teaching_attempts t
              ON t.assignment_id=r.assignment_id AND t.user_id=r.user_id WHERE r.assignment_id=?''' + teacher_filter + ' ORDER BY u.name,u.username', args):
                result = json.loads(row['result']) if row['result'] else None
                results.append({key: row[key] for key in ('user_id', 'name', 'username', 'submitted_at')} | {
                    'submitted': result is not None, 'score': result['score'] if result else None,
                    'full_score': summary['full_score'], 'correct': result['correct'] if result else None, 'total': summary['question_count']})
            conn.commit()
            core.audit(conn, actor['id'], 'teaching.results.view', assignment_id)
            return {'assignment': summary, 'results': results}

    @app.get('/api/teaching/assignments/{assignment_id}/students/{student_id}/result')
    def get_student_result(request: Request, assignment_id: str, student_id: str, actor=Depends(core.manager)):
        """Read an already submitted task snapshot; never start or grade an attempt."""
        if actor['role'] != 'teacher':
            core.fail(403, '此入口仅供任课教师查看本人任务的在班学生')
        with core.db() as conn:
            conn.execute('BEGIN')
            item = assignment_owner(conn, assignment_id, actor)
            current_task_class(conn, item, actor)
            matches = _roster(conn, core, item['class_id'], student_id)
            if not matches or not core.one(conn, 'SELECT 1 FROM teaching_recipients WHERE assignment_id=? AND user_id=?',
                                           (assignment_id, student_id)):
                core.fail(404, '学生当前不在此任务的正式接收名单中')
            attempt = core.one(conn, 'SELECT result,submitted_at FROM teaching_attempts WHERE assignment_id=? AND user_id=?',
                               (assignment_id, student_id))
            if not attempt or not attempt['submitted_at'] or not attempt['result']:
                core.fail(409, '学生尚未交卷，暂不能查看本卷作答')
            result = json.loads(attempt['result'])
            core.require_media_capability(request, result['questions'])
            summary = assignment_summary(conn, item, actor)
            conn.commit()
            core.audit(conn, actor['id'], 'teaching.student.result.view', student_id,
                       '教师查看本人任务当前在班学生已交卷快照；任务' + assignment_id)
            return {'assignment': summary, 'student': matches[0], 'result': result}

    @app.get('/api/student/assignments')
    def student_assignments(actor=Depends(core.student)):
        with core.db() as conn:
            result = []
            for row in core.rows(conn, '''SELECT r.assignment_id,t.result,t.submitted_at,t.created_at attempt_started_at FROM teaching_recipients r
              JOIN teaching_assignments a ON a.id=r.assignment_id LEFT JOIN teaching_attempts t
              ON t.assignment_id=r.assignment_id AND t.user_id=r.user_id WHERE r.user_id=? ORDER BY a.created_at DESC''', (actor['id'],)):
                item = assignment(conn, row['assignment_id'])
                grade = json.loads(row['result']) if row['result'] else None
                result.append({**assignment_summary(conn, item), 'submitted': grade is not None,
                               'score': grade['score'] if grade else None, 'correct': grade['correct'] if grade else None,
                               'submitted_at': row['submitted_at'], 'started': row['attempt_started_at'] is not None,
                               'started_at': row['attempt_started_at'],
                               'available': bool(grade) or is_available(conn, item, actor)})
            return result

    @app.get('/api/student/assignments/{assignment_id}')
    def get_student_assignment(request:Request,assignment_id: str, actor=Depends(core.student)):
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            item, attempt = student_assignment(conn, assignment_id, actor, True)
            attempt = start_attempt(conn, item, actor, attempt)
            result = json.loads(attempt['result']) if attempt['result'] else None
            questions = json.loads(attempt['questions'])
            core.require_media_capability(request,questions)
            from .question_media import visible_media
            safe = []
            for question in questions:
                visible = {key:value for key,value in question.items() if key not in ('answer','explanation','media')}
                media = visible_media(question,include_explanation=False)
                if media:
                    visible['media'] = media
                safe.append(visible)
            return {**assignment_summary(conn, item), 'submitted': result is not None, 'questions': safe, 'result': result}

    @app.post('/api/student/assignments/{assignment_id}/submit')
    def submit_assignment(assignment_id: str, data: dict = Body(...), actor=Depends(core.student)):
        strict(data, ('client_uuid', 'answers'))
        try:
            client_uuid = str(uuid.UUID(data.get('client_uuid', '')))
        except (ValueError, TypeError, AttributeError):
            core.fail(422, '提交标识须为UUID')
        answers = data.get('answers')
        if not isinstance(answers, list) or not 1 <= len(answers) <= 100:
            core.fail(422, '须提交整卷1至100道题的答案')
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            item, attempt = student_assignment(conn, assignment_id, actor, True)
            attempt = start_attempt(conn, item, actor, attempt)
            questions = json.loads(attempt['questions'])
            by_id = {question['id']: question for question in questions}
            selected = {}
            for answer in answers:
                if not isinstance(answer, dict):
                    core.fail(422, '答案格式无效')
                strict(answer, ('question_id', 'selected'))
                question_id, values = answer.get('question_id'), answer.get('selected')
                if not isinstance(question_id, str) or question_id not in by_id or question_id in selected:
                    core.fail(422, '答案包含未知或重复题目')
                question = by_id[question_id]
                if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                    core.fail(422, '作答须为字符串列表')
                if question['type'] == 'fill':
                    if len(values) not in (0, question['blank_count']) or any(len(value) > 1000 for value in values):
                        core.fail(422, '填空作答数量或长度无效')
                elif len(values) > len(question['options']) or len(set(values)) != len(values) or any(value not in {option['key'] for option in question['options']} for value in values) or (question['type'] != 'multiple' and len(values) > 1):
                    core.fail(422, '选项作答无效，请提交原始选项标识')
                selected[question_id] = values if question['type'] == 'fill' else sorted(values)
            if set(selected) != set(by_id):
                core.fail(422, '须提交整卷答案，未作答题目请传空列表')
            payload_hash = hashlib.sha256(core.canonical(selected).encode()).hexdigest()
            if attempt['submitted_at']:
                if attempt['client_uuid'] != client_uuid or attempt['payload_hash'] != payload_hash:
                    core.fail(409, '练习已提交，不能更换提交标识或答案')
                return json.loads(attempt['result'])
            reviews = []
            for question in questions:
                correct = bool(grade_question(question, selected[question['id']]))
                reviews.append({**question, 'selected': selected[question['id']], 'correct': correct,
                                'awarded_score': question['score'] if correct else 0})
            submitted_at = core.iso()
            result = {'assignment_id': assignment_id, 'score': sum(question['awarded_score'] for question in reviews),
                      'full_score': sum(question['score'] for question in reviews), 'correct': sum(question['correct'] for question in reviews),
                      'total': len(reviews), 'submitted_at': submitted_at, 'questions': reviews}
            conn.execute('UPDATE teaching_attempts SET client_uuid=?,payload_hash=?,result=?,submitted_at=? WHERE assignment_id=? AND user_id=? AND submitted_at IS NULL',
                         (client_uuid, payload_hash, core.canonical(result), submitted_at, assignment_id, actor['id']))
            core.audit(conn, actor['id'], 'teaching.assignment.submit', assignment_id)
            return result
