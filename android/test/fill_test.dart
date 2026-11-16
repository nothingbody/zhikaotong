import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

class FillStore extends LocalStore {
  final values = <String, dynamic>{};
  Completer<void>? gate;
  @override
  Future<dynamic> read(String key) async => values[key];
  @override
  Future<void> write(String key, dynamic value) async {
    await gate?.future;
    values[key] = jsonDecode(jsonEncode(value));
  }
}

Json fillQuestion({String id = 'fill-1'}) => {
  'id': id,
  'version': 2,
  'type': 'fill',
  'stem': '请按顺序填写两种加工方法：____、____。',
  'options': [],
  'answer': [
    ['车削', 'TURNING'],
    ['钻孔', 'DRILLING'],
  ],
  'explanation': '第一空为车削，第二空为钻孔。',
  'source': '测试题',
};

void main() {
  test('fill scoring preserves blank order and explicit synonyms', () {
    final question = fillQuestion();
    expect(scoreQuestion(question, ['车削', '钻孔']), isTrue);
    expect(scoreQuestion(question, ['  ｔｕｒｎｉｎｇ　', '\u00a0DRILLING ']), isTrue);
    expect(scoreQuestion(question, ['钻孔', '车削']), isFalse);
    expect(scoreQuestion(question, ['车削', '']), isFalse);
    expect(scoreQuestion(question, ['车削']), isFalse);
    expect(scoreQuestion(question, ['车削', '钻孔', '其他']), isFalse);
    expect(
      scoreQuestion(
        {
          ...question,
          'answer': [
            ['A'],
            ['A'],
          ],
        },
        ['A', 'A'],
      ),
      isTrue,
    );
    expect(
      scoreQuestion(
        {
          ...question,
          'answer': [
            ['A'],
            ['A'],
          ],
        },
        ['A'],
      ),
      isFalse,
    );
    expect(normalizeFillAnswer('  ＣＮＣ\t\n机床　'), 'cnc 机床');
  });

  test(
    'fill outbox persists ordered duplicate answers and draft atomically',
    () async {
      final store = FillStore();
      final state = AppState(store)
        ..user = {'id': 'student-fill', 'activated': false};
      final question = {
        ...fillQuestion(),
        'answer': [
          ['相同'],
          ['相同'],
        ],
      };
      await state.record(
        question,
        ['相同', '相同'],
        7,
        practiceState: {
          'cursor': 0,
          'answers': {
            '0': ['相同', '相同'],
          },
          'submitted': [0],
        },
      );
      final restarted = AppState(store)
        ..user = {'id': 'student-fill', 'activated': false};
      await restarted.loadLocal();
      expect(restarted.queue.single['selected'], ['相同', '相同']);
      expect(restarted.queue.single['question_version'], 2);
      expect(restarted.practice!['answers']['0'], ['相同', '相同']);
      expect(restarted.practice!['submitted'], [0]);
      expect(
        restarted.queue.single['client_uuid'],
        state.queue.single['client_uuid'],
      );
      state.dispose();
      restarted.dispose();
    },
  );

  testWidgets(
    'fill drafts resume without exposing accepted answers before submission',
    (tester) async {
      final store = FillStore();
      final state = AppState(store)
        ..user = {'id': 'student-fill', 'activated': false};
      final question = fillQuestion();
      await tester.pumpWidget(
        MaterialApp(
          home: PracticePage(
            state: state,
            questions: [question],
            resume: {
              'cursor': 0,
              'answers': {
                '0': ['车削', ''],
              },
              'submitted': [],
            },
          ),
        ),
      );
      expect(find.text('正确答案：'), findsNothing);
      expect(find.textContaining('TURNING'), findsNothing);
      final inputs = find.byType(TextFormField);
      expect(inputs, findsNWidgets(2));
      expect(tester.widget<TextFormField>(inputs.at(0)).initialValue, '车削');
      await tester.enterText(inputs.at(1), '钻孔');
      await tester.pump();
      expect(state.practice!['answers']['0'], ['车削', '钻孔']);
      await tester.ensureVisible(find.text('提交答案'));
      await tester.tap(find.text('提交答案'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.queue.single['selected'], ['车削', '钻孔']);
      expect(
        scoreQuestion(
          question,
          List<String>.from(state.queue.single['selected']),
        ),
        isTrue,
      );
      expect(state.practice!['submitted'], [0]);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'fill submission freezes fields and navigation until durable save',
    (tester) async {
      final store = FillStore();
      final state = AppState(store)
        ..user = {'id': 'student-fill', 'activated': false};
      await tester.pumpWidget(
        MaterialApp(
          home: PracticePage(
            state: state,
            questions: [
              fillQuestion(),
              fillQuestion(id: 'fill-2'),
            ],
            resume: {
              'cursor': 1,
              'answers': {
                '1': ['车削', '钻孔'],
              },
              'submitted': [],
            },
          ),
        ),
      );
      store.gate = Completer<void>();
      await tester.ensureVisible(find.text('提交答案'));
      await tester.tap(find.text('提交答案'));
      await tester.pump();
      final card = tester.widget<IconButton>(
        find.ancestor(
          of: find.byTooltip('答题卡'),
          matching: find.byType(IconButton),
        ),
      );
      expect(card.onPressed, isNull);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '上一题'))
            .onPressed,
        isNull,
      );
      expect(
        tester.widget<TextFormField>(find.byType(TextFormField).first).enabled,
        isFalse,
      );
      store.gate!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(state.queue.single['question_id'], 'fill-2');
      expect(state.queue.single['selected'], ['车削', '钻孔']);
      expect(state.practice!['submitted'], [1]);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
