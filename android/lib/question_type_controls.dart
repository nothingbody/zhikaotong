import 'package:flutter/material.dart';

import 'ios_theme.dart';

String questionTypeLabel(String? type) =>
    const {
      'single': '单选题',
      'multiple': '多选题',
      'judge': '判断题',
      'fill': '填空题',
    }[type] ??
    '综合练习';

/// Visible choices keep single and multiple practice one tap apart.
class QuestionTypeSelector extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  final Map<String, int>? counts;

  const QuestionTypeSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.counts,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(
        '练习题型',
        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          for (final type in <String?>[
            'single',
            'multiple',
            'judge',
            'fill',
            null,
          ])
            ChoiceChip(
              key: ValueKey('practice-type-${type ?? 'all'}'),
              label: Text(
                counts == null
                    ? questionTypeLabel(type)
                    : '${questionTypeLabel(type)} · ${type == null ? counts!.values.fold<int>(0, (sum, count) => sum + count) : counts![type] ?? 0}',
              ),
              selected: value == type,
              onSelected: (_) => onChanged(type),
            ),
        ],
      ),
      const SizedBox(height: 6),
      const Text(
        '按题型分别练习，单选与多选的续练进度各自保存。',
        style: TextStyle(fontSize: 12, height: 1.5, color: iosSecondary),
      ),
    ],
  );
}

/// Rules sit before the stem so a student knows how many choices may be made.
class QuestionTypeGuidance extends StatelessWidget {
  final String type;
  final bool showTitle;

  const QuestionTypeGuidance({
    super.key,
    required this.type,
    this.showTitle = true,
  });

  String get rule => switch (type) {
    'single' => '请选择 1 个答案，选好后提交。',
    'multiple' => '可选择多个答案，选好后提交；漏选、错选均不得分。',
    'judge' => '请选择正确或错误，选好后提交。',
    'fill' => '请按空格顺序填写答案，全部空格正确才计为答对。',
    _ => '请完成本题后提交答案。',
  };

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 11),
    decoration: BoxDecoration(
      color: type == 'multiple' ? iosWarmTint : iosTint,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          switch (type) {
            'multiple' => Icons.check_box_outlined,
            'fill' => Icons.edit_note,
            'judge' => Icons.rule,
            _ => Icons.radio_button_checked,
          },
          color: iosBlue,
          size: 20,
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (showTitle) ...[
                Text(
                  questionTypeLabel(type),
                  style: const TextStyle(
                    fontSize: 14,
                    color: iosInk,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
              ],
              Text(
                rule,
                style: const TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: iosInk,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

/// Multiple answers use a square check control; single answers stay circular.
class QuestionOptionMarker extends StatelessWidget {
  final String label;
  final bool multiple;
  final bool selected;
  final Color color;

  const QuestionOptionMarker({
    super.key,
    required this.label,
    required this.multiple,
    required this.selected,
    this.color = iosBlue,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    label: '选项$label',
    checked: multiple ? selected : null,
    selected: multiple ? null : selected,
    inMutuallyExclusiveGroup: !multiple,
    child: ExcludeSemantics(
      child: Container(
        width: 30,
        height: 30,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? color : iosBackground,
          shape: multiple ? BoxShape.rectangle : BoxShape.circle,
          borderRadius: multiple ? BorderRadius.circular(7) : null,
          border: Border.all(color: selected ? color : iosLine),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : color,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    ),
  );
}
