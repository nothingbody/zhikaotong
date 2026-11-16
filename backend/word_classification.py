"""Reconcile source-backed classifications and publish corrected snapshots."""
import json

from fastapi import Body, Depends


def register_word_classification(app, core, subject_mapping, subject_names, fingerprint):
    @app.post('/api/management/imports/word/classify')
    def classify_word(data: dict = Body(...), actor=Depends(core.admin)):
        preview_id, apply = data.get('preview_id'), data.get('apply', False)
        if not isinstance(preview_id, str) or not isinstance(apply, bool):
            core.fail(422, '识别预览或执行标记无效')
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            preview = core.one(conn, 'SELECT * FROM word_import_previews WHERE id=?', (preview_id,))
            if not preview or preview['actor_id'] != actor['id']:
                core.fail(404, '识别预览不存在')
            if preview['expires_at'] <= core.iso():
                core.fail(410, '识别预览已过期')
            mapping = subject_mapping(conn, core)
            assignments, conflicts, protected_ids = {}, [], set()
            for question in json.loads(preview['payload'])['questions']:
                source = core.one(conn, 'SELECT question_id FROM word_import_items WHERE source_key=? AND document_hash=?', (question['source_key'], preview['document_hash']))
                if not source:
                    continue
                hint = question.get('subject_hint')
                identifier = source['question_id']
                original = core.one(conn, 'SELECT status FROM questions WHERE id=?', (identifier,))
                if original and (original['status'] == 'deleted' or core.one(conn, 'SELECT question_id FROM question_classification_overrides WHERE question_id=?', (identifier,))):
                    protected_ids.add(identifier)
                    continue
                if hint not in subject_names or hint not in mapping:
                    conflicts.append({'question_id': identifier, 'source_label': question['source_label'], 'reason': '科目未知或尚未配置对应科目'})
                    continue
                previous = assignments.get(identifier)
                if previous and previous != hint:
                    conflicts.append({'question_id': identifier, 'source_label': question['source_label'], 'reason': '同一题的来源科目存在冲突'})
                else:
                    assignments[identifier] = hint
            blocked_ids = {item['question_id'] for item in conflicts}
            checked, changed, protected = len(protected_ids), 0, len(protected_ids)
            counts = {}
            for identifier, hint in assignments.items():
                if identifier in blocked_ids:
                    continue
                question = core.one(conn, 'SELECT * FROM questions WHERE id=?', (identifier,))
                if not question:
                    continue
                checked += 1
                counts[subject_names[hint]] = counts.get(subject_names[hint], 0) + 1
                if question['subject_id'] == mapping[hint]:
                    continue
                changed += 1
                if not apply:
                    continue
                subject_id = mapping[hint]
                node = core.one(conn, "SELECT id FROM knowledge WHERE subject_id=? AND name='Word导入待归类'", (subject_id,))
                knowledge_id = node['id'] if node else core.uid()
                if not node:
                    conn.execute('INSERT INTO knowledge(id,name,subject_id) VALUES(?,?,?)', (knowledge_id, 'Word导入待归类', subject_id))
                conn.execute('UPDATE questions SET subject_id=?,knowledge_id=?,updated_at=? WHERE id=?', (subject_id, knowledge_id, core.iso(), identifier))
                # Keep document-source fingerprints stable. Import deduplication
                # checks both original source hashes and current question data.
                core.audit(conn, actor['id'], 'word.classification.update', identifier, question['subject_id'] + ' -> ' + subject_id)
            core.audit(conn, actor['id'], 'word.classification.apply' if apply else 'word.classification.audit', preview_id, f'{checked} checked; {changed} changes; {protected} protected')
            if apply and changed:
                release = core.publish_bank(conn, actor['id'])
            else:
                version, bank = core.current_bank(conn)
                release = {'version': version, 'count': len(bank)}
            return {'checked': checked, 'changed': changed, 'applied': apply, 'protected': protected, 'by_subject': counts, 'conflicts': conflicts, **release}
