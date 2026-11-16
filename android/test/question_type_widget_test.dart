import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/question_type_controls.dart';
import 'package:zhikaotong/teaching.dart';

import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

Json typeQuestion(String type, {String? id}) => {
  'id': id ?? 'question-$type',
  'version': 3,
  'subject_id': 'math',
  'type': type,
  'stem': type == 'multiple' ? '请选择所有符合条件的选项。' : '请选择一个符合条件的选项。',
  'options': [
    {'key': 'A', 'text': '选项甲'},
    {'key': 'B', 'text': '选项乙'},
    {'key': 'C', 'text': '选项丙'},
  ],
  'answer': type == 'multiple' ? ['A', 'B'] : ['B'],
  'source': '临时测试题库',
  'explanation': '原资料未提供解析。',
  'score': 2,
};

Json typeProgress(String type) => {
  'questions': [typeQuestion(type)],
  'mode': 'all',
  'subject_id': 'math',
  'question_type': type,
  'session_id': 'saved-$type',
  'cursor': 0,
  'answers': {
    '0': type == 'multiple' ? ['A', 'B'] : ['B'],
  },
  'submitted': <int>[],
  'durations': {'0': 6},
};

http.Response ok(dynamic value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class TypePracticeState extends AppState {
  TypePracticeState(
    UiPreviewStore storage,
    Future<http.Response> Function(http.Request) handler,
  ) : super(
        storage,
        Api(storage, client: MockClient(handler))..consented = true,
      ) {
    user = {'id': 'type-test-student', 'role': 'student', 'activated': false};
    subjects = [
      {
        'id': 'math',
        'name': '数学',
        'total': 2,
        'by_type': {'single': 1, 'multiple': 1, 'judge': 0, 'fill': 0},
      },
    ];
  }

  @override
  Future<void> reload() async {}
}

Future<void> clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> configure(WidgetTester tester) =>
    tap(tester, find.text('开始本科目练习'));

void main() {
  setUpAll(preview.loadPreviewFonts);

  testWidgets('ordinary practice defaults to a separate single-choice pool', (
    tester,
  ) async {
    final requests = <Uri>[];
    final state = TypePracticeState(UiPreviewStore(), (request) async {
      requests.add(request.url);
      return ok({
        'questions': [typeQuestion(request.url.queryParameters['type']!)],
        'version': 3,
        'pool_hash': List.filled(64, 'a').join(),
        'seed': List.filled(32, 'b').join(),
        'offset': 0,
        'next_offset': 1,
        'has_more': false,
        'total': 1,
      });
    });
    await preview.mountPage(
      tester,
      SubjectPage(state: state, subject: state.subjects.single),
    );
    await configure(tester);
    expect(
      tester
          .widget<ChoiceChip>(
            find.byKey(const ValueKey('practice-type-single')),
          )
          .selected,
      isTrue,
    );
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('practice-type-all')))
          .selected,
      isFalse,
    );
    await tap(tester, find.text('进入练习'));
    expect(requests.single.queryParameters['type'], 'single');
    expect(state.practice!['question_type'], 'single');
    expect(
      (state.practice!['questions'] as List).every(
        (q) => q['type'] == 'single',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await clean(tester, state);
  });

  testWidgets(
    'type entry shows all choices and trusted counts on narrow large text',
    (tester) async {
      final requests = <Uri>[];
      final state = TypePracticeState(UiPreviewStore(), (request) async {
        requests.add(request.url);
        return ok([]);
      });
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: state.subjects.single),
        width: 320,
        height: 700,
        scale: 1.5,
      );
      await configure(tester);
      for (final type in ['all', 'single', 'multiple', 'judge', 'fill']) {
        expect(find.byKey(ValueKey('practice-type-$type')), findsOneWidget);
      }
      expect(find.text('单选题 · 1'), findsOneWidget);
      expect(find.text('多选题 · 1'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      await tap(tester, find.byKey(const ValueKey('practice-type-multiple')));
      expect(
        tester
            .widget<ChoiceChip>(
              find.byKey(const ValueKey('practice-type-multiple')),
            )
            .selected,
        isTrue,
      );
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await preview.capture(tester, 'question-types-settings-320-large-0.8.3');
      await clean(tester, state);
    },
  );

  for (final continuous in [false, true]) {
    testWidgets(
      'typed ${continuous ? 'continuous' : 'finite'} entry fetches only selected type',
      (tester) async {
        final requests = <Uri>[];
        final state = TypePracticeState(UiPreviewStore(), (request) async {
          requests.add(request.url);
          final type = request.url.queryParameters['type']!;
          if (request.url.path.endsWith('/continuous')) {
            return ok({
              'questions': [typeQuestion(type)],
              'version': 3,
              'pool_hash': List.filled(64, 'a').join(),
              'seed': List.filled(32, 'b').join(),
              'offset': 0,
              'next_offset': 1,
              'has_more': false,
              'total': 1,
            });
          }
          return ok([typeQuestion(type)]);
        });
        await preview.mountPage(
          tester,
          SubjectPage(state: state, subject: state.subjects.single),
        );
        await configure(tester);
        await tap(tester, find.byKey(const ValueKey('practice-type-multiple')));
        if (!continuous) await tap(tester, find.text('持续刷题'));
        await tap(tester, find.text('进入练习'));
        expect(find.byType(PracticePage), findsOneWidget);
        expect(requests, hasLength(1));
        expect(requests.single.queryParameters['type'], 'multiple');
        expect(
          requests.single.path,
          continuous ? '/api/questions/continuous' : '/api/questions',
        );
        expect(state.practice!['question_type'], 'multiple');
        expect(AppState.practiceScope(state.practice!), 'all:math:multiple');
        expect(
          (state.practice!['questions'] as List).every(
            (q) => q['type'] == 'multiple',
          ),
          isTrue,
        );
        expect(find.text('可选择多个答案，选好后提交；漏选、错选均不得分。'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await clean(tester, state);
      },
    );
  }

  testWidgets(
    'selected type resumes its own slot without fetching or replacing another type',
    (tester) async {
      final requests = <Uri>[];
      final state = TypePracticeState(UiPreviewStore(), (request) async {
        requests.add(request.url);
        return ok([]);
      });
      await state.activatePractice(typeProgress('single'));
      await state.activatePractice(typeProgress('multiple'));
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: state.subjects.single),
      );
      await configure(tester);
      expect(find.text('继续已保存的练习？'), findsNothing);
      await tap(tester, find.byKey(const ValueKey('practice-type-single')));
      await tap(tester, find.text('进入练习'));
      expect(find.text('继续已保存的练习？'), findsOneWidget);
      expect(find.textContaining('单选题的进度已保留'), findsOneWidget);
      await tap(tester, find.widgetWithText(CupertinoDialogAction, '继续练习'));
      expect(find.byType(PracticePage), findsOneWidget);
      expect(state.practice!['question_type'], 'single');
      expect(state.practice!['session_id'], 'saved-single');
      expect(state.practice!['answers'], {
        '0': ['B'],
      });
      expect(state.savedPractice('math', type: 'multiple')!['answers'], {
        '0': ['A', 'B'],
      });
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  for (final type in ['single', 'multiple']) {
    testWidgets(
      '$type options expose distinct controls and submit the selected answers',
      (tester) async {
        final state = TypePracticeState(UiPreviewStore(), (_) async => ok([]));
        await preview.mountPage(
          tester,
          PracticePage(
            state: state,
            questions: [typeQuestion(type)],
            questionType: type,
          ),
          width: 320,
          height: 700,
          scale: 1.3,
        );
        expect(find.text(questionTypeLabel(type)), findsOneWidget);
        await tap(tester, find.text('选项甲'));
        await tap(tester, find.text('选项乙'));
        final markers = tester
            .widgetList<QuestionOptionMarker>(find.byType(QuestionOptionMarker))
            .toList();
        expect(
          markers.every((marker) => marker.multiple == (type == 'multiple')),
          isTrue,
        );
        expect(
          markers
              .where((marker) => marker.selected)
              .map((marker) => marker.label)
              .toList(),
          type == 'multiple' ? ['A', 'B'] : ['B'],
        );
        expect(state.queue, isEmpty);
        await tap(tester, find.text('提交答案'));
        expect(state.queue, hasLength(1));
        expect(
          state.queue.single['selected'],
          type == 'multiple' ? ['A', 'B'] : ['B'],
        );
        expect(state.practice!['question_type'], type);
        expect(state.practice!['submitted'], [0]);
        expect(find.text('回答正确，继续保持'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await preview.capture(tester, 'question-type-$type-320-0.8.3');
        await clean(tester, state);
      },
    );
  }

  testWidgets(
    'teacher assignment and local wrong review both identify multiple choices',
    (tester) async {
      final store = UiPreviewStore();
      final requests = <String>[];
      final question = typeQuestion('multiple');
      final state = TypePracticeState(store, (request) async {
        requests.add('${request.method} ${request.url.path}');
        final publicQuestion = {...question}
          ..remove('answer')
          ..remove('explanation');
        return ok({
          'id': 'type-task',
          'paper_title': '多选课堂练习',
          'class_name': '测试班',
          'question_count': 1,
          'full_score': 2,
          'submitted': false,
          'result': null,
          'questions': [publicQuestion],
        });
      });
      await preview.mountPage(
        tester,
        AssignmentAttemptPage(state: state, assignmentId: 'type-task'),
      );
      expect(find.text('可选择多个答案，选好后提交；漏选、错选均不得分。'), findsOneWidget);
      await tap(tester, find.text('选项甲'));
      await tap(tester, find.text('选项乙'));
      final draft = store.values['assignment_${state.cacheKey}_type-task'];
      expect(draft['answers'][question['id']], ['A', 'B']);
      expect(requests, ['GET /api/student/assignments/type-task']);
      expect(state.queue, isEmpty);
      await preview.mountPage(
        tester,
        AssignmentWrongReviewPage(title: '原卷复习', questions: [question]),
      );
      expect(find.text('多选题'), findsOneWidget);
      await tap(tester, find.text('选项甲'));
      await tap(tester, find.text('选项乙'));
      await tap(tester, find.text('检查答案'));
      expect(find.text('本次复习答对了'), findsOneWidget);
      expect(requests, ['GET /api/student/assignments/type-task']);
      expect(state.queue, isEmpty);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );
}
