"""Audited individual views and bounded XLSX imports for the M1 workflow."""
import base64
import binascii
import io
import json
import zipfile
from copy import copy

from fastapi import Body, Depends, HTTPException, Query
from openpyxl import Workbook, load_workbook

USER_HEADERS = ['username', 'name', 'password']
QUESTION_HEADERS = ['subject_id', 'knowledge_id', 'type', 'stem', 'option_A', 'option_B', 'option_C', 'option_D', 'answer', 'explanation', 'difficulty', 'source', 'authorization']


def parse_workbook(encoded, kind):
    if not isinstance(kind, str) or kind not in {'users', 'questions'}:
        raise HTTPException(422, '模板类型无效')
    if not isinstance(encoded, str) or len(encoded) > 1_400_000:
        raise HTTPException(413, 'Excel 文件请控制在 1MB 以内')
    try:
        raw = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error):
        raise HTTPException(422, '文件编码无效')
    if len(raw) > 1_048_576:
        raise HTTPException(413, 'Excel 文件请控制在 1MB 以内')
    try:
        with zipfile.ZipFile(io.BytesIO(raw)) as archive:
            entries = archive.infolist()
            if len(entries) > 2000 or sum(entry.file_size for entry in entries) > 20_000_000:
                raise ValueError('文件解压体积过大')
            for entry in entries:
                if entry.filename.lower().endswith('.bin'):
                    raise ValueError('不支持含宏或嵌入文件的工作簿')
                if entry.filename.lower().endswith('.xml'):
                    xml = archive.read(entry)
                    if b'<!DOCTYPE' in xml.upper() or b'<!ENTITY' in xml.upper():
                        raise ValueError('工作簿包含不支持的 XML 声明')
        workbook = load_workbook(io.BytesIO(raw), read_only=True, data_only=False, keep_links=False)
        try:
            if len(workbook.worksheets) != 1:
                raise ValueError('请使用仅有一个工作表的模板')
            sheet = workbook.worksheets[0]
            if (sheet.max_row or 0) > 501 or (sheet.max_column or 0) > 30:
                raise ValueError('每次最多500行、30列')
            iterator = sheet.iter_rows()
            header_cells = next(iterator, None)
            if not header_cells:
                raise ValueError('工作簿为空')
            headers = [str(cell.value or '').strip() for cell in header_cells]
            while headers and not headers[-1]:
                headers.pop()
            expected = USER_HEADERS if kind == 'users' else QUESTION_HEADERS
            if headers != expected:
                raise ValueError('列名或顺序不匹配，请下载最新模板')
            result = []
            for row_number, row in enumerate(iterator, 2):
                if row_number > 501:
                    raise ValueError('每次最多导入500行')
                if any(cell.data_type == 'f' for cell in row):
                    raise ValueError(f'第{row_number}行含公式，请粘贴为纯文本')
                values = [cell.value for cell in row[:len(headers)]]
                if not any(value is not None and str(value).strip() for value in values):
                    continue
                if any(value is not None and len(str(value)) > 12000 for value in values):
                    raise ValueError(f'第{row_number}行字段过长')
                item = {header: '' if value is None else str(value) for header, value in zip(headers, values)}
                if kind == 'users':
                    item['username'] = item['username'].strip()
                    item['name'] = item['name'].strip()
                else:
                    try:
                        item['difficulty'] = int(item['difficulty'])
                    except ValueError:
                        raise ValueError(f'第{row_number}行难度须为1至5的整数')
                    item['options'] = [{'key': key, 'text': item.pop('option_' + key)} for key in 'ABCD']
                    item['options'] = [option for option in item['options'] if option['text'].strip()]
                    item['answer'] = [key.strip().upper() for key in item['answer'].replace('，', ',').split(',') if key.strip()]
                    item['status'] = 'published'
                result.append(item)
            if not result:
                raise ValueError('模板中没有数据行')
            return result
        finally:
            workbook.close()
    except HTTPException:
        raise
    except Exception as exc:
        message = str(exc) if isinstance(exc, ValueError) else '不是有效的 XLSX 文件'
        raise HTTPException(422, message) from None


def register_extensions(app, core):
    core.SCHEMA += '''
    CREATE TABLE IF NOT EXISTS question_import_batches(id TEXT PRIMARY KEY,creator_id TEXT NOT NULL,question_ids TEXT NOT NULL,status TEXT NOT NULL,created_at TEXT NOT NULL);
    '''

    @app.get('/api/management/questions/import/batches')
    def import_batches(actor=Depends(core.admin)):
        with core.db() as conn:
            batches = core.rows(conn, "SELECT b.*,u.name creator_name,EXISTS(SELECT 1 FROM audit a WHERE a.target=b.id AND a.action IN ('word.import.draft','word.import')) word_import FROM question_import_batches b JOIN users u ON u.id=b.creator_id ORDER BY b.created_at DESC LIMIT 50")
            existing = {row[0] for row in conn.execute("SELECT id FROM questions WHERE status<>'deleted'")}
            core.audit(conn, actor['id'], 'questions.import.history.view')
            return [{'id': item['id'], 'batch_id': item['id'], 'created_count': len(json.loads(item['question_ids'])), 'remaining_count': sum(identifier in existing for identifier in json.loads(item['question_ids'])), 'status': item['status'], 'created_at': item['created_at'], 'creator_name': item['creator_name'], 'kind': 'word' if item['word_import'] else 'xlsx'} for item in batches]

    @app.get('/api/management/imports/template')
    def template(kind: str, actor=Depends(core.manager)):
        if kind not in {'users', 'questions'}:
            core.fail(422, '模板类型无效')
        if kind == 'questions' and actor['role'] != 'admin':
            core.fail(403, '仅管理员可导入平台题库')
        workbook = Workbook()
        sheet = workbook.active
        sheet.title = '学生账号' if kind == 'users' else '题目'
        headers = USER_HEADERS if kind == 'users' else QUESTION_HEADERS
        sheet.append(headers)
        for cell in sheet[1]:
            font = copy(cell.font)
            font.bold = True
            cell.font = font
        for column in sheet.columns:
            sheet.column_dimensions[column[0].column_letter].number_format = '@'
        sheet.freeze_panes = 'A2'
        # No passwords, personal data or pretend examination questions in templates.
        buffer = io.BytesIO()
        workbook.save(buffer)
        workbook.close()
        return {'filename': kind + '-template.xlsx', 'content_base64': base64.b64encode(buffer.getvalue()).decode('ascii')}

    @app.post('/api/management/imports/parse')
    def parse_upload(data: dict = Body(...), actor=Depends(core.manager)):
        kind = data.get('kind')
        if kind == 'questions' and actor['role'] != 'admin':
            core.fail(403, '仅管理员可导入平台题库')
        parsed = parse_workbook(data.get('content_base64'), kind)
        # Parsed passwords are returned only to the authenticated operator; never audited/logged.
        return {'rows': parsed}

    @app.post('/api/management/questions/import')
    def import_questions(data: dict = Body(...), actor=Depends(core.admin)):
        incoming = data.get('rows')
        if not isinstance(incoming, list) or not 1 <= len(incoming) <= 500:
            core.fail(422, '每次须导入1至500行')
        errors, normalized = [], []
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            for index, row in enumerate(incoming, 1):
                if not isinstance(row, dict):
                    errors.append({'row': index, 'message': '行格式错误'})
                    continue
                item = {**row, 'status': 'published'}
                try:
                    from .bank_classification import normalize_question_scope
                    item = normalize_question_scope(conn, core, item)
                    core.validate_question(conn, item)
                    normalized.append(item)
                except HTTPException as error:
                    errors.append({'row': index, 'message': str(error.detail)})
            if errors:
                conn.rollback()
                return {'created': 0, 'errors': errors, 'batch_id': None}
            from .word_import import content_hash
            known = {content_hash(core, core.question_public(question)) for question in core.rows(conn, 'SELECT * FROM questions')}
            known.update(row['content_hash'] for row in core.rows(conn, 'SELECT content_hash FROM word_import_items'))
            identifiers, duplicates = [], 0
            for item in normalized:
                fingerprint = content_hash(core, item)
                if fingerprint in known:
                    duplicates += 1
                    continue
                known.add(fingerprint)
                identifier = core.uid()
                identifiers.append(identifier)
                conn.execute('INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,status,creator_id,reviewer_id,created_at,updated_at,media) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', (identifier, item['subject_id'], item['knowledge_id'], item['type'], item['stem'], core.canonical(item['options']), core.canonical(item['answer']), item['explanation'], item['difficulty'], item['source'], item['authorization'], 'published', actor['id'], None, core.iso(), core.iso(), core.canonical(item.get('media',{}))))
            batch_id = None
            if identifiers:
                batch_id = core.uid()
                conn.execute('INSERT INTO question_import_batches VALUES(?,?,?,?,?)', (batch_id, actor['id'], core.canonical(identifiers), 'imported', core.iso()))
                release = core.publish_bank(conn, actor['id'])
            else:
                version, bank = core.current_bank(conn)
                release = {'version': version, 'count': len(bank)}
            core.audit(conn, actor['id'], 'questions.import', batch_id or '', f'{len(identifiers)} published questions; {duplicates} duplicates')
            return {'created': len(identifiers), 'duplicates': duplicates, 'errors': [], 'batch_id': batch_id, **release}

    @app.post('/api/management/questions/import/{batch_id}/rollback')
    def rollback_questions(batch_id: str, actor=Depends(core.admin)):
        with core.db() as conn:
            conn.execute('BEGIN IMMEDIATE')
            batch = core.one(conn, 'SELECT * FROM question_import_batches WHERE id=?', (batch_id,))
            if not batch:
                core.fail(404, '导入批次不存在')
            if batch['status'] == 'rolled_back':
                version, bank = core.current_bank(conn)
                return {'rolled_back': 0, 'version': version, 'count': len(bank)}
            identifiers = set(json.loads(batch['question_ids']))
            for identifier in identifiers:
                question = core.one(conn, 'SELECT * FROM questions WHERE id=?', (identifier,))
                if question and question['status'] != 'deleted' and question['creator_id'] != batch['creator_id']:
                    core.fail(409, '批次题目已被其他管理员编辑，请在题库中逐题处理')
            changed = 0
            for identifier in identifiers:
                changed += conn.execute("UPDATE questions SET status='deleted',updated_at=? WHERE id=? AND status<>'deleted'", (core.iso(), identifier)).rowcount
            conn.execute("UPDATE question_import_batches SET status='rolled_back' WHERE id=?", (batch_id,))
            core.audit(conn, actor['id'], 'questions.import.rollback', batch_id)
            if changed:
                release = core.publish_bank(conn, actor['id'])
            else:
                version, bank = core.current_bank(conn)
                release = {'version': version, 'count': len(bank)}
            return {'rolled_back': changed, **release}

    @app.get('/api/management/users/{user_id}/details')
    def user_details(user_id: str, reason: str = Query(..., min_length=4, max_length=500), actor=Depends(core.admin)):
        if len(reason.strip()) < 4:
            core.fail(422, '请填写至少4字的访问原因')
        with core.db() as conn:
            target = core.user_scope(conn, user_id, actor)
            core.audit(conn, actor['id'], 'user.personal_details.view', user_id, reason.strip())
            stats = core.one(conn, 'SELECT COUNT(*) answered,COALESCE(SUM(correct),0) correct,COALESCE(SUM(duration_seconds),0) study_seconds FROM records WHERE user_id=?', (user_id,))
            stats['accuracy'] = round(stats['correct'] * 100 / stats['answered'], 1) if stats['answered'] else 0
            records = core.rows(conn, 'SELECT r.question_id,q.stem,r.question_snapshot,r.selected,r.correct,r.answered_at,r.duration_seconds FROM records r JOIN questions q ON q.id=r.question_id WHERE r.user_id=? ORDER BY r.answered_at DESC LIMIT 100', (user_id,))
            for item in records:
                snapshot = json.loads(item.pop('question_snapshot') or '{}')
                item['stem'] = snapshot.get('stem', item['stem'])
                item['selected'] = json.loads(item['selected'])
                item['correct'] = bool(item['correct'])
            return {'user': core.public_user(target), 'stats': stats, 'subjects': core.subject_stats(conn, target) if target['role'] == 'student' else [], 'records': records, 'classes': core.classes_for_student(conn, target) if target['role'] == 'student' else []}

    @app.post('/api/management/users/{user_id}/force-logout')
    def force_logout(user_id: str, actor=Depends(core.admin)):
        with core.db() as conn:
            core.user_scope(conn, user_id, actor)
            conn.execute('UPDATE sessions SET revoked=1 WHERE user_id=?', (user_id,))
            core.audit(conn, actor['id'], 'user.force_logout', user_id)
        return {'ok': True}
