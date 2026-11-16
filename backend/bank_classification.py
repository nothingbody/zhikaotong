"""Subject-first administration without changing school visibility groups."""
import unicodedata

from fastapi import Body, Depends
from .bank_pagination import release_summary


def normalized_subject_name(core, value):
    if not isinstance(value, str):
        core.fail(422, '科目名称必填')
    name = ' '.join(unicodedata.normalize('NFKC', value).split())
    if not 1 <= len(name) <= 100:
        core.fail(422, '科目名称须为1至100字')
    return name


def default_knowledge(conn, core, subject_id):
    node = core.one(conn, "SELECT id FROM knowledge WHERE subject_id=? AND name IN ('科目题目','Word导入待归类') ORDER BY CASE name WHEN '科目题目' THEN 0 ELSE 1 END,rowid LIMIT 1", (subject_id,))
    if node:
        return node['id']
    identifier = core.uid()
    conn.execute('INSERT INTO knowledge(id,name,subject_id) VALUES(?,?,?)', (identifier, '科目题目', subject_id))
    return identifier


def normalize_question_scope(conn, core, data, previous=None):
    item = dict(data)
    subject_id = core.identifier(item.get('subject_id'))
    if not core.one(conn, 'SELECT id FROM subjects WHERE id=?', (subject_id,)):
        core.fail(422, '科目不存在')
    knowledge = item.get('knowledge_id')
    if knowledge in (None, ''):
        if previous and previous['subject_id'] == subject_id and core.one(conn, 'SELECT id FROM knowledge WHERE id=? AND subject_id=?', (previous['knowledge_id'], subject_id)):
            knowledge = previous['knowledge_id']
        else:
            knowledge = default_knowledge(conn, core, subject_id)
    core.identifier(knowledge)
    item['knowledge_id'] = knowledge
    return item


def record_manual_classification(conn, core, question_id, subject_id, knowledge_id, actor_id):
    conn.execute('INSERT INTO question_classification_overrides(question_id,subject_id,knowledge_id,actor_id,updated_at) VALUES(?,?,?,?,?) ON CONFLICT(question_id) DO UPDATE SET subject_id=excluded.subject_id,knowledge_id=excluded.knowledge_id,actor_id=excluded.actor_id,updated_at=excluded.updated_at', (question_id, subject_id, knowledge_id, actor_id, core.iso()))


def register_bank_classification(app, core):
    core.SCHEMA += '''
    CREATE TABLE IF NOT EXISTS question_classification_overrides(question_id TEXT PRIMARY KEY REFERENCES questions(id),subject_id TEXT NOT NULL REFERENCES subjects(id),knowledge_id TEXT NOT NULL REFERENCES knowledge(id),actor_id TEXT NOT NULL REFERENCES users(id),updated_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS word_subject_mappings(hint TEXT PRIMARY KEY,subject_id TEXT NOT NULL REFERENCES subjects(id));
    '''

    @app.get('/api/management/bank/classifications')
    def classifications(actor=Depends(core.admin)):
        with core.db() as conn:
            version, published_count = release_summary(conn)
            questions = core.rows(conn, "SELECT subject_id,type,status FROM questions WHERE status<>'deleted'")
            subjects = []
            for subject in core.rows(conn, 'SELECT id,name FROM subjects ORDER BY rowid'):
                members = [item for item in questions if item['subject_id'] == subject['id']]
                subjects.append({**subject, 'total': len(members), 'published': sum(item['status'] == 'published' for item in members),
                                 'offline': sum(item['status'] == 'offline' for item in members),
                                 'by_type': {kind: sum(item['type'] == kind for item in members) for kind in ('single', 'multiple', 'judge', 'fill')}})
            return {'version': version, 'total': len(questions), 'published': published_count, 'subjects': subjects}

    @app.post('/api/management/bank/subjects')
    def create_subject(data: dict = Body(...), actor=Depends(core.admin)):
        if set(data) != {'name'}:
            core.fail(422, '仅需填写科目名称')
        name = normalized_subject_name(core, data['name'])
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            if any(normalized_subject_name(core, row['name']).casefold() == name.casefold() for row in core.rows(conn, 'SELECT name FROM subjects')):
                core.fail(409, '科目名称已存在')
            identifier = core.uid()
            conn.execute('INSERT INTO subjects(id,name,group_id) VALUES(?,?,NULL)', (identifier, name))
            core.audit(conn, actor['id'], 'subject.create.bank', identifier, name)
            return core.one(conn, 'SELECT * FROM subjects WHERE id=?', (identifier,))

    @app.patch('/api/management/bank/subjects/{subject_id}')
    def rename_subject(subject_id: str, data: dict = Body(...), actor=Depends(core.admin)):
        if set(data) != {'name'}:
            core.fail(422, '仅支持修改科目名称')
        name = normalized_subject_name(core, data['name'])
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            old = core.one(conn, 'SELECT * FROM subjects WHERE id=?', (core.identifier(subject_id),))
            if not old:
                core.fail(404, '科目不存在')
            if any(row['id'] != subject_id and normalized_subject_name(core, row['name']).casefold() == name.casefold() for row in core.rows(conn, 'SELECT id,name FROM subjects')):
                core.fail(409, '科目名称已存在')
            if old['name'] != name:
                from .word_import import SUBJECT_NAMES
                for hint, canonical in SUBJECT_NAMES.items():
                    if normalized_subject_name(core, old['name']) == canonical:
                        conn.execute('INSERT INTO word_subject_mappings(hint,subject_id) VALUES(?,?) ON CONFLICT(hint) DO UPDATE SET subject_id=excluded.subject_id', (hint, subject_id))
                conn.execute('UPDATE subjects SET name=? WHERE id=?', (name, subject_id))
                core.audit(conn, actor['id'], 'subject.rename.bank', subject_id, old['name'] + ' -> ' + name)
            return core.one(conn, 'SELECT * FROM subjects WHERE id=?', (subject_id,))

    @app.post('/api/management/questions/classify')
    def classify_questions(data: dict = Body(...), actor=Depends(core.admin)):
        if set(data) - {'ids', 'subject_id', 'knowledge_id'}:
            core.fail(422, '不支持的分类字段')
        identifiers = data.get('ids')
        if not isinstance(identifiers, list) or not 1 <= len(identifiers) <= 5000 or not all(isinstance(value, str) and 1 <= len(value) <= 128 for value in identifiers) or len(set(identifiers)) != len(identifiers):
            core.fail(422, '请选择1至5000道不同题目')
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            prepared = []
            for identifier in identifiers:
                previous = core.one(conn, "SELECT * FROM questions WHERE id=? AND status<>'deleted'", (identifier,))
                if not previous:
                    core.fail(404, '题目不存在或已移除')
                target = normalize_question_scope(conn, core, data, previous)
                if not core.one(conn, 'SELECT id FROM knowledge WHERE id=? AND subject_id=?', (target['knowledge_id'], target['subject_id'])):
                    core.fail(422, '知识点与目标科目不匹配')
                prepared.append((previous, target))
            changed = published_changed = 0
            for previous, target in prepared:
                record_manual_classification(conn, core, previous['id'], target['subject_id'], target['knowledge_id'], actor['id'])
                if (previous['subject_id'], previous['knowledge_id']) == (target['subject_id'], target['knowledge_id']):
                    continue
                conn.execute('UPDATE questions SET subject_id=?,knowledge_id=?,updated_at=? WHERE id=?', (target['subject_id'], target['knowledge_id'], core.iso(), previous['id']))
                core.audit(conn, actor['id'], 'question.classify', previous['id'], previous['subject_id'] + ' -> ' + target['subject_id'])
                changed += 1
                published_changed += int(previous['status'] == 'published')
            if published_changed:
                release = core.publish_bank(conn, actor['id'])
            else:
                version, current = core.current_bank(conn)
                release = {'version': version, 'count': len(current)}
            return {'changed': changed, 'published_changed': published_changed, **release}
