"""Source-backed content categories, overlaid without rewriting bank releases.

The provenance section is a category only when its complete heading matches a
known heading. Stems, filenames and substrings never guess a curriculum topic.
"""
import re
import unicodedata

CATEGORY_RULES_VERSION = 1
TYPES = ('single', 'multiple', 'judge', 'fill')
ENGLISH = (
    ('phonetics', '语音辨析'), ('image-text', '图文理解'),
    ('conversation', '交际用语'), ('vocabulary-grammar', '词汇与语法'),
    ('cloze', '完形填空'), ('reading', '阅读理解'), ('writing', '书面表达'),
)
CHINESE = (
    ('language', '基础知识与语言运用'), ('reading', '阅读理解'),
    ('classical-reading', '古代诗文阅读'), ('classical-memory', '古代诗文默写'),
)
GENERAL = ('general', '综合练习')
_IDENTIFIER = re.compile(r'^[a-z0-9][a-z0-9-]{0,63}$')


def _family(subject_id, subject_name=''):
    name = unicodedata.normalize('NFKC', str(subject_name)).strip()
    if subject_id == 'english' or name == '英语':
        return ENGLISH
    if subject_id == 'chinese' or name == '语文':
        return CHINESE
    return ()


def _heading(value):
    value = unicodedata.normalize('NFKC', value).strip()
    value = re.sub(r'^[一二三四五六七八九十百0-9]+[、.．]\s*', '', value)
    return re.split(r'[（(]', value, maxsplit=1)[0].strip().rstrip('：:')


def category_for(question, subject_name=''):
    """Return a stable category scoped to the question's own subject."""
    family = _family(question.get('subject_id'), subject_name)
    canonical = dict((*family, GENERAL))
    explicit_id, explicit_name = question.get('category_id'), question.get('category_name')
    if (isinstance(explicit_id, str) and _IDENTIFIER.fullmatch(explicit_id)
            and isinstance(explicit_name, str) and 1 <= len(explicit_name.strip()) <= 80
            and not any(unicodedata.category(char).startswith('C') for char in explicit_name)):
        return explicit_id, canonical.get(explicit_id, explicit_name.strip())
    if not family:
        return GENERAL
    aliases = {name: identifier for identifier, name in family}
    if family == ENGLISH:
        aliases.update({'语音': 'phonetics', '交际对话': 'conversation'})
    elif family == CHINESE:
        aliases['基础知识及语言运用'] = 'language'
    source = question.get('source')
    if not isinstance(source, str):
        return GENERAL
    matches = {aliases[heading] for segment in re.split(r'[·|｜]', source)
               if (heading := _heading(segment)) in aliases}
    if len(matches) != 1:
        return GENERAL
    identifier = matches.pop()
    return identifier, canonical[identifier]


def annotate_questions(questions, subject_names=None):
    names = subject_names or {}
    result = []
    for question in questions:
        identifier, name = category_for(question, names.get(question.get('subject_id'), ''))
        result.append({**question, 'category_id': identifier, 'category_name': name})
    return result


def category_catalog(questions, subject_id, subject_name=''):
    counts = {}
    for question in questions:
        if question.get('subject_id') != subject_id:
            continue
        identifier, name = category_for(question, subject_name)
        current = counts.setdefault(identifier, {'id': identifier, 'name': name, 'total': 0,
                                                'by_type': dict.fromkeys(TYPES, 0)})
        current['total'] += 1
        if question.get('type') in current['by_type']:
            current['by_type'][question['type']] += 1
    preferred = [identifier for identifier, _ in (*_family(subject_id, subject_name), GENERAL)]
    return sorted(counts.values(), key=lambda item: (preferred.index(item['id'])
                  if item['id'] in preferred else len(preferred), item['name'], item['id']))


def filter_category(core, questions, subject_id, category_id):
    if category_id in (None, ''):
        return questions
    if not isinstance(category_id, str) or not _IDENTIFIER.fullmatch(category_id):
        core.fail(422, '内容分类标识无效')
    if not subject_id:
        core.fail(422, '请先选择科目，再选择内容分类')
    if not any(question['subject_id'] == subject_id and question.get('category_id') == category_id
               for question in questions):
        core.fail(404, '本科目暂无该内容分类，请刷新分类列表')
    return [question for question in questions
            if question['subject_id'] == subject_id and question.get('category_id') == category_id]
