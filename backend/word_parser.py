"""Bounded, deterministic DOCX question recognition; no OCR or invented answers.

Selection, fill and judgment questions become preview rows. Diagrams, legacy equations,
missing answers and ambiguous material are explicit review blockers.
"""
from __future__ import annotations

import hashlib
import io
import re
import unicodedata
import zipfile
from dataclasses import dataclass, field
from xml.etree import ElementTree as ET

W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
M = 'http://schemas.openxmlformats.org/officeDocument/2006/math'
NS = {'w': W, 'm': M}
MAX_FILE_BYTES = 20 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 100 * 1024 * 1024
MAX_XML_BYTES = 20 * 1024 * 1024
MAX_PARAGRAPHS = 30000
NUMBER = re.compile(r'^\s*(\d{1,4})\s*[.．、]\s*(.*)$', re.S)
OPTION = re.compile(r'(?:([A-JＡ-Ｊ])\s*[.．、)）]|[（(]([A-JＡ-Ｊ])[）)])')
ANSWER_MARKER = re.compile(r'(?:参考答案|正确答案|答案|(?<![\u4e00-\u9fff])答)\s*[：:]')
EXPLANATION = re.compile(r'(?:答案解析|参考解析|解析|解答)\s*[：:]')
PAPER = re.compile(r'《([^》]+)》\s*(?:练习卷|试卷|测试卷)\s*[（(]\s*(\d+)\s*[）)]')
SECTION = re.compile(r'^(?:第[ⅠⅡⅢIVX一二三四五六七八九十0-9]+卷\s*|[一二三四五六七八九十]+\s*[、.．]\s*)')
MATERIAL_MARKER = re.compile(r'^[（(][一二三四五六七八九十0-9]+[）)]$')
ENGLISH_SECTIONS = {'语音辨析', '图文理解', '交际用语', '词汇与语法', '完形填空', '阅读理解', '书面表达'}
SUBJECTS = {'语文': 'chinese', '数学': 'math', '英语': 'english', '思想政治': 'politics', '政治': 'politics', '专业理论': 'mechanics', '专业综合': 'mechanics', '机械基础': 'mechanics', '机械专业综合理论': 'mechanics', '机械专业': 'mechanics', '机械制图': 'mechanics', '电工基础': 'mechanics', '机械': 'mechanics'}
DRAWING_HEADING = re.compile(r'(?:绘图题|作图题|画图题|补图题|绘制题|机械绘制|补画.*视图|补全.*视图|绘制.*三视图|(?:视图|零件图|装配图|投影图).{0,8}(?:绘制|补全|补画))')
JUDGE_HEADING = re.compile(r'(?:判断题|是非题|判断正误|正误判断|true\s*(?:or|/|and)\s*false|true[- ]false)', re.I)
OTHER_HEADING = re.compile(r'(?:解答题|计算题|简答题|问答题|论述题|识图题|写作|作文|书面表达|综合实践)')
BLANK = re.compile(r'_{2,}|＿{2,}|﹏{2,}|\[\s*\]|【\s*】|[（(][ \u3000]+[）)]')
SOURCE_OPTION_LABEL_FIXES = {}


class WordParseError(ValueError):
    """A safe user-facing validation error."""


def _local(tag):
    return tag.rsplit('}', 1)[-1]


def _xml(raw):
    if len(raw) > MAX_XML_BYTES:
        raise WordParseError('Word XML体积过大')
    normalized = raw.replace(b'\x00', b'').upper()
    if b'<!DOCTYPE' in normalized or b'<!ENTITY' in normalized:
        raise WordParseError('不支持包含DTD或实体声明的Word文档')
    try:
        tree = ET.fromstring(raw)
    except ET.ParseError:
        raise WordParseError('Word XML内容损坏') from None
    pending = [(tree, 0)]
    count = 0
    while pending:
        node, depth = pending.pop()
        count += 1
        if depth > 128 or count > 600000:
            raise WordParseError('Word结构过于复杂')
        pending.extend((child, depth + 1) for child in node)
    return tree


@dataclass
class Block:
    index: int
    text: str
    style: str = ''
    image_count: int = 0
    formula_count: int = 0
    formatted: bool = False
    rows: list[list[str]] | None = None
    paragraphs: list['Block'] = field(default_factory=list)
    source_suffix: str = ''
    shared_material: str = ''
    shared_images: int = 0
    shared_formulas: int = 0
    exercise_number: str = ''
    forced_kind: str = ''


def _paragraph(node, index, styles, media_context=None):
    images, formulas, formatted = 0, 0, False

    def render(element):
        nonlocal images, formulas, formatted
        name = _local(element.tag)
        if name in {'del', 'delText', 'instrText'}:
            return ''
        if name in {'drawing', 'pict', 'object'}:
            if media_context is not None:
                rendered = media_context.render_element(element)
                if rendered is not None:
                    return rendered
            images += 1
            if name == 'object':
                formulas += 1
            return '〔图片或旧公式待核对〕'
        if element.tag == '{' + M + '}oMath':
            formulas += 1
            text = ''.join(part.text or '' for part in element.iter() if _local(part.tag) == 't')
            return '〔公式：' + text + '〕'
        if name in {'t', 'tab', 'br', 'cr'}:
            return element.text or '' if name == 't' else ('\t' if name == 'tab' else '\n')
        value = ''.join(render(child) for child in element)
        if name == 'r':
            properties = element.find('w:rPr', NS)
            underline = properties.find('w:u', NS) if properties is not None else None
            emphasis = properties.find('w:em', NS) if properties is not None else None
            marked = underline is not None and underline.get('{' + W + '}val', 'single') not in {'none', '0', 'false'}
            if marked and value and not value.strip():
                return '____'
            if (marked or emphasis is not None) and value.strip():
                formatted = True
                return '【' + value + '】'
        return value

    text = render(node).replace('\u00a0', ' ').strip()
    style = node.find('w:pPr/w:pStyle', NS)
    style_name = styles.get(style.get('{' + W + '}val'), '') if style is not None else ''
    return Block(index, text, style_name, images, formulas, formatted)


def _read_blocks(raw, media_context=None):
    if not isinstance(raw, bytes) or not raw or len(raw) > MAX_FILE_BYTES:
        raise WordParseError('Word文件须为非空DOCX，大小不超过20MB')
    try:
        archive = zipfile.ZipFile(io.BytesIO(raw))
    except zipfile.BadZipFile:
        raise WordParseError('请选择有效的.docx文件，旧版.doc不受支持') from None
    with archive:
        members = archive.infolist()
        names = [item.filename for item in members]
        if len(members) > 10000 or len(names) != len(set(names)) or sum(item.file_size for item in members) > MAX_UNCOMPRESSED_BYTES:
            raise WordParseError('Word压缩包过大或包含重复条目')
        if any(item.flag_bits & 1 for item in members):
            raise WordParseError('不支持加密Word文档')
        if any('vbaproject' in name.lower() for name in names):
            raise WordParseError('不支持含宏的Word文档')
        if 'word/document.xml' not in names:
            raise WordParseError('文件不是有效的Word文档')
        try:
            tree = _xml(archive.read('word/document.xml'))
            style_tree = _xml(archive.read('word/styles.xml')) if 'word/styles.xml' in names else None
        except (RuntimeError, zipfile.BadZipFile, OSError):
            raise WordParseError('Word压缩数据损坏') from None
        styles = {}
        if style_tree is not None:
            for style in style_tree.findall('w:style', NS):
                label = style.find('w:name', NS)
                styles[style.get('{' + W + '}styleId')] = label.get('{' + W + '}val', '') if label is not None else ''
        body = tree.find('w:body', NS)
        if body is None:
            raise WordParseError('Word正文为空')
        index = 0
        blocks = []

        def walk(container):
            nonlocal index
            for node in container:
                name = _local(node.tag)
                if name == 'p':
                    block = _paragraph(node, index, styles, media_context)
                    index += 1
                    blocks.append(block)
                elif name == 'tbl':
                    table_index = index
                    table_rows, paragraphs = [], []
                    for row in node.findall('w:tr', NS):
                        cells = []
                        for cell in row.findall('w:tc', NS):
                            cell_text = []
                            for paragraph in cell.findall('.//w:p', NS):
                                block = _paragraph(paragraph, index, styles, media_context)
                                index += 1
                                paragraphs.append(block)
                                cell_text.append(block.text)
                            cells.append('\n'.join(cell_text).strip())
                        table_rows.append(cells)
                    blocks.append(Block(table_index, '\n'.join('\t'.join(row) for row in table_rows), image_count=sum(p.image_count for p in paragraphs), formula_count=sum(p.formula_count for p in paragraphs), formatted=any(p.formatted for p in paragraphs), rows=table_rows, paragraphs=paragraphs))
                elif name in {'sdt', 'sdtContent', 'customXml', 'ins'}:
                    walk(node)
                if index > MAX_PARAGRAPHS:
                    raise WordParseError('Word段落过多，每次最多30000段')
        walk(body)
        return blocks, {'paragraphs': len(tree.findall('.//w:p', NS)), 'indexed_paragraphs': index, 'tables': sum(block.rows is not None for block in blocks), 'media_files': sum(name.startswith('word/media/') for name in names)}


def _choice_answer(text):
    text = unicodedata.normalize('NFKC', text).strip().upper()
    text = re.sub(r'[。．.；;]+$', '', text).strip()
    if re.fullmatch(r'[A-J](?:[\s、,，/|;；]*[A-J])*', text):
        values = re.findall(r'[A-J]', text)
        if len(values) == len(set(values)):
            return values
    return []


def _judge_answer(text, *, allow_numeric=False, allow_letters=False, section=''):
    """Map only explicit answer tokens; never decide a statement's truth."""
    value = unicodedata.normalize('NFKC', text).strip().lower()
    value = re.sub(r'[。．.；;]+$', '', value).strip()
    if len(value) >= 2 and (value[0], value[-1]) in {('(', ')'), ('【', '】'), ('[', ']')}:
        value = value[1:-1].strip()
    truth = {'正确', '对', '√', '✓', '✔', 'true', '是'}
    falsehood = {'错误', '错', '×', '✕', '✗', 'false', '否'}
    if value in truth:
        return ['A']
    if value in falsehood:
        return ['B']
    if allow_letters:
        if value in {'t', 'f'}:
            return ['A' if value == 't' else 'B']
        if value in {'a', 'b'}:
            # Some schools reverse their source labels. The stored options always
            # use A=correct and B=incorrect, so honor a stated source mapping.
            true_letter = re.search(r'正确(?:的)?\s*(?:选|选择|记为|用)\s*([AB])', section, re.I)
            false_letter = re.search(r'错误(?:的)?\s*(?:选|选择|记为|用)\s*([AB])', section, re.I)
            if true_letter and false_letter:
                if true_letter.group(1).lower() == false_letter.group(1).lower():
                    return []
                return ['A' if value == true_letter.group(1).lower() else 'B']
            return ['A' if value == 'a' else 'B']
    if allow_numeric and value in {'1', '0'}:
        return ['A' if value == '1' else 'B']
    return []


def _subject_heading(text):
    """Recognize a standalone subject heading, not a keyword inside a question."""
    value = unicodedata.normalize('NFKC', text).strip()
    if len(value) > 80:
        return None
    value = re.sub(r'^(?:第[一二三四五六七八九十0-9]+(?:部分|章|篇|科)|[一二三四五六七八九十]+[、.]|\d{1,2}[、.])\s*', '', value)
    for label in sorted(SUBJECTS, key=len, reverse=True):
        if re.fullmatch(r'《?' + re.escape(label) + r'》?(?:\s*(?:题库|试题|题目|部分|科目|练习|测试))?', value):
            return SUBJECTS[label]
    return None


def _table_answers(block):
    result = {}
    table_rows = block.rows or []
    for index, row in enumerate(table_rows[:-1]):
        if not row or row[0].strip() not in {'题号', '题 号', '序号'}:
            continue
        answer_row = table_rows[index + 1]
        if not answer_row or answer_row[0].strip() not in {'答案', '答 案', '参考答案'} or len(row) != len(answer_row):
            continue
        for number, answer in zip(row[1:], answer_row[1:]):
            if re.fullmatch(r'\d{1,4}', number.strip()) and (_choice_answer(answer) or _judge_answer(answer, allow_numeric=True, allow_letters=True)):
                result[number.strip()] = {'text': answer.strip(), 'image_count': 0, 'formula_count': 0}
    return result


def _section_kind(text):
    heading = SECTION.match(text)
    if heading and re.match(r'(?:绘图|画图|作图|补图|补画|绘制|画出)', text[heading.end():]):
        return 'drawing'
    if DRAWING_HEADING.search(text):
        return 'drawing'
    if JUDGE_HEADING.search(text):
        return 'judge'
    if '非选择题' in text:
        return 'other'
    if OTHER_HEADING.search(text):
        return 'other'
    if '填空题' in text or '诗文默写' in text:
        return 'fill'
    if '多项选择' in text or '多选题' in text:
        return 'multiple'
    if '选择题' in text or '单选题' in text or text in ENGLISH_SECTIONS - {'书面表达'}:
        return 'choice'
    if any(word in text for word in ('阅读理解', '古代诗文阅读', '基础知识', '语言运用')):
        return 'choice'
    return None


def _fill_answers(text, count):
    text = text.strip().rstrip('。．')
    if not text or '〔图片或旧公式待核对〕' in text or '〔公式：' in text or '{{img:' in text:
        return []
    parts = [part.strip() for part in re.split(r'[；;]|\t+|\n+|\s{2,}', text) if part.strip()]
    if count > 1 and len(parts) != count:
        parts = [part.strip() for part in re.split(r'[、，,]', text) if part.strip()]
    if count == 1:
        parts = [text]
    if len(parts) != count:
        return []
    return [[part] for part in parts]


def _option_matches(text):
    """Prefer an actual A-option line over A、B、C、D in an instruction."""
    raw_matches = list(OPTION.finditer(text))
    matches = []
    for match in raw_matches:
        if match.start() and text[match.start() - 1].isalnum():
            continue
        label = unicodedata.normalize('NFKC', match.group(1) or match.group(2))
        if matches and match.start() == matches[-1].end() and label == unicodedata.normalize('NFKC', matches[-1].group(1) or matches[-1].group(2)):
            # A.A. / B.B. in picture questions means the literal A/B option,
            # not an empty repeated option marker.
            continue
        matches.append(match)
    starts = [index for index, match in enumerate(matches)
              if unicodedata.normalize('NFKC', match.group(1) or match.group(2)) == 'A'
              and not text[:match.start()].rsplit('\n', 1)[-1].strip()]
    for start in starts:
        suffix = matches[start:]
        labels = [unicodedata.normalize('NFKC', item.group(1) or item.group(2)) for item in suffix]
        if labels == [chr(65 + index) for index in range(len(labels))] and 2 <= len(labels) <= 10:
            return suffix
    return matches


def _answer_fragments(text):
    markers = list(ANSWER_MARKER.finditer(text))
    values = []
    for index, marker in enumerate(markers):
        end = markers[index + 1].start() if index + 1 < len(markers) else len(text)
        values.append(text[marker.end():end].strip())
    return values


def _shared_options(text):
    matches = _option_matches(text)
    labels = [unicodedata.normalize('NFKC', match.group(1) or match.group(2)) for match in matches]
    if labels != [chr(65 + index) for index in range(len(labels))] or not 2 <= len(labels) <= 10:
        return None
    options = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        value = text[match.end():end].strip()
        if not value:
            return None
        options.append((labels[index], value))
    return text[:matches[0].start()].strip(), options


def _split_child_blocks(blocks, section):
    """Retain paragraph indices; only additional children get an explicit suffix."""
    children = []
    for block in blocks:
        text = block.text
        if section == '完形填空':
            pattern = r'(?<![A-Za-z0-9])(\d{1,2})\s*[.．、]\s*(?=A\s*[.．、])'
        else:
            pattern = r'(?:^|\n)\s*(\d{1,2})\s*[.．、]\s*'
        markers = list(re.finditer(pattern, text))
        implicit_first = section == '完形填空' and not children and markers and re.match(r'^\s*A\s*[.．、]', text[:markers[0].start()])
        if implicit_first:
            children.append({'number': '1', 'index': block.index, 'suffix': '', 'text': text[:markers[0].start()].strip(),
                             'images': block.image_count, 'formulas': block.formula_count, 'formatted': block.formatted})
        if not markers and section == '阅读理解':
            missing = re.match(r'^(\d{1,2})(?=[A-Za-z])(.*)$', text, re.S)
            if missing and int(missing.group(1)) == len(children) + 1 and ANSWER_MARKER.search(text):
                children.append({'number': missing.group(1), 'index': block.index, 'suffix': '', 'text': missing.group(2),
                                 'images': block.image_count, 'formulas': block.formula_count, 'formatted': block.formatted})
                continue
        if not markers and section == '完形填空' and not children and re.match(r'^\s*A\s*[.．、]', text):
            children.append({'number': '1', 'index': block.index, 'suffix': '', 'text': text,
                             'images': block.image_count, 'formulas': block.formula_count, 'formatted': block.formatted})
            continue
        if not markers:
            if children and text.strip():
                children[-1]['text'] += '\n' + text
                children[-1]['images'] += block.image_count
                children[-1]['formulas'] += block.formula_count
                children[-1]['formatted'] |= block.formatted
            continue
        for index, marker in enumerate(markers):
            end = markers[index + 1].start() if index + 1 < len(markers) else len(text)
            children.append({'number': marker.group(1), 'index': block.index,
                             'suffix': '' if index == 0 and not implicit_first else ':part' + str(index + 1 + int(bool(implicit_first))),
                             'text': text[marker.end():end].strip(), 'images': block.image_count,
                             'formulas': block.formula_count, 'formatted': block.formatted})
    return children


def _ordered_group_answers(text, expected=5):
    values = _answer_fragments(text)
    if len(values) == expected and all(len(_choice_answer(value)) == 1 for value in values):
        return [_choice_answer(value)[0] for value in values]
    if len(values) == 1:
        compact = re.fullmatch(r'\s*([A-E]{' + str(expected) + r'})\s*[)）]?\s*', values[0])
        if compact:
            return list(compact.group(1))
    return []


def _expand_five_blank_group(group, section, number):
    combined = '\n'.join(block.text for block in group)
    answers = _ordered_group_answers(combined)
    if len(answers) != 5 or set(answers) != set('ABCDE'):
        return None
    title = NUMBER.sub(lambda match: match.group(2), group[0].text, count=1)
    option_blocks, end = [], 1
    for offset, block in enumerate(group[1:], 1):
        if not block.text.strip():
            continue
        if not re.match(r'^[A-E]\s*[.．、]', block.text):
            break
        option_blocks.append(block.text)
        end = offset + 1
        parsed = _shared_options('\n'.join(option_blocks))
        if parsed and len(parsed[1]) == 5:
            break
    shared = _shared_options('\n'.join(option_blocks)) if option_blocks else None
    images = sum(block.image_count for block in group)
    formulas = sum(block.formula_count for block in group)
    if shared and len(shared[1]) == 5:
        options = shared[1]
        last_key, last_text = options[-1]
        split = re.search(r'\n|【\s*1(?:\s+2|\s*】)', last_text)
        extra = ''
        if split:
            extra = last_text[split.start():].strip()
            options[-1] = (last_key, last_text[:split.start()].strip())
        material = '\n'.join([title, extra] + [block.text for block in group[end:]])
    elif (images or '{{img:' in combined) and section == '书面表达':
        options = [(letter, letter + '（见原文材料）') for letter in 'ABCDE']
        material = NUMBER.sub(lambda match: match.group(2), combined, count=1)
    else:
        return None
    marker = ANSWER_MARKER.search(material)
    if marker:
        material = material[:marker.start()].rstrip(' (（\n')
    result = []
    for position, answer in enumerate(answers, 1):
        source = next((block for block in group[1:] if re.search(r'【\s*' + str(position) + r'\s*】', block.text)), None) if section == '交际用语' else None
        source_index = source.index if source else group[0].index
        suffix = '' if source and sum(bool(re.search(r'【\s*' + str(other) + r'\s*】', source.text)) for other in range(1, 6)) == 1 else ':' + ('dialogue' if section == '交际用语' else 'writing') + str(position)
        text = str(position) + '. 请根据材料，为第' + str(position) + '空选择正确选项。\n'
        text += '\n'.join(key + '. ' + value for key, value in options) + '\n答案：' + answer
        result.append(Block(source_index, text, source_suffix=suffix, shared_material=material.strip(),
                            shared_images=images, shared_formulas=formulas, exercise_number=number, forced_kind='choice'))
    return result


def _expand_english_group(group, section, number):
    """Expand explicit grouped objective exercises without inferring any answer."""
    header = group[0]
    title = NUMBER.sub(lambda match: match.group(2), header.text, count=1)
    if section == '书面表达':
        return _expand_five_blank_group(group, section, number)
    if section == '交际用语' and any(re.search(r'【\s*[1-5]\s*】', block.text) for block in group):
        return _expand_five_blank_group(group, section, number)
    # A shared E-option and the first question can occupy one Word paragraph.
    prepared_group = []
    for offset, block in enumerate(group):
        marker = re.search(r'\n\s*1\s*[.．、]\s*', block.text) if offset else None
        if marker:
            prepared_group.append(Block(block.index, block.text[:marker.start()], image_count=block.image_count, formula_count=block.formula_count, formatted=block.formatted))
            prepared_group.append(Block(block.index, block.text[marker.start():].strip(), formatted=block.formatted))
        else:
            prepared_group.append(block)
    group = prepared_group
    first_child = None
    for index, block in enumerate(group[1:], 1):
        if NUMBER.match(block.text) or section == '完形填空' and re.match(r'^\s*A\s*[.．、]', block.text):
            first_child = index
            break
    if first_child is None:
        return None
    leading = group[:first_child]
    material = '\n'.join([title] + [block.text for block in leading[1:]]).strip()
    shared_images = sum(block.image_count for block in leading)
    shared_formulas = sum(block.formula_count for block in leading)
    children = _split_child_blocks(group[first_child:], section)
    expected = 10 if section == '完形填空' else 5
    if [int(child['number']) for child in children] != list(range(1, expected + 1)):
        return None
    shared = _shared_options(material) if section == '阅读理解' else None
    pool = None
    if shared:
        material, pool = shared
    if section == '交际用语':
        pool = []
        for child in children:
            matches = list(OPTION.finditer(child['text']))
            if len(matches) != 1:
                return None
            marker = matches[0]
            label = unicodedata.normalize('NFKC', marker.group(1) or marker.group(2))
            body = child['text'][marker.end():]
            body = body.split('答案', 1)[0].strip()
            pool.append((label, body))
            child['text'] = child['text'][:marker.start()].strip()
        if [key for key, value in pool] != list('ABCDE') or any(not value for _, value in pool):
            return None
        material = '请为下列话语选择合适的回应。'
    if pool:
        original = '\n'.join(block.text for block in group)
        answers = _answer_fragments(original)
        if len(answers) != expected or any(len(_choice_answer(answer)) != 1 for answer in answers):
            return None
        for child, answer in zip(children, answers):
            child['text'] = ANSWER_MARKER.split(child['text'], maxsplit=1)[0].strip()
            child['text'] += '\n' + '\n'.join(key + '. ' + value for key, value in pool) + '\n答案：' + answer
    result = []
    for child in children:
        content = child['text']
        if section == '完形填空':
            content = '请为材料中第' + child['number'] + '空选择正确答案。\n' + content
        result.append(Block(child['index'], child['number'] + '. ' + content,
                            image_count=child['images'], formula_count=child['formulas'], formatted=child['formatted'],
                            source_suffix=child['suffix'], shared_material=material,
                            shared_images=shared_images, shared_formulas=shared_formulas,
                            exercise_number=number, forced_kind='choice'))
    return result


def _expand_english_groups(blocks):
    result = []
    index = 0
    targets = {'交际用语', '完形填空', '阅读理解', '书面表达'}
    while index < len(blocks):
        block = blocks[index]
        if block.text not in targets:
            result.append(block)
            index += 1
            continue
        section = block.text
        result.append(block)
        index += 1
        section_blocks = []
        while index < len(blocks):
            candidate = blocks[index]
            if candidate.text in ENGLISH_SECTIONS or PAPER.search(candidate.text) and len(candidate.text) < 100:
                break
            # The supplied writing exercises end before an untitled technical bank.
            if section == '书面表达' and section_blocks and re.match(r'^1\s+\.', candidate.text) and any(re.match(r'^\d+\s+\.', item.text) for item in section_blocks):
                break
            section_blocks.append(candidate)
            index += 1
        starts = []
        expected = 1
        for offset, candidate in enumerate(section_blocks):
            match = re.match(r'^\s*(\d{1,3})\s+\.\s*', candidate.text)
            if section == '完形填空' and match is None and len(re.findall(r'【\s*\d+\s*】', candidate.text)) >= 3:
                match = NUMBER.match(candidate.text)
            if match and int(match.group(1)) == expected:
                starts.append(offset)
                expected += 1
        if not starts:
            result.extend(section_blocks)
            continue
        result.extend(section_blocks[:starts[0]])
        for position, start in enumerate(starts):
            end = starts[position + 1] if position + 1 < len(starts) else len(section_blocks)
            original = section_blocks[start:end]
            expanded = _expand_english_group(original, section, str(position + 1))
            result.extend(expanded if expanded is not None else original)
    return result


def parse_docx(raw: bytes, filename: str = '题库.docx', *, preserve_media: bool = False) -> dict:
    """Return preview rows and exclusions. Eligible rows still require import review.

    ``fill`` answers are accepted alternatives per blank, e.g. ``[['力'],['速度']]``.
    The document remains the source of every answer; no semantic guesses are made.
    """
    media_context = None
    if preserve_media:
        from .word_media import load_word_media
        media_context = load_word_media(raw)
    blocks, document_stats = _read_blocks(raw, media_context)
    blocks = _expand_english_groups(blocks)
    filename = str(filename).replace('\\', '/').rsplit('/', 1)[-1][:150] or '题库.docx'
    digest = hashlib.sha256(raw).hexdigest()
    questions, excluded, keys = [], [], {}
    current = None
    subject, section, paper, kind = '', '', '', None
    subject_origin = 'unknown'
    paper_title = ''
    paper_occurrences = {}
    answer_mode = False
    material = []
    material_images = material_formulas = 0
    material_once = False
    last_number = None

    def exclude(label, reason, index, current_section=None):
        excluded.append({'source_index': index, 'source_label': label, 'section': current_section or section, 'reason': reason})

    def finish():
        nonlocal current, material, material_images, material_formulas, subject, section, paper, kind, paper_title, subject_origin
        if current is None:
            return
        record = current
        current = None
        lines = record['lines']
        content, answer_fragments, explanation_lines = [], [], []
        explaining = False
        for line in lines:
            explanation_match = EXPLANATION.search(line)
            if explanation_match:
                explaining = True
                explanation_lines.append(line[explanation_match.end():].strip())
                line = line[:explanation_match.start()].strip()
            if explaining and not line:
                continue
            matches = list(ANSWER_MARKER.finditer(line))
            if matches:
                content.append(line[:matches[0].start()].strip())
                for index, match in enumerate(matches):
                    end = matches[index + 1].start() if index + 1 < len(matches) else len(line)
                    answer_fragments.append(line[match.end():end].strip())
            elif explaining:
                explanation_lines.append(line)
            else:
                content.append(line)
        answer = answer_fragments[0] if len(answer_fragments) == 1 else ''
        combined = '\n'.join(part for part in content if part).strip()
        # A few English reading keys in the source are printed as a Chinese token
        # immediately after a full English sentence, without an answer label.
        # Restrict this to reading context and sentence punctuation, not arbitrary
        # Chinese statements ending in the ordinary word "正确".
        if not answer_fragments and record['subject'] == 'english' and record['section'] == '阅读理解':
            suffix = re.search(r'(?<=[.!?。！？])\s*(正确|错误|对|错)\s*$', combined)
            if suffix and len(re.findall(r'[A-Za-z]', combined[:suffix.start()])) >= 15:
                answer = suffix.group(1)
                answer_fragments = [answer]
                combined = combined[:suffix.start()].strip()
        source_label_normalized = False
        expected_first_option = SOURCE_OPTION_LABEL_FIXES.get(digest, {}).get(record['index'])
        if expected_first_option:
            original_markers = _option_matches(combined)
            original_labels = [unicodedata.normalize('NFKC', marker.group(1) or marker.group(2)) for marker in original_markers]
            if original_labels == ['B', 'C', 'D']:
                parts = combined.splitlines()
                for index, part in enumerate(parts):
                    if ' '.join(part.split()) == expected_first_option:
                        parts[index] = 'A. ' + part
                        source_label_normalized = True
                        break
                combined = '\n'.join(parts)
        option_matches = _option_matches(combined)
        options = []
        option_sequence_valid = True
        if option_matches:
            labels = [unicodedata.normalize('NFKC', match.group(1) or match.group(2)) for match in option_matches]
            # Only a full A,B,... option sequence can classify a question as choice.
            if labels == [chr(65 + n) for n in range(len(labels))] and 2 <= len(labels) <= 10:
                stem = combined[:option_matches[0].start()].strip()
                for index, match in enumerate(option_matches):
                    end = option_matches[index + 1].start() if index + 1 < len(option_matches) else len(combined)
                    options.append({'key': labels[index], 'text': combined[match.end():end].strip()})
            else:
                # Broken option sequences must never be relabelled as fill merely
                # because their sentence contains an underline blank.
                option_sequence_valid = False
                stem = combined[:option_matches[0].start()].strip()
                for index, match in enumerate(option_matches):
                    end = option_matches[index + 1].start() if index + 1 < len(option_matches) else len(combined)
                    options.append({'key': labels[index], 'text': combined[match.end():end].strip()})
        else:
            stem = combined
        number = record['number']
        record_section = record['section']
        record_kind = record['kind']
        record_subject = record['subject']
        record_subject_origin = record['subject_origin']
        judge_context = record_kind == 'judge'
        explicit_judge = _judge_answer(answer, allow_numeric=judge_context, allow_letters=judge_context, section=record_section)
        raw_options_are_judgment = len(options) == 2 and all(_judge_answer(option['text']) for option in options)
        raw_judge_key_map = {option['key']: _judge_answer(option['text']) for option in options} if raw_options_are_judgment else {}
        # Prioritize explicit truth tokens over incidental text like "NBA." or
        # "22μF、250V" that happens to resemble an option label.
        judge_tokens = [_judge_answer(value) for value in answer_fragments]
        is_judge = record_kind != 'fill' and (judge_context or raw_options_are_judgment or (bool(explicit_judge) or any(judge_tokens)) and (not options or not option_sequence_valid))
        if is_judge:
            stem = combined
            if raw_options_are_judgment:
                stem = combined[:option_matches[0].start()].strip()
                if len(answer_fragments) == 1 and not _judge_answer(answer) and re.fullmatch(r'[ABab]', answer.strip()):
                    source_option = next(option for option in options if option['key'] == answer.strip().upper())
                    explicit_judge = _judge_answer(source_option['text'])
            options = [{'key': 'A', 'text': '正确'}, {'key': 'B', 'text': '错误'}]
            option_sequence_valid = True
        if record_kind == 'drawing' or (not options and re.search(r'(?:绘制|补画|画出|绘出|补全).{0,20}(?:图|投影|视图|形体)|^(?:作图|绘图|画图|补图)', stem)):
            exclude(number, '机械绘制或作图题已排除', record['index'], record_section)
            return
        if record_kind == 'other':
            # The supplied bank switches from English writing to an untitled
            # professional question bank. A Chinese A-D question with one explicit
            # answer after that switch is a new objective section, not composition.
            language_stem = re.sub(r'\{\{img:[a-f0-9]+\}\}', '', stem)
            is_professional = record_section == '书面表达' and (options or is_judge) and len(answer_fragments) == 1 and bool(re.search(r'(?:电路|电压|电流|电阻|开关|机械|齿轮|金属|螺纹|轴承|加工|公差|图样|零件)', language_stem)) and len(re.findall(r'[A-Za-z]{3,}', language_stem)) < 3
            if is_professional:
                record_subject = 'mechanics'
                record_section = '专业理论'
                # This is an evidence-backed subject boundary. Keep the following
                # unheaded professional judgment bank out of English as well.
                subject, section, paper, kind, paper_title = 'mechanics', '专业理论', '专业理论', None, ''
                subject_origin = record_subject_origin = 'technical_boundary'
                record['paper_title'] = ''
                record['paper'] = '专业理论'
            else:
                exclude(number, '解答、计算、写作或其他非目标题型已排除', record['index'], record_section)
                return
        # Reading material itself is not a fill or selection question. Preserve
        # it for the next question instead of silently losing the shared passage.
        if not options and record_subject == 'english' and record_section == '阅读理解' and len(stem) > 150 and not answer_fragments:
            material = [stem]
            material_images = record['images']
            material_formulas = record['formulas']
            exclude(number, '阅读材料保留为后续题目的共同材料', record['index'], record_section)
            return
        is_fill = record_kind == 'fill' or bool(BLANK.search(stem)) and not options
        if not options and not is_fill and not is_judge:
            exclude(number, '没有识别到选择选项或填空结构', record['index'], record_section)
            return
        blocked, warnings = [], []
        if source_label_normalized:
            warnings.append('原文首个选项缺A标号，已依据经核对的连续B/C/D结构规范标号；答案仍采用原文明确答案')
        if not option_sequence_valid:
            blocked.append('选项标号缺失、重复或不连续，需人工核对')
        if len(answer_fragments) > 1:
            blocked.append('同一题块出现多段答案，需拆分或人工核对')
        if is_judge:
            qtype = 'judge'
            parsed_answer = explicit_judge if len(answer_fragments) <= 1 else []
        elif options:
            qtype = 'multiple' if record_kind == 'multiple' else 'single'
            parsed_answer = _choice_answer(answer)
            if len(parsed_answer) > 1:
                qtype = 'multiple'
            if any(not item['text'] for item in options):
                blocked.append('选项内容为空或仅包含未识别的公式')
        else:
            qtype = 'fill'
            # Whitespace blanks are only recognized inside an explicit fill section.
            if record_kind == 'fill':
                stem = re.sub(r'[ \u3000]{3,}', '____', stem)
            # Word frequently stores one blank as several underlined runs with a
            # printed triangle in the middle. It is one blank, not two or three.
            stem = re.sub(r'_{2,}(?:\s*【?[▲△]?】?\s*_{2,})+', '____', stem)
            blank_count = len(BLANK.findall(stem))
            if not blank_count:
                blocked.append('未能确定填空位置和空数')
                blank_count = 1
            parsed_answer = _fill_answers(answer, blank_count)
        if not stem.strip():
            blocked.append('题干为空')
        if not record_subject:
            blocked.append('未能可靠识别科目，请人工指定科目')
        images, formulas = record['images'], record['formulas']
        if record['material']:
            stem = '材料：\n' + '\n'.join(record['material']) + '\n\n问题：\n' + stem
            images += record['material_images']
            formulas += record['material_formulas']
        if images:
            blocked.append('包含图片或旧版公式，当前文本题库无法完整保留，需人工补录')
        if formulas:
            blocked.append('包含公式，需人工核对完整表达式')
        if record['formatted']:
            warnings.append('原文下划线或着重号已用【】标记，请核对')
        if record_section in {'图文理解', '阅读理解'} and not record['material'] and not re.search(r'[\u4e00-\u9fffA-Za-z].{100,}', stem, re.S) and not images and '{{img:' not in stem:
            blocked.append('题目依赖阅读或图文材料，但未识别到完整材料')
        if '划线' in stem or '加点' in stem:
            if not record['formatted'] and '【' not in stem and not any('【' in option['text'] for option in options):
                blocked.append('题干依赖划线或加点标记，但未识别到该标记')
        if not answer_fragments:
            key = keys.get((record['paper'], number))
            if key:
                answer = key['text']
                parsed_answer = _fill_answers(answer, blank_count) if qtype == 'fill' else (raw_judge_key_map.get(answer.strip().upper()) or _judge_answer(answer, allow_numeric=True, allow_letters=True, section=record_section)) if qtype == 'judge' else _choice_answer(answer)
        if not parsed_answer:
            blocked.append('缺少可确定的答案')
        if qtype != 'fill' and parsed_answer and not set(parsed_answer).issubset({item['key'] for item in options}):
            blocked.append('答案与选项不匹配')
        source_label = ('第' + record['exercise_number'] + '组' if record.get('exercise_number') else '') + '第' + number + '题'
        media_text = stem + '\n' + '\n'.join(option['text'] for option in options) + '\n' + '\n'.join(explanation_lines)
        questions.append({
            'source_index': record['index'], 'source_label': source_label,
            'source_suffix': record.get('source_suffix', ''),
            'source_key': hashlib.sha256((digest + ':' + str(record['index']) + record.get('source_suffix', '')).encode()).hexdigest(),
            'source_kind': 'docx', 'section': record_section, 'source_section': record_section,
            'paper_title': record['paper_title'],
            'subject_hint': record_subject or 'unknown', 'subject_confidence': record_subject_origin, 'paper_key': record['paper'],
            'type': qtype, 'stem': stem, 'options': options, 'answer': parsed_answer,
            'explanation': '\n'.join(explanation_lines).strip(), 'difficulty': 1,
            'source': filename + ' · ' + (record['paper_title'] + ' · ' if record['paper_title'] else '') + (record_section + ' · ' if record_section else '') + source_label,
            'authorization': '', 'warnings': warnings, 'blocked_reasons': list(dict.fromkeys(blocked)),
            'eligible': not blocked, 'image_count': images, 'formula_count': formulas,
            'media': media_context.media_for_text(media_text) if media_context is not None else {},
            '_number': number, '_raw_answer': answer, '_blank_count': blank_count if qtype == 'fill' else None, '_judge_key_map': raw_judge_key_map,
        })

    for block in blocks:
        text = block.text.strip()
        # Anchored figures can precede the numbered text or even its heading in
        # the same Word paragraph. Preserve their marker in question content.
        prefix = re.match(r'^(?:(?:〔图片或旧公式待核对〕|\{\{img:[a-f0-9]+\}\})\s*)+', text)
        figure_prefix = prefix.group(0) if prefix else ''
        if prefix and (NUMBER.match(text[prefix.end():]) or SECTION.match(text[prefix.end():])):
            text = text[prefix.end():].strip()
        if section == '图文理解' and current is not None and any(ANSWER_MARKER.search(line) for line in current['lines']) and re.fullmatch(r'(?:\s*(?:〔图片或旧公式待核对〕|\{\{img:[a-f0-9]+\}\}))+\s*', text):
            finish()
            material = [text]
            material_images, material_formulas = block.image_count, block.formula_count
            material_once = True
            continue
        if block.style.lower().startswith('toc') or '目录' in block.style:
            continue
        if text in {'江苏省中等职业学校学生学业水平考试', '江苏省学业水平考试'}:
            continue
        title = PAPER.search(text)
        if title and len(text) < 100:
            finish()
            subject = SUBJECTS.get(title.group(1), '')
            subject_origin = 'paper_heading' if subject else 'unknown'
            base_paper = title.group(1) + '-' + title.group(2)
            is_answer_title = bool(re.search(r'答案|评分参考', text[title.end():]))
            if not is_answer_title:
                paper_occurrences[base_paper] = paper_occurrences.get(base_paper, 0) + 1
            paper = base_paper + '#' + str(paper_occurrences.get(base_paper, 1))
            paper_title = title.group(0)
            section = title.group(0)
            answer_mode = is_answer_title
            kind = None
            material = []
            material_images = material_formulas = 0
            last_number = None
            continue
        if text in ENGLISH_SECTIONS or text in {'专业理论', '专业综合', '机械基础'}:
            finish()
            if text in {'阅读理解', '书面表达'}:
                # Shared exercise labels do not override a known Chinese paper
                # or provide enough evidence to infer a new subject by themselves.
                section = text
                if not paper_title:
                    paper = text
            else:
                subject = 'english' if text in ENGLISH_SECTIONS else 'mechanics'
                subject_origin = 'section_heading'
                paper, section = text, text
                paper_title = ''
            answer_mode, kind = False, _section_kind(text)
            material = []
            material_images = material_formulas = 0
            last_number = None
            continue
        standalone_subject = _subject_heading(text)
        if standalone_subject:
            finish()
            subject = standalone_subject
            subject_origin = 'subject_heading'
            paper, section, paper_title = text, text, text
            answer_mode, kind = False, None
            material = []
            material_images = material_formulas = 0
            last_number = None
            continue
        heading_kind = _section_kind(text)
        if heading_kind and (SECTION.match(text) or DRAWING_HEADING.fullmatch(text) or JUDGE_HEADING.fullmatch(text) or re.match(r'^(?:判断题|是非题|判断正误|正误判断)[（(:：]', text) or text in {'单选题', '多选题', '填空题', '判断题', '绘图题', '作图题'}):
            finish()
            kind = heading_kind
            if not answer_mode:
                section = text[:180]
            material = [figure_prefix] if figure_prefix else []
            material_images = block.image_count if figure_prefix else 0
            material_formulas = block.formula_count if figure_prefix else 0
            continue
        if SECTION.match(text) and len(text) <= 200:
            # An unfamiliar next exercise heading is still a boundary. Never append
            # its drawing/calculation instructions to the previous choice option.
            finish()
            kind = 'other'
            if not answer_mode:
                section = text[:180]
            material = []
            material_images = material_formulas = 0
            continue
        if answer_mode:
            if block.rows:
                for number, value in _table_answers(block).items():
                    keys[(paper, number)] = value
            elif kind == 'judge':
                matches = list(re.finditer(r'(\d{1,4})\s*[.．、]', text))
                for index, match in enumerate(matches):
                    end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
                    value = text[match.end():end].strip()
                    if _judge_answer(value, allow_numeric=True, allow_letters=True, section=section):
                        keys[(paper, match.group(1))] = {'text': value, 'image_count': block.image_count, 'formula_count': block.formula_count}
            elif kind in {'choice', 'multiple'} or re.search(r'\d+\s*[.．、]\s*[A-J]', text):
                for match in re.finditer(r'(\d{1,4})\s*[.．、]\s*([A-J](?:[、,，\s]*[A-J])*)(?=\s*\d+\s*[.．、]|\s*$)', text):
                    keys[(paper, match.group(1))] = {'text': match.group(2), 'image_count': block.image_count, 'formula_count': block.formula_count}
            elif kind == 'fill':
                matches = list(re.finditer(r'(\d{1,4})\s*[.．、]', text))
                for index, match in enumerate(matches):
                    end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
                    value = text[match.end():end].strip()
                    if value:
                        keys[(paper, match.group(1))] = {'text': value, 'image_count': block.image_count, 'formula_count': block.formula_count}
            continue
        if MATERIAL_MARKER.fullmatch(text) and (subject == 'chinese' and ('阅读' in section or '诗文' in section)):
            finish()
            material = []
            material_images = material_formulas = 0
            continue
        match = NUMBER.match(text) if block.rows is None else None
        if match is None and block.rows is None and kind == 'fill' and last_number is not None:
            missing_separator = re.match(r'^(\d{1,4})(?=[\u4e00-\u9fff])(.*)$', text, re.S)
            if missing_separator and int(missing_separator.group(1)) == last_number + 1 and BLANK.search(missing_separator.group(2)):
                match = missing_separator
        if match:
            finish()
            number = match.group(1)
            # An unheaded professional bank may follow English composition. Its
            # complete stem and answer, rather than numbering alone, establish
            # that transition when finish() sees the first technical question.
            last_number = int(number)
            current = {'index': block.index, 'number': unicodedata.normalize('NFKC', number), 'lines': [figure_prefix + match.group(2)], 'images': block.image_count, 'formulas': block.formula_count, 'formatted': block.formatted, 'paper': paper, 'paper_title': paper_title, 'subject': subject, 'subject_origin': subject_origin, 'section': section, 'kind': block.forced_kind or kind, 'material': [block.shared_material] if block.shared_material else list(material), 'material_images': block.shared_images if block.shared_material else material_images, 'material_formulas': block.shared_formulas if block.shared_material else material_formulas, 'source_suffix': block.source_suffix, 'exercise_number': block.exercise_number}
            if material_once:
                material = []
                material_images = material_formulas = 0
                material_once = False
            if media_context is not None:
                figures = media_context.figure_tokens_for_question(block.index)
                if figures is None:
                    current['images'] += 1
                elif figures:
                    current['lines'].append(''.join(figures))
        elif current is not None:
            current['lines'].append(text)
            current['images'] += block.image_count
            current['formulas'] += block.formula_count
            current['formatted'] |= block.formatted
        elif text or block.image_count or block.formula_count:
            # Material before the first numbered reading question is shared.
            if subject in {'chinese', 'english'} and ('阅读' in section or '图文' in section or '诗文' in section):
                material.append(text)
                material_images += block.image_count
                material_formulas += block.formula_count
    finish()
    # Answer sections normally occur after question sections. Apply the complete
    # key map only after the document has been read, never guess by nearby number.
    for question in questions:
        if not question['answer']:
            key = keys.get((question['paper_key'], question['_number']))
            if key and not key['image_count'] and not key['formula_count']:
                answer = _fill_answers(key['text'], question['_blank_count']) if question['type'] == 'fill' else (question['_judge_key_map'].get(key['text'].strip().upper()) or _judge_answer(key['text'], allow_numeric=True, allow_letters=True, section=question['section'])) if question['type'] == 'judge' else _choice_answer(key['text'])
                if answer:
                    question['answer'] = answer
                    question['blocked_reasons'] = [reason for reason in question['blocked_reasons'] if reason != '缺少可确定的答案']
                    if question['type'] not in {'fill', 'judge'}:
                        if len(answer) > 1:
                            question['type'] = 'multiple'
                        if not set(answer).issubset({option['key'] for option in question['options']}):
                            question['blocked_reasons'].append('答案与选项不匹配')
                    question['eligible'] = not question['blocked_reasons']
        if not question['answer'] and question['type'] == 'fill' and media_context is not None:
            source_answer = media_context.answer_override(question['source_index'])
            answer = _fill_answers(source_answer, question['_blank_count']) if source_answer is not None else []
            if answer:
                question['answer'] = answer
                question['blocked_reasons'] = [reason for reason in question['blocked_reasons'] if reason != '缺少可确定的答案']
                question['eligible'] = not question['blocked_reasons']
        for field_name in ('_number', '_raw_answer', '_blank_count', 'paper_key', '_judge_key_map'):
            question.pop(field_name, None)
    by_subject = {}
    for question in questions:
        bucket = by_subject.setdefault(question['subject_hint'], {'total': 0, 'eligible': 0, 'single': 0, 'multiple': 0, 'fill': 0, 'judge': 0})
        bucket['total'] += 1
        bucket['eligible'] += int(question['eligible'])
        bucket[question['type']] += 1
    summary = {**document_stats, 'recognized': len(questions), 'eligible': sum(question['eligible'] for question in questions), 'blocked': sum(not question['eligible'] for question in questions), 'excluded': len(excluded), **{qtype: sum(q['type'] == qtype for q in questions) for qtype in ('single', 'multiple', 'fill', 'judge')}, 'by_subject': by_subject}
    return {'questions': questions, 'excluded': excluded, 'summary': summary, 'warnings': ['自动识别选择、填空和判断，并按原文科目标题分科；计算、写作及绘图练习不导入。', '缺答案、科目不明、材料、图片或复杂公式不完整的题目已阻止直接导入，需人工核对。'], 'document_sha256': digest, 'filename': filename}
