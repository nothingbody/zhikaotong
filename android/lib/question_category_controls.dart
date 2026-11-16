import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import 'core.dart';
import 'ios_theme.dart';

String categoryTypeSummary(Json category) {
  final counts = category['by_type'];
  if (counts is! Map) return '进入后选择练习题型';
  const names = {'single': '单选', 'multiple': '多选', 'judge': '判断', 'fill': '填空'};
  final values = <String>[];
  for (final item in names.entries) {
    final value = counts[item.key];
    if (value is num && value > 0) values.add('${item.value} ${value.toInt()}');
  }
  return values.isEmpty ? '暂无已发布题目' : values.join(' · ');
}

/// A content category is separate from single/multiple/judge/fill answer types.
/// Labels and counts come from the current visible school subject catalog.
class QuestionCategoryTile extends StatelessWidget {
  final Json category;
  final int index;
  final VoidCallback? onTap;

  const QuestionCategoryTile({
    super.key,
    required this.category,
    required this.index,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final count = category['total'];
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        key: ValueKey('content-category-${category['id']}'),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
          child: Row(
            children: [
              Container(
                width: 37,
                height: 37,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: index.isEven ? iosTint : iosWarmTint,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  (index + 1).toString().padLeft(2, '0'),
                  style: TextStyle(
                    color: index.isEven ? iosBlue : iosAmber,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      category['name']?.toString() ?? '综合练习',
                      style: const TextStyle(
                        color: iosInk,
                        fontWeight: FontWeight.w600,
                        fontSize: 15,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Text(
                      categoryTypeSummary(category),
                      style: const TextStyle(
                        fontSize: 11,
                        color: iosSecondary,
                        height: 1.45,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    count is num ? '${count.toInt()}题' : '学校题库',
                    style: const TextStyle(
                      color: iosBlue,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Icon(
                    CupertinoIcons.chevron_right,
                    size: 12,
                    color: iosSecondary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
