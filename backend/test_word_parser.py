"""Synthetic DOCX recognition regressions without private source documents."""
import hashlib
import io
from pathlib import Path
import zipfile
from xml.sax.saxutils import escape

import pytest

from backend.word_parser import parse_docx, WordParseError


def paragraph(text):
    return '<w:p><w:r><w:t xml:space="preserve">' + escape(text) + '</w:t></w:r></w:p>'


def docx(parts, extra=None):
    xml = '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"><w:body>' + ''.join(part if part.startswith('<') else paragraph(part) for part in parts) + '</w:body></w:document>'
    stream = io.BytesIO()
    with zipfile.ZipFile(stream, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('word/document.xml', xml.encode())
        for name, content in (extra or {}).items():
            archive.writestr(name, content)
    return stream.getvalue()


def answer_table(numbers, answers):
    rows = []
    for values in [['题号'] + numbers, ['答案'] + answers]:
        rows.append('<w:tr>' + ''.join('<w:tc>' + paragraph(value) + '</w:tc>' for value in values) + '</w:tr>')
    return '<w:tbl>' + ''.join(rows) + '</w:tbl>'


def test_target_types_only_and_drawing_knowledge_is_retained():
    result = parse_docx(docx([
        '机械专业', '单选题', '1. 公称直径是？', 'A.大径', 'B.小径', '答案：A',
        '多选题', '2. 机械传动有哪些？', 'A.带传动 B.齿轮传动 C.绝缘传动', '答案：A、B',
        '填空题', '3. 力的单位是____，长度的单位是____。', '答案：牛顿；米',
        '判断题', '4. 齿轮可以传递运动。', '答案：正确',
        '绘图题', '5. 请绘制零件的三视图。', '答案：略',
        '单选题', '6. 机械制图中尺寸的默认单位是？', 'A.mm B.cm', '答案：A',
    ]), 'test.docx')
    assert [q['type'] for q in result['questions']] == ['single', 'multiple', 'fill', 'judge', 'single']
    assert all(q['eligible'] for q in result['questions'])
    assert result['questions'][2]['answer'] == [['牛顿'], ['米']]
    assert result['questions'][3]['answer'] == ['A']
    assert result['questions'][3]['options'] == [{'key': 'A', 'text': '正确'}, {'key': 'B', 'text': '错误'}]
    assert result['summary']['excluded'] == 1
    assert any('机械绘制' in item['reason'] for item in result['excluded'])
    assert all(q['source_key'] for q in result['questions'])


def test_separate_keys_are_scoped_to_each_paper_occurrence():
    result = parse_docx(docx([
        '《数学》练习卷（1）', '一、选择题', '1. 第一份题目？', 'A.甲 B.乙',
        '《数学》练习卷（1）答案及评分参考', '一、选择题', answer_table(['1'], ['A']),
        '《数学》练习卷（1）', '一、选择题', '1. 第二份题目？', 'A.甲 B.乙',
        '《数学》练习卷（1）答案及评分参考', '一、选择题', answer_table(['1'], ['B']),
    ]))
    assert [q['answer'] for q in result['questions']] == [['A'], ['B']]
    assert all(q['eligible'] for q in result['questions'])


def test_underlined_fragmented_blanks_and_separate_fill_answers():
    blank = '<w:r><w:rPr><w:u w:val="single"/></w:rPr><w:t xml:space="preserve">    </w:t></w:r>'
    triangle = '<w:r><w:rPr><w:u/></w:rPr><w:t>▲</w:t></w:r>'
    fill = '<w:p><w:r><w:t>1. 力的单位是</w:t></w:r>' + blank + triangle + blank + '<w:r><w:t>，长度单位是____。</w:t></w:r></w:p>'
    result = parse_docx(docx([
        '《机械》练习卷（1）', '一、填空题', fill,
        '《机械》练习卷（1）参考答案', '一、填空题', '1.牛顿\t米',
    ]))
    question = result['questions'][0]
    assert question['stem'] == '力的单位是____，长度单位是____。'
    assert question['answer'] == [['牛顿'], ['米']]
    assert question['eligible']


def test_missing_answers_material_and_images_are_blocked_not_guessed():
    image = '<w:p><w:r><w:drawing/></w:r></w:p>'
    result = parse_docx(docx(['单选题', '1. 如图所示的齿轮是？', image, 'A.甲 B.乙', '答案：A', '填空题', '2. 速度单位是____。']))
    assert len(result['questions']) == 2
    assert not any(q['eligible'] for q in result['questions'])
    assert result['questions'][0]['image_count'] == 1
    assert result['questions'][1]['answer'] == []
    assert '缺少可确定的答案' in result['questions'][1]['blocked_reasons']
    missing_passage = parse_docx(docx(['阅读理解', '1. According to the passage?', 'A.yes B.no', '答案：A']))
    assert not missing_passage['questions'][0]['eligible']


def test_broken_option_letters_never_become_fill_answer_letters():
    result = parse_docx(docx(['词汇与语法', '1. ____ the challenge, we succeeded.', 'Although B.Though C.Despite D.In spite', '答案：C']))
    question = result['questions'][0]
    assert question['type'] == 'single'
    assert not question['eligible']
    assert '选项标号缺失、重复或不连续，需人工核对' in question['blocked_reasons']


def test_drawing_heading_without_ti_suffix_is_a_hard_boundary():
    result = parse_docx(docx(['单选题', '1. 选择单位。', 'A.mm B.cm', '答案：A', '二、画图（10分）', '2. 请画出零件的三视图。', '答案：略']))
    assert len(result['questions']) == 1
    assert result['questions'][0]['options'][1]['text'] == 'cm'
    assert any('机械绘制' in item['reason'] for item in result['excluded'])


def test_reading_passage_and_emphasis_are_preserved():
    marked = '<w:p><w:r><w:t>1. 文中加点字的读音是？</w:t></w:r></w:p>'
    option = '<w:p><w:r><w:t>A.</w:t></w:r><w:r><w:rPr><w:em w:val="dot"/></w:rPr><w:t>甲</w:t></w:r><w:r><w:t> B.乙</w:t></w:r></w:p>'
    result = parse_docx(docx(['《语文》练习卷（1）', '一、阅读理解', '（一）', '这是第一段阅读材料，供下面题目使用。', marked, option, '答案：A', '2. 材料的主题是什么？', 'A.主题甲 B.主题乙', '答案：B']))
    assert len(result['questions']) == 2
    assert all(q['stem'].startswith('材料：\n这是第一段阅读材料') for q in result['questions'])
    assert result['questions'][0]['options'][0]['text'] == '【甲】'
    assert all(q['eligible'] for q in result['questions'])


def test_rejects_invalid_archives_macros_and_xml_entities():
    for raw in [b'not zip', docx([], {'word/vbaProject.bin': b'macro'})]:
        with pytest.raises(WordParseError):
            parse_docx(raw)
    malicious = io.BytesIO()
    with zipfile.ZipFile(malicious, 'w') as archive:
        archive.writestr('word/document.xml', '<!DOCTYPE x [<!ENTITY a "unsafe">]><x>&a;</x>')
    with pytest.raises(WordParseError, match='DTD'):
        parse_docx(malicious.getvalue())
    malformed = io.BytesIO()
    with zipfile.ZipFile(malformed, 'w') as archive:
        archive.writestr('word/document.xml', '<not-closed>')
    with pytest.raises(WordParseError):
        parse_docx(malformed.getvalue())




def test_instruction_letters_and_literal_letter_options_do_not_split_options():
    result = parse_docx(docx(['语音辨析', '1. 从A、B、C、D四个选项中选出划线部分发音不同的一项。',
                              'A.【th】in', 'B.【th】ese', 'C.leng【th】', 'D.【th】rough', '答案：B',
                              '图文理解', '2. Please choose the label described in this complete statement. ' * 3,
                              'A.A.', 'B.B.', 'C.C.', '答案：C']))
    assert len(result['questions']) == 2
    assert all(question['eligible'] for question in result['questions'])
    assert result['questions'][0]['stem'].startswith('从A、B、C、D')
    assert result['questions'][1]['options'] == [{'key': 'A', 'text': 'A.'}, {'key': 'B', 'text': 'B.'}, {'key': 'C', 'text': 'C.'}]


def test_sequential_chinese_fill_without_number_separator_is_recovered():
    result = parse_docx(docx(['《语文》练习卷（3）', '一、填空题', '24. 人生得意____，____千金。',
                              '25是故无贵无贱，____，____。', '《语文》练习卷（3）参考答案', '一、填空题',
                              '24. 须尽欢；散尽还复来', '25. 无长无少；道之所存']))
    assert len(result['questions']) == 2
    assert [question['answer'] for question in result['questions']] == [[['须尽欢'], ['散尽还复来']], [['无长无少'], ['道之所存']]]
    assert len({question['source_key'] for question in result['questions']}) == 2
    assert all(question['eligible'] for question in result['questions'])


def test_cloze_many_children_in_one_paragraph_keep_material_and_distinct_source_keys():
    passage = 'A complete source passage contains ' + ' '.join('【' + str(index) + '】' for index in range(1, 11))
    choices = 'A.first B.second C.third 答案：A  ' + '  '.join(str(index) + '.A.first B.second C.third 答案：B' for index in range(2, 11))
    result = parse_docx(docx(['完形填空', '1 . ' + passage, choices]))
    assert len(result['questions']) == 10
    assert all(question['eligible'] and passage in question['stem'] for question in result['questions'])
    assert [question['answer'] for question in result['questions']] == [['A']] + [['B']] * 9
    assert len({question['source_key'] for question in result['questions']}) == 10
    assert len({question['source_index'] for question in result['questions']}) == 1
    assert result['questions'][0]['source_suffix'] == ''
    assert result['questions'][-1]['source_suffix'] == ':part10'


def test_reading_matching_shares_options_and_splits_an_embedded_first_child():
    result = parse_docx(docx(['英语', '阅读理解', '1 . Match each person with the original alternatives listed below.',
                              'A. First answer', 'B. Second answer', 'C. Third answer', 'D. Fourth answer',
                              'E. Fifth answer\n1. Person one\n2. Person two', '3. Person three', '4. Person four', '5. Person five',
                              '答案：B答案：D答案：A答案：C答案：E']))
    assert len(result['questions']) == 5
    assert all(question['eligible'] and 'Match each person' in question['stem'] for question in result['questions'])
    assert all(len(question['options']) == 5 for question in result['questions'])
    assert result['questions'][0]['options'][-1]['text'] == 'Fifth answer'
    assert [question['answer'] for question in result['questions']] == [[letter] for letter in 'BDACE']
    assert len({question['source_key'] for question in result['questions']}) == 5


def test_dialogue_pairs_and_numbered_blanks_use_explicit_ordered_answers():
    paired = ['交际用语', '1 . I II'] + [str(index) + '. Question ' + str(index) + '       ' + letter + '. Response ' + letter for index, letter in enumerate('ABCDE', 1)] + ['答案：C答案：A答案：E答案：B答案：D']
    blank = ['2 .', 'A. One\nB. Two\nC. Three\nD. Four\nE. Five', 'Speaker: 【1 】', 'Partner: 【2 】', 'Speaker: 【3 】', 'Partner: 【4 】', 'Speaker: 【5 】', '(答案：BAEDC)']
    result = parse_docx(docx(paired + blank))
    assert len(result['questions']) == 10
    assert all(question['eligible'] for question in result['questions'])
    assert [question['answer'] for question in result['questions']] == [[letter] for letter in 'CAEBD'] + [[letter] for letter in 'BAEDC']
    assert all('Speaker' in question['stem'] and len(question['options']) == 5 for question in result['questions'][5:])


def test_ordered_writing_with_given_options_is_objective_not_free_composition():
    result = parse_docx(docx(['英语', '书面表达', '1 . 请用所给句子完成五个位置，顺序为【1 2 3 4 5】。',
                              'A. Sentence A', 'B. Sentence B', 'C. Sentence C', 'D. Sentence D', 'E. Sentence E',
                              '答案：C答案：E答案：B答案：A答案：D']))
    assert len(result['questions']) == 5
    assert all(question['eligible'] and question['type'] == 'single' for question in result['questions'])
    assert [question['answer'] for question in result['questions']] == [[letter] for letter in 'CEBAD']


def test_leading_figure_does_not_merge_the_next_number_into_the_previous_question():
    figure_number = '<w:p><w:r><w:drawing/></w:r><w:r><w:t>2. 如图选择正确值。</w:t></w:r></w:p>'
    result = parse_docx(docx(['数学', '单选题', '1. 请选择数值。', 'A.1 B.2', '答案：A', figure_number, 'A.3 B.4', '答案：B']))
    assert len(result['questions']) == 2
    assert result['questions'][0]['eligible']
    assert not result['questions'][1]['eligible']
    assert '〔图片或旧公式待核对〕' in result['questions'][1]['stem']






@pytest.mark.parametrize('value,expected', [
    ('正确', 'A'), ('错误', 'B'), ('对', 'A'), ('错', 'B'), ('√', 'A'),
    ('×', 'B'), ('true', 'A'), ('false', 'B'), ('T', 'A'), ('F', 'B'),
    ('是', 'A'), ('否', 'B'), ('1', 'A'), ('0', 'B'), ('（√）', 'A'), ('（√）。', 'A'),
])
def test_explicit_judgment_answer_variants(value, expected):
    result = parse_docx(docx(['机械专业', '判断题', '1. 这是需要判断的陈述。', '答案：' + value]))
    question = result['questions'][0]
    assert question['type'] == 'judge'
    assert question['answer'] == [expected]
    assert question['eligible']


def test_judgment_keys_and_reverse_source_labels_are_respected():
    result = parse_docx(docx([
        '《思想政治》练习卷（1）', '一、是非题（正确选B，错误选A）',
        '1. 每个人都应遵守职业道德。', '2. 任何收入都属于职业收入。',
        '《思想政治》练习卷（1）参考答案', '一、是非题（正确选B，错误选A）',
        answer_table(['1', '2'], ['B', 'A']),
    ]))
    assert [q['answer'] for q in result['questions']] == [['A'], ['B']]
    assert all(q['type'] == 'judge' and q['subject_hint'] == 'politics' and q['eligible'] for q in result['questions'])
    inline = parse_docx(docx(['机械专业', '判断题', '1. 陈述甲。', '2. 陈述乙。', '《机械》练习卷（9）']))
    assert all(not q['eligible'] for q in inline['questions'])
    reversed_options = parse_docx(docx([
        '《机械》练习卷（1）', '一、选择题', '1. 电路闭合。', 'A.错误 B.正确',
        '《机械》练习卷（1）答案', '一、选择题', answer_table(['1'], ['A']),
    ]))
    assert reversed_options['questions'][0]['type'] == 'judge'
    assert reversed_options['questions'][0]['answer'] == ['B']
    assert reversed_options['questions'][0]['eligible']
    standalone = parse_docx(docx(['思想政治', '是非题', '1. 陈述甲。', '答案：1', '2. 陈述乙。', '答案：0']))
    assert [q['answer'] for q in standalone['questions']] == [['A'], ['B']]
    english = parse_docx(docx(['英语', 'True or False', '1. A statement.', '答案：F']))
    assert english['questions'][0]['type'] == 'judge'
    assert english['questions'][0]['answer'] == ['B']


def test_numeric_and_boolean_fill_answers_are_not_judgment():
    result = parse_docx(docx([
        '数学', '填空题', '1. 填写数值____。', '答案：1',
        '2. 填写另一个数值____。', '答案：0',
        '英语', '填空题', '3. 填写单词____。', '答案：true',
        '4. 填写字母____。', '答案：T',
        '单选题', '5. 从下面选一项。', 'A.甲 B.乙', '答案：B',
    ]))
    assert [q['type'] for q in result['questions']] == ['fill', 'fill', 'fill', 'fill', 'single']
    assert [q['answer'] for q in result['questions'][:4]] == [[['1']], [['0']], [['true']], [['T']]]
    assert all(q['eligible'] for q in result['questions'])


def test_explicit_truth_token_overrides_incidental_option_letters():
    result = parse_docx(docx([
        '机械专业', '1. 电容规格为22μF、250V。', '答案：错误',
        '英语', '阅读理解', 'This reading material is complete and applies to both statements. ' * 4,
        '1. The player entered the NBA.', '答案：错误',
        '2. The player entered the NBA.正确',
    ]))
    assert [q['type'] for q in result['questions']] == ['judge', 'judge', 'judge']
    assert [q['answer'] for q in result['questions']] == [['B'], ['B'], ['A']]
    assert '22μF、250V' in result['questions'][0]['stem']
    assert 'entered the NBA.' in result['questions'][1]['stem']
    assert all(q['eligible'] for q in result['questions'])


def test_auto_subject_boundaries_and_unknown_subjects_are_not_guessed():
    result = parse_docx(docx([
        '一、语文部分', '单选题', '1. 语文题目。', 'A.甲 B.乙', '答案：A',
        '2、数学', '填空题', '1. 数值是____。', '答案：2',
        '思想政治', '是非题', '1. 职业道德是素养之一。', '答案：对',
        '英语', '书面表达', '2. Write a short letter.', '答案：略',
        '1. 构成电路的条件是？', 'A.闭合 B.断开', '答案：A',
        '2. 电路必须闭合。', '答案：正确',
    ]))
    assert [q['subject_hint'] for q in result['questions']] == ['chinese', 'math', 'politics', 'mechanics', 'mechanics']
    assert all(q['eligible'] for q in result['questions'])
    assert result['questions'][-1]['subject_confidence'] == 'technical_boundary'
    unknown = parse_docx(docx(['单选题', '1. 未标明科目的题目。', 'A.甲 B.乙', '答案：A']), 'unknown.docx')
    assert unknown['questions'][0]['subject_hint'] == 'unknown'
    assert not unknown['questions'][0]['eligible']
    assert '未能可靠识别科目，请人工指定科目' in unknown['questions'][0]['blocked_reasons']


def test_shared_reading_label_keeps_chinese_subject_and_unknown_does_not_become_english():
    chinese = parse_docx(docx(['《语文》练习卷（1）', '阅读理解', '阅读材料。' * 30, '1. 主题是？', 'A.甲 B.乙', '答案：A']))
    assert chinese['questions'][0]['subject_hint'] == 'chinese'
    assert chinese['questions'][0]['eligible']
    unknown = parse_docx(docx(['阅读理解', 'Reading material. ' * 20, '1. Statement.', '答案：正确']))
    assert unknown['questions'][0]['subject_hint'] == 'unknown'
    assert not unknown['questions'][0]['eligible']
