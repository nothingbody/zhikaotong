import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

class DelayedStore extends LocalStore {
  final gate = Completer<void>();
  Json? snapshot;
  @override
  Future<void> write(String key, dynamic value) async {
    await gate.future;
    snapshot = Map<String, dynamic>.from(value);
  }
}

void main() {
  testWidgets(
    'navigation is disabled while a captured answer is durably saved',
    (tester) async {
      final store = DelayedStore();
      final state = AppState(store)..user = {'id': 's1', 'activated': false};
      final questions = List.generate(
        2,
        (i) => <String, dynamic>{
          'id': 'q$i',
          'version': 'v1',
          'type': 'single',
          'stem': '题目${i + 1}',
          'options': [
            {'key': 'A', 'text': '选项甲'},
            {'key': 'B', 'text': '选项乙'},
          ],
          'answer': ['A'],
          'explanation': '示例解析',
          'source': '示例',
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PracticePage(
            state: state,
            questions: questions,
            resume: {'cursor': 1},
          ),
        ),
      );
      await tester.tap(find.text('选项甲'));
      await tester.pump();
      await tester.ensureVisible(find.text('提交答案'));
      await tester.tap(find.text('提交答案'));
      await tester.pump();
      final card = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('答题卡'),
          matching: find.byType(IconButton),
        ),
      );
      final previous = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '上一题'),
      );
      expect(card.onPressed, isNull);
      expect(previous.onPressed, isNull);
      store.gate.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.queue.single['question_id'], 'q1');
      expect(store.snapshot!['practice']['submitted'], [1]);
      expect(store.snapshot!['queue'].single['question_id'], 'q1');
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
