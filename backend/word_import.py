"""Admin-only DOCX preview and explicit, idempotent direct publishing."""
import base64
import binascii
import hashlib
import json
import os
from datetime import timedelta
from pathlib import Path

from fastapi import Body, Depends, HTTPException

SUBJECT_NAMES = {'chinese': '语文', 'math': '数学', 'english': '英语', 'politics': '思想政治', 'mechanics': '机械专业综合理论'}
MAX_FILE_BYTES = 15 * 1024 * 1024


def bank_directory():
    return Path(os.environ.get('WORD_BANK_DIR', str(Path(__file__).resolve().parents[1]))).resolve()


def local_files():
    directory = bank_directory()
    if not directory.is_dir():
        return []
    files = []
    for path in sorted(directory.glob('*.docx')):
        if path.is_symlink() or path.resolve().parent != directory or not path.is_file() or path.name.startswith('~$'):
            continue
        size = path.stat().st_size
        if size > MAX_FILE_BYTES:
            continue
        files.append({'id': hashlib.sha256(path.name.encode('utf-8')).hexdigest(), 'name': path.name, 'size': size})
    return files


def resolve_document(data):
    if data.get('local_file_id'):
        identifier = data['local_file_id']
        if not isinstance(identifier, str):
            raise HTTPException(422, '本地题库标识无效')
        match = next((item for item in local_files() if item['id'] == identifier), None)
        if not match:
            raise HTTPException(404, '本地题库不存在，请重新选择')
        path = bank_directory() / match['name']
        with path.open('rb') as file:
            raw = file.read(MAX_FILE_BYTES + 1)
        filename = match['name']
    else:
        filename = data.get('filename')
        encoded = data.get('content_base64')
        if not isinstance(filename, str) or not filename.lower().endswith('.docx') or len(filename) > 200:
            raise HTTPException(422, '请选择 DOCX 格式的 Word 文件')
        filename = filename.replace('\\', '/').rsplit('/', 1)[-1]
        if not isinstance(encoded, str) or len(encoded) > (MAX_FILE_BYTES + 2) // 3 * 4:
            raise HTTPException(413, 'Word 文件不能超过15MB')
        try:
            raw = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            raise HTTPException(422, 'Word 文件编码无效') from None
    if not raw or len(raw) > MAX_FILE_BYTES:
        raise HTTPException(413, 'Word 文件为空或超过15MB')
    return raw, filename


def content_hash(core, question):
    fields = {key: question[key] for key in ('subject_id', 'type', 'stem', 'options', 'answer')}
    return hashlib.sha256(core.canonical(fields).encode('utf-8')).hexdigest()


def suggested_map(subjects):
    result = {}
    for hint, name in SUBJECT_NAMES.items():
        subject = next((item for item in subjects if item['id'] == hint or item['name'] == name or (hint == 'mechanics' and item['name'].startswith('机械'))), None)
        if subject:
            result[hint] = subject['id']
    return result


def subject_mapping(conn, core, subjects=None):
    result = suggested_map(subjects if subjects is not None else core.rows(conn, 'SELECT * FROM subjects'))
    # Explicit subject renaming must not create a second canonical subject on a
    # later document import. Current names/IDs retain priority over old aliases.
    for item in core.rows(conn, 'SELECT m.hint,m.subject_id FROM word_subject_mappings m JOIN subjects s ON s.id=m.subject_id'):
        result.setdefault(item['hint'], item['subject_id'])
    return result


def register_word_import(app, core):
    core.SCHEMA += '''
    CREATE TABLE IF NOT EXISTS word_import_previews(id TEXT PRIMARY KEY,actor_id TEXT NOT NULL,filename TEXT NOT NULL,document_hash TEXT NOT NULL,payload TEXT NOT NULL,created_at TEXT NOT NULL,expires_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS word_import_items(source_key TEXT PRIMARY KEY,document_hash TEXT NOT NULL,question_id TEXT NOT NULL REFERENCES questions(id) ON DELETE CASCADE,content_hash TEXT NOT NULL);
    CREATE INDEX IF NOT EXISTS word_import_content ON word_import_items(content_hash);
    '''

    @app.get('/api/management/imports/word/local')
    def available_local(actor=Depends(core.admin)):
        return {'files': local_files()}

    @app.post('/api/management/imports/word/preview')
    def preview_word(data: dict = Body(...), actor=Depends(core.admin)):
        from .word_parser import parse_docx
        raw, filename = resolve_document(data)
        try:
            parsed = parse_docx(raw, filename, preserve_media=True)
        except ValueError as error:
            core.fail(422, str(error)[:300])
        if not isinstance(parsed, dict):
            core.fail(422, '无法识别该Word题库')
        digest = hashlib.sha256(raw).hexdigest()
        candidates = []
        excluded = list(parsed.get('excluded', []))
        for index, original in enumerate(parsed.get('questions', [])):
            if original.get('type') not in {'single', 'multiple', 'fill', 'judge'}:
                excluded.append({'reason': '只导入选择、填空和判断题', 'source_label': original.get('source_label', ''), 'section': original.get('section', '')})
                continue
            candidate = dict(original)
            candidate.setdefault('source_key', hashlib.sha256(f'{digest}:{index}'.encode()).hexdigest())
            candidate.setdefault('source_label', str(index + 1))
            candidate.setdefault('source_index', index)
            candidate.setdefault('section', candidate.get('source_section', ''))
            candidate.setdefault('warnings', [])
            candidate.setdefault('blocked_reasons', [])
            candidate.setdefault('explanation', '原资料未提供解析。')
            candidate.setdefault('eligible', False)
            candidates.append(candidate)
        if len(candidates) > 5000:
            core.fail(422, '单份文件最多识别5000道题，请拆分文件')
        payload = {'questions': candidates, 'excluded': excluded, 'warnings': parsed.get('warnings', [])}
        with core.db() as conn:
            conn.execute('DELETE FROM word_import_previews WHERE expires_at<?', (core.iso(),))
            preview_id = core.uid()
            conn.execute('INSERT INTO word_import_previews VALUES(?,?,?,?,?,?,?)', (preview_id, actor['id'], filename, digest, core.canonical(payload), core.iso(), core.iso(core.now() + timedelta(hours=24))))
            subjects = core.rows(conn, 'SELECT * FROM subjects')
            knowledge = core.rows(conn, 'SELECT * FROM knowledge')
            mappings = subject_mapping(conn, core, subjects)
            core.audit(conn, actor['id'], 'word.preview', filename, f'{len(candidates)} candidates; {len(excluded)} excluded')
        summary = {**parsed.get('summary', {}), 'total': len(candidates), 'eligible': sum(bool(item['eligible']) for item in candidates), 'blocked': sum(not bool(item['eligible']) for item in candidates), 'excluded': len(excluded)}
        for kind in ('single', 'multiple', 'fill', 'judge'):
            summary[kind] = sum(item['type'] == kind for item in candidates)
        by_subject = {}
        unique_by_subject = {}
        for candidate in candidates:
            hint = candidate.get('subject_hint') or 'unknown'
            counts = by_subject.setdefault(hint, {'total': 0, 'eligible': 0, 'blocked': 0, 'single': 0, 'multiple': 0, 'fill': 0, 'judge': 0})
            counts['total'] += 1
            counts['eligible' if candidate['eligible'] else 'blocked'] += 1
            counts[candidate['type']] += 1
            if candidate['eligible']:
                unique_by_subject.setdefault(hint,set()).add(content_hash(core,{**candidate,'subject_id':hint}))
        for hint,counts in by_subject.items():
            counts['unique_eligible'] = len(unique_by_subject.get(hint,set()))
            counts['duplicate_eligible'] = counts['eligible'] - counts['unique_eligible']
        summary['unique_eligible'] = sum(len(values) for values in unique_by_subject.values())
        summary['duplicate_eligible'] = summary['eligible'] - summary['unique_eligible']
        summary['by_subject'] = by_subject
        return {'preview_id': preview_id, 'filename': filename, **payload, 'summary': summary, 'subjects': subjects, 'knowledge': knowledge, 'subject_map': mappings}

    @app.post('/api/management/imports/word/commit')
    def commit_word(data: dict = Body(...), actor=Depends(core.admin)):
        preview_id = data.get('preview_id')
        selected = data.get('source_keys')
        authorization = data.get('authorization')
        mapping = data.get('subject_map', {})
        overrides = data.get('overrides', {})
        create_missing = data.get('create_missing_subjects', True)
        default_subject_id = data.get('default_subject_id')
        if not isinstance(preview_id, str) or not isinstance(selected, list) or not 1 <= len(selected) <= 5000 or not all(isinstance(key, str) and len(key) <= 128 for key in selected) or len(set(selected)) != len(selected):
            core.fail(422, '请选择1至5000道不同的题目')
        if not isinstance(authorization, str) or not 2 <= len(authorization.strip()) <= 1000:
            core.fail(422, '请填写本次题库的来源授权记录（2至1000字）')
        if not isinstance(mapping, dict) or not all(key in SUBJECT_NAMES and (value is None or isinstance(value, str)) for key, value in mapping.items()) or not isinstance(overrides, dict) or not isinstance(create_missing, bool):
            core.fail(422, '科目映射或修正内容格式无效')
        if default_subject_id is not None:
            default_subject_id = core.identifier(default_subject_id)
        errors, prepared, duplicates = [], [], 0
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            preview = core.one(conn, 'SELECT * FROM word_import_previews WHERE id=?', (preview_id,))
            if not preview or preview['actor_id'] != actor['id']:
                core.fail(404, '识别预览不存在')
            if preview['expires_at'] <= core.iso():
                core.fail(410, '识别预览已过期，请重新识别Word')
            if default_subject_id is not None and not core.one(conn, 'SELECT id FROM subjects WHERE id=?', (default_subject_id,)):
                core.fail(422, '人工指定的科目不存在，请选择已创建的真实科目')
            questions = {item['source_key']: item for item in json.loads(preview['payload'])['questions']}
            defaults = subject_mapping(conn, core)
            resolved_subjects, seen_fingerprints = {}, {}
            # Source fingerprints remain tied to the original document. Also
            # recognize current content after a manual move to another subject.
            current_fingerprints = {content_hash(core, core.question_public(question)): question['id'] for question in core.rows(conn, 'SELECT * FROM questions')}
            for key in selected:
                candidate = questions.get(key)
                if not candidate:
                    errors.append({'source_label': key, 'message': '题目不属于本次识别预览'})
                    continue
                label = candidate['source_label']
                if core.one(conn, 'SELECT source_key FROM word_import_items WHERE source_key=?', (key,)):
                    duplicates += 1
                    continue
                changes = overrides.get(key, {})
                if not isinstance(changes, dict) or set(changes) - {'stem', 'answer', 'options', 'explanation'}:
                    errors.append({'source_label': label, 'message': '仅可修正题干、选项、答案与解析'})
                    continue
                item = {**candidate, **changes}
                reasons = candidate.get('blocked_reasons', [])
                hint = item.get('subject_hint')
                manually_mapped = hint not in SUBJECT_NAMES and default_subject_id is not None
                if manually_mapped:
                    # An explicit target resolves only the missing classification. It
                    # never resolves missing source media, formulas, material or answers.
                    reasons = [reason for reason in reasons if reason != '未能可靠识别科目，请人工指定科目']
                if not candidate.get('eligible') and not (manually_mapped and not reasons):
                    # Missing answers may be completed by the operator. Incomplete source
                    # diagrams/formulas/material cannot be promoted merely by posting an answer.
                    answer_only = reasons and all(any(term in str(reason).lower() for term in ('missing_answer', 'answer_missing', '缺少答案', '未找到答案', '答案缺失', '缺少可确定的答案')) for reason in reasons)
                    if not (answer_only and changes.get('answer')):
                        errors.append({'source_label': label, 'message': '原文内容或答案不完整，需先人工核对：' + '；'.join(map(str, reasons))})
                        continue
                if hint not in SUBJECT_NAMES and not manually_mapped:
                    errors.append({'source_label': label, 'message': '无法识别题目科目，不能自动归类'})
                    continue
                subject_id = default_subject_id if manually_mapped else mapping.get(hint) or defaults.get(hint)
                if not subject_id and hint in resolved_subjects:
                    subject_id = resolved_subjects[hint]
                if not subject_id and create_missing:
                    subject_id = core.uid()
                    conn.execute('INSERT INTO subjects(id,name,full_score,duration_minutes) VALUES(?,?,100,60)', (subject_id, SUBJECT_NAMES[hint]))
                    resolved_subjects[hint] = subject_id
                    core.audit(conn, actor['id'], 'subject.create.word_import', subject_id, SUBJECT_NAMES[hint])
                if not subject_id or not core.one(conn, 'SELECT id FROM subjects WHERE id=?', (subject_id,)):
                    errors.append({'source_label': label, 'message': '请为' + SUBJECT_NAMES.get(hint, '未识别题目') + '指定科目，或勾选新增未匹配科目'})
                    continue
                node = core.one(conn, "SELECT id FROM knowledge WHERE subject_id=? AND name='Word导入待归类'", (subject_id,))
                if not node:
                    knowledge_id = core.uid()
                    conn.execute('INSERT INTO knowledge(id,name,subject_id) VALUES(?,?,?)', (knowledge_id, 'Word导入待归类', subject_id))
                else:
                    knowledge_id = node['id']
                question = {'subject_id': subject_id, 'knowledge_id': knowledge_id, 'type': item['type'], 'stem': item.get('stem'), 'options': item.get('options', []), 'answer': item.get('answer', []), 'explanation': item.get('explanation') or '原资料未提供解析。', 'difficulty': item.get('difficulty', 1), 'source': (item.get('source') or preview['filename'] + ' | ' + item.get('section', '') + ' | ' + str(label))[:500], 'authorization': authorization.strip(), 'status': 'published', 'media':item.get('media',{})}
                try:
                    core.validate_question(conn, question)
                except HTTPException as error:
                    errors.append({'source_label': label, 'message': str(error.detail)})
                    continue
                fingerprint = content_hash(core, question)
                existing = core.one(conn, 'SELECT question_id FROM word_import_items WHERE content_hash=? LIMIT 1', (fingerprint,))
                if not existing and fingerprint in current_fingerprints:
                    existing = {'question_id': current_fingerprints[fingerprint]}
                if existing or fingerprint in seen_fingerprints:
                    duplicates += 1
                    # A previously committed source remains discoverable for future retries.
                    if existing:
                        conn.execute('INSERT INTO word_import_items VALUES(?,?,?,?)', (key, preview['document_hash'], existing['question_id'], fingerprint))
                    continue
                seen_fingerprints[fingerprint] = key
                prepared.append((key, fingerprint, question))
            if errors:
                conn.rollback()
                return {'created': 0, 'duplicates': 0, 'batch_id': None, 'errors': errors}
            identifiers = []
            for key, fingerprint, question in prepared:
                identifier = core.uid()
                identifiers.append(identifier)
                conn.execute('INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at,media) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', (identifier, question['subject_id'], question['knowledge_id'], question['type'], question['stem'], core.canonical(question['options']), core.canonical(question['answer']), question['explanation'], question['difficulty'], question['source'], question['authorization'], 'published', actor['id'], None, core.iso(), core.iso(), core.canonical(question.get('media',{}))))
                conn.execute('INSERT INTO word_import_items VALUES(?,?,?,?)', (key, preview['document_hash'], identifier, fingerprint))
            batch_id = None
            if identifiers:
                batch_id = core.uid()
                conn.execute('INSERT INTO question_import_batches VALUES(?,?,?,?,?)', (batch_id, actor['id'], core.canonical(identifiers), 'imported', core.iso()))
                release = core.publish_bank(conn, actor['id'])
            else:
                version, bank = core.current_bank(conn)
                release = {'version': version, 'count': len(bank)}
            core.audit(conn, actor['id'], 'word.import', batch_id or preview_id, f'{len(identifiers)} published; {duplicates} duplicates')
            return {'created': len(identifiers), 'duplicates': duplicates, 'batch_id': batch_id, 'errors': [], **release}

    from .word_classification import register_word_classification
    register_word_classification(app, core, subject_mapping, SUBJECT_NAMES, content_hash)
