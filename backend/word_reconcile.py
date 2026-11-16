"""Repair source-backed Word imports without replacing historical question IDs."""
import hashlib
import json
from collections import Counter, defaultdict

from .bank_classification import default_knowledge
from .word_import import content_hash, subject_mapping


CONTENT_FIELDS = ('subject_id', 'knowledge_id', 'type', 'stem', 'options', 'answer', 'explanation', 'difficulty', 'source', 'authorization', 'media')


def reconcile_word(conn, core, parsed, actor_id, authorization, *, execute=False):
    """A dry run rolls back even default-node creation; execution is one transaction."""
    if not conn.in_transaction:
        conn.execute('BEGIN IMMEDIATE')
    conn.execute('SAVEPOINT word_source_reconcile')
    completed = False
    try:
        result = _reconcile(conn, core, parsed, actor_id, authorization, execute)
        completed = True
        return result
    finally:
        if not execute or not completed:
            conn.execute('ROLLBACK TO word_source_reconcile')
        conn.execute('RELEASE word_source_reconcile')


def _reconcile(conn, core, parsed, actor_id, authorization, execute):
    digest = parsed.get('document_sha256')
    if not isinstance(digest, str) or len(digest) != 64:
        core.fail(422, '原Word校验信息无效')
    if not isinstance(authorization, str) or not 2 <= len(authorization.strip()) <= 1000:
        core.fail(422, '请保留真实来源与校内使用记录')
    candidates = parsed.get('questions', [])
    if not candidates or len(candidates) > 5000 or any(not item.get('eligible') for item in candidates):
        core.fail(422, '核对计划仍有未完整识别题目，不能整体补齐')
    if len({item['source_key'] for item in candidates}) != len(candidates):
        core.fail(422, '原题来源标识重复')
    sources = {item['source_key']: item for item in core.rows(conn, 'SELECT * FROM word_import_items WHERE document_hash=?', (digest,))}
    all_sources = {item['source_key']:item['document_hash'] for item in core.rows(conn,'SELECT source_key,document_hash FROM word_import_items')}
    if any(item['source_key'] in all_sources and all_sources[item['source_key']] != digest for item in candidates):
        core.fail(409,'原题来源标识已属于其他文档，拒绝覆盖')
    missing = set(sources) - {item['source_key'] for item in candidates}
    if missing:
        core.fail(409, '新识别结果遗漏已有来源，拒绝覆盖原题')
    known_ids = {item['question_id'] for item in sources.values()}
    manual = {item['question_id'] for item in core.rows(conn, 'SELECT question_id FROM question_classification_overrides')}
    edited = {item['target'] for item in core.rows(conn, "SELECT DISTINCT target FROM audit WHERE action='question.update'")}
    if known_ids & (manual | edited):
        core.fail(409, '原导入题目存在管理员手动修订，请先逐题核对，不能自动覆盖')
    mapping = subject_mapping(conn, core)
    groups = defaultdict(list)
    for candidate in candidates:
        subject_id = mapping.get(candidate.get('subject_hint'))
        if not subject_id:
            core.fail(422, '原Word科目缺少可靠对应关系')
        item = {'subject_id': subject_id, 'type': candidate['type'], 'stem': candidate['stem'],
                'options': candidate['options'], 'answer': candidate['answer'], 'media': candidate.get('media', {}),
                'source': candidate['source'], 'explanation': candidate.get('explanation') or '原资料未提供解析。',
                'difficulty': candidate.get('difficulty', 1), 'authorization': authorization.strip()}
        groups[content_hash(core, item)].append((candidate, item))
    operations, assigned, created_ids = [], {}, []
    reused_ids = set()
    by_subject, by_type = Counter(), Counter()
    for fingerprint, members in groups.items():
        previous_ids = {sources[candidate['source_key']]['question_id'] for candidate, _ in members if candidate['source_key'] in sources}
        if len(previous_ids) > 1:
            core.fail(409, '新识别把多个已有题目合并，需明确处理旧身份后再修复')
        previous = None
        if previous_ids:
            identifier = next(iter(previous_ids))
            if identifier in reused_ids:
                core.fail(409, '同一旧题的不同来源现识别为不同题目，需先拆分身份')
            reused_ids.add(identifier)
            previous = core.one(conn, 'SELECT * FROM questions WHERE id=?', (identifier,))
            if not previous:
                core.fail(409, '原题目关系不完整')
        else:
            identifier = hashlib.sha256(('word-source-reconcile-v1:' + digest + ':' + fingerprint).encode()).hexdigest()[:32]
            if core.one(conn, 'SELECT id FROM questions WHERE id=?', (identifier,)):
                core.fail(409, '新题目编号已被其他数据使用')
            created_ids.append(identifier)
        candidate, item = members[0]
        item = dict(item)
        if previous:
            if previous['subject_id'] != item['subject_id']:
                core.fail(409, '原题目科目已有变化，不能擅自改回')
            item['knowledge_id'] = previous['knowledge_id']
            item['authorization'] = previous['authorization']
            item['difficulty'] = previous['difficulty']
            item['source'] = previous['source']
        else:
            item['knowledge_id'] = default_knowledge(conn, core, item['subject_id'])
        item['status'] = previous['status'] if previous else 'published'
        # Validation does not reactivate an intentionally withdrawn question.
        validated = {**item, 'status': 'published'}
        core.validate_question(conn, validated)
        item['media'] = validated['media']
        changed = previous is None
        if previous:
            for field in CONTENT_FIELDS:
                old = previous.get(field, '{}')
                if field in ('options', 'answer', 'media') and isinstance(old, str):
                    old = json.loads(old)
                if old != item[field]:
                    changed = True
                    break
        operations.append((identifier, previous, item, changed))
        by_subject[candidate['subject_hint']] += 1
        by_type[item['type']] += 1
        for source_candidate, _ in members:
            assigned[source_candidate['source_key']] = (identifier, fingerprint)
    if reused_ids != known_ids:
        core.fail(409, '补齐计划未保留所有原题编号')
    updated = sum(previous is not None and changed for _, previous, _, changed in operations)
    result = {'execute': execute, 'document_sha256': digest, 'source_occurrences': len(candidates), 'unique_questions': len(groups),
              'duplicate_occurrences': len(candidates) - len(groups), 'existing_questions_preserved': len(reused_ids),
              'created': len(created_ids), 'updated': updated, 'sources_before': len(sources), 'sources_after': len(assigned),
              'by_subject': dict(by_subject), 'by_type': dict(by_type), 'media_questions': sum(bool(item['media']) for _, _, item, _ in operations)}
    if not execute:
        return result
    stamp = core.iso()
    for identifier, previous, item, changed in operations:
        if not changed:
            continue
        values = (item['subject_id'], item['knowledge_id'], item['type'], item['stem'], core.canonical(item['options']), core.canonical(item['answer']), item['explanation'], item['difficulty'], item['source'], item['authorization'], core.canonical(item['media']))
        if previous:
            conn.execute('UPDATE questions SET subject_id=?,knowledge_id=?,type=?,stem=?,options=?,answer=?,explanation=?,difficulty=?,source=?,authorization=?,media=?,updated_at=? WHERE id=?', (*values, stamp, identifier))
        else:
            conn.execute('INSERT INTO questions(id,subject_id,knowledge_id,type,stem,options,answer,explanation,difficulty,source,authorization,media,status,creator_id,reviewer_id,created_at,updated_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)', (identifier, *values, item['status'], actor_id, None, stamp, stamp))
    for key, (identifier, fingerprint) in assigned.items():
        conn.execute('INSERT INTO word_import_items(source_key,document_hash,question_id,content_hash) VALUES(?,?,?,?) ON CONFLICT(source_key) DO UPDATE SET content_hash=excluded.content_hash', (key, digest, identifier, fingerprint))
    if created_ids:
        batch_id = core.uid()
        conn.execute('INSERT INTO question_import_batches VALUES(?,?,?,?,?)', (batch_id, actor_id, core.canonical(created_ids), 'imported', stamp))
        core.audit(conn, actor_id, 'word.import', batch_id, f'原文核对补齐{len(created_ids)}题，修复{updated}道已有题；原题编号与历史作答保留')
        result['batch_id'] = batch_id
    if created_ids or updated:
        result.update(core.publish_bank(conn, actor_id))
        core.audit(conn, actor_id, 'word.reconcile', digest, core.canonical({key: result[key] for key in ('source_occurrences', 'unique_questions', 'created', 'updated', 'duplicate_occurrences')}))
    else:
        version, bank = core.current_bank(conn)
        result.update(version=version, count=len(bank))
    return result
