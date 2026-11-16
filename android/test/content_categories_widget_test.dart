import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

Map<String, int> counts(int single, [int judge = 0]) => {
  'single': single,
  'multiple': 0,
  'judge': judge,
  'fill': 0,
};

List<Json> englishCategories() => [
  {'id': 'phonetics', 'name': '语音辨析', 'total': 31, 'by_type': counts(31)},
  {'id': 'image-text', 'name': '图文理解', 'total': 32, 'by_type': counts(32)},
  {'id': 'conversation', 'name': '交际用语', 'total': 120, 'by_type': counts(120)},
  {
    'id': 'vocabulary-grammar',
    'name': '词汇与语法',
    'total': 120,
    'by_type': counts(120),
  },
  {'id': 'cloze', 'name': '完形填空', 'total': 80, 'by_type': counts(80)},
  {'id': 'reading', 'name': '阅读理解', 'total': 240, 'by_type': counts(160, 80)},
  {'id': 'writing', 'name': '书面表达', 'total': 40, 'by_type': counts(40)},
];

Json question({String category = 'reading', String type = 'single'}) => {
  'id': 'category-$category-$type',
  'version': 5,
  'subject_id': 'english',
  'category_id': category,
  'category_name': '阅读理解',
  'type': type,
  'stem': 'Read the passage and choose the correct answer.',
  'options': [
    {'key': 'A', 'text': type == 'judge' ? '正确' : 'At school'},
    {'key': 'B', 'text': type == 'judge' ? '错误' : 'At home'},
  ],
  'answer': ['A'],
  'difficulty': 1,
  'source': '隔离界面验收数据',
  'explanation': '原资料未提供解析。',
};

http.Response ok(dynamic data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

class CategoryState extends AppState {
  CategoryState({String group = 'mechanics', List<Uri>? requests})
    : this._(UiPreviewStore(), group, requests);
  CategoryState._(UiPreviewStore storage, String group, List<Uri>? requests)
    : super(
        storage,
        Api(
          storage,
          client: MockClient((request) async {
            requests?.add(request.url);
            if (request.url.path.endsWith('/questions/continuous')) {
              final category =
                  request.url.queryParameters['category_id'] ?? 'general';
              final type = request.url.queryParameters['type'] ?? 'single';
              final offset =
                  int.tryParse(request.url.queryParameters['offset'] ?? '') ??
                  0;
              return ok({
                'questions': [
                  {
                    ...question(category: category, type: type),
                    'id': 'batch-$offset-$category-$type',
                  },
                ],
                'version': 5,
                'pool_hash': List.filled(64, 'a').join(),
                'seed': '0123456789abcdef0123456789abcdef',
                'offset': offset,
                'next_offset': offset + 1,
                'has_more': false,
                'total': offset + 1,
              });
            }
            if (request.url.path.endsWith('/questions')) {
              return ok([
                question(
                  category:
                      request.url.queryParameters['category_id'] ?? 'general',
                  type: request.url.queryParameters['type'] ?? 'single',
                ),
              ]);
            }
            return ok([]);
          }),
        )..consented = true,
      ) {
    ready = true;
    user = {
      'id': 'isolated-category-student',
      'role': 'student',
      'activated': true,
      'name': '分类验收',
      'subject_group_id': group,
      'must_change_password': false,
      'consent_version': 'draft-1',
    };
    config = {'agreement_version': 'draft-1', 'exam_start': '2027-04-17'};
    dashboard = {
      'stats': {'answered': 0, 'today_answered': 0, 'today_goal': 20},
    };
    subjects = [
      {
        'id': 'english',
        'name': '英语',
        'total': 663,
        'by_type': counts(583, 80),
        'categories': englishCategories(),
      },
      {
        'id': 'computer-network',
        'name': '计算机网络技术',
        'total': 119,
        'by_type': counts(60, 59),
        'categories': [
          {
            'id': 'general',
            'name': '综合练习',
            'total': 119,
            'by_type': counts(60, 59),
          },
        ],
      },
    ];
  }
  @override
  Future<void> reload() async {}
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
  tester.view.resetPadding();
  tester.view.resetViewPadding();
  tester.platformDispatcher.clearTextScaleFactorTestValue();
}

void main() {
  setUpAll(preview.loadPreviewFonts);

  for (final group in ['mechanics', 'computer']) {
    testWidgets(
      '$group students see the same seven public English categories',
      (tester) async {
        final state = CategoryState(group: group);
        await preview.mountPage(
          tester,
          SubjectPage(state: state, subject: state.subjects.first),
        );
        expect(find.text('663道题 · 7个分类'), findsOneWidget);
        expect(find.text('31题'), findsOneWidget);
        expect(find.text('全部题目练习'), findsOneWidget);
        expect(find.textContaining('知识点'), findsNothing);
        expect(find.textContaining('待归类'), findsNothing);
        if (group == 'mechanics')
          await preview.capture(tester, 'content-categories-english-390-0.8.5');
        for (final category in englishCategories()) {
          final tile = find.byKey(
            ValueKey('content-category-${category['id']}'),
          );
          await tester.scrollUntilVisible(tile, 160);
          expect(tile, findsOneWidget);
          expect(find.text(category['name']), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        await clean(tester, state);
      },
    );
  }

  testWidgets(
    'reading category uses its own type counts and sends finite or continuous category scope',
    (tester) async {
      final requests = <Uri>[];
      final state = CategoryState(requests: requests);
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: state.subjects.first),
      );
      await tap(tester, find.byKey(const ValueKey('content-category-reading')));
      expect(find.text('单选题 · 160'), findsOneWidget);
      expect(find.text('判断题 · 80'), findsOneWidget);
      await tap(tester, find.byKey(const ValueKey('practice-type-judge')));
      await tap(tester, find.text('进入练习'));
      expect(find.byType(PracticePage), findsOneWidget);
      expect(requests.single.queryParameters['subject_id'], 'english');
      expect(requests.single.queryParameters['category_id'], 'reading');
      expect(requests.single.queryParameters['type'], 'judge');
      expect(state.practice!['category_id'], 'reading');
      expect((state.practice!['stream'] as Map)['category_id'], 'reading');
      expect(state.practice!['category_name'], '阅读理解');
      expect(find.text('阅读理解'), findsOneWidget);
      expect(
        state.savedPractice('english', categoryId: 'reading', type: 'judge'),
        isNotNull,
      );
      expect(
        state.savedPractice('english', categoryId: 'cloze', type: 'judge'),
        isNull,
      );
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets(
    'a named category finite session and the all-content entry preserve distinct scopes',
    (tester) async {
      final requests = <Uri>[];
      final state = CategoryState(requests: requests);
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: state.subjects.first),
      );
      await tap(tester, find.byKey(const ValueKey('content-category-cloze')));
      await tap(tester, find.text('持续刷题'));
      await tap(tester, find.text('进入练习'));
      expect(requests.single.path, '/api/questions');
      expect(requests.single.queryParameters['category_id'], 'cloze');
      expect(state.practice!['category_id'], 'cloze');
      expect(
        (state.practice!['questions'] as List).single['category_id'],
        'cloze',
      );
      expect(state.savedPractice('english', type: 'single'), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('all-content-practice')),
        -160,
      );
      await tap(tester, find.byKey(const ValueKey('all-content-practice')));
      await tap(tester, find.text('进入练习'));
      expect(requests, hasLength(2));
      expect(requests.last.queryParameters.containsKey('category_id'), isFalse);
      expect(state.practice!['category_id'], isNull);
      expect(
        state.savedPractice('english', type: 'single', categoryId: 'cloze'),
        isNotNull,
      );
      expect(state.savedPractice('english', type: 'single'), isNotNull);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  for (final hasMore in [true, false]) {
    testWidgets(
      'continuous ${hasMore ? 'next batch' : 'new round'} retains category and question type',
      (tester) async {
        final requests = <Uri>[];
        final state = CategoryState(requests: requests);
        final initial = <String, dynamic>{
          'mode': 'all',
          'subject_id': 'english',
          'question_type': 'judge',
          'category_id': 'reading',
          'category_name': '阅读理解',
          'session_id': 'reading-resume-session',
          'questions': [question(type: 'judge')],
          'cursor': 0,
          'answers': {
            '0': ['A'],
          },
          'submitted': [0],
          'durations': {'0': 9},
          'stream': {
            'category_id': 'reading',
            'category_name': '阅读理解',
            'subject_id': 'english',
            'type': 'judge',
            'difficulty': null,
            'seed': '0123456789abcdef0123456789abcdef',
            'version': 5,
            'pool_hash': List.filled(64, 'a').join(),
            'offset': 0,
            'next_offset': 1,
            'has_more': hasMore,
            'total': hasMore ? 2 : 1,
            'round': 1,
            'answered': 0,
            'correct': 0,
            'study_seconds': 0,
            'shuffle': false,
            'shuffle_options': false,
          },
        };
        state.practice = initial;
        await preview.mountPage(
          tester,
          PracticePage(
            state: state,
            questions: [question(type: 'judge')],
            resume: initial,
          ),
        );
        await tap(
          tester,
          find.widgetWithText(FilledButton, hasMore ? '下一题' : '继续新一轮'),
        );
        expect(requests, hasLength(1));
        expect(requests.single.queryParameters['category_id'], 'reading');
        expect(requests.single.queryParameters['type'], 'judge');
        expect(requests.single.queryParameters['offset'], hasMore ? '1' : '0');
        expect(state.practice!['category_id'], 'reading');
        expect(state.practice!['question_type'], 'judge');
        expect((state.practice!['stream'] as Map)['category_id'], 'reading');
        expect((state.practice!['stream'] as Map)['round'], hasMore ? 1 : 2);
        expect(tester.takeException(), isNull);
        await clean(tester, state);
      },
    );
  }

  testWidgets(
    'professional subjects use their own supplied categories and old catalogs retain all-content practice',
    (tester) async {
      final state = CategoryState(group: 'computer');
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: state.subjects.last),
      );
      expect(find.text('综合练习'), findsOneWidget);
      expect(find.text('语音辨析'), findsNothing);
      expect(find.text('阅读理解'), findsNothing);
      expect(find.text('119道题 · 1个分类'), findsOneWidget);
      await clean(tester, state);

      final legacy = CategoryState();
      legacy.subjects.first.remove('categories');
      await preview.mountPage(
        tester,
        SubjectPage(state: legacy, subject: legacy.subjects.first),
      );
      expect(find.text('开始本科目练习'), findsOneWidget);
      await tap(tester, find.text('开始本科目练习'));
      expect(find.text('英语 · 全部题目'), findsOneWidget);
      expect(find.text('单选题 · 583'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await clean(tester, legacy);
    },
  );

  for (final scale in [1.0, 1.5]) {
    testWidgets(
      'category page fits short 320px screen with bottom system inset at scale $scale',
      (tester) async {
        final state = CategoryState();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 48);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 48);
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        await tester.pumpWidget(
          RepaintBoundary(
            key: preview.captureBoundary,
            child: StudyApp(state: state),
          ),
        );
        await tester.pumpAndSettle();
        await tap(tester, find.text('英语'));
        expect(find.byType(SubjectPage), findsOneWidget);
        final writing = find.byKey(const ValueKey('content-category-writing'));
        await tester.scrollUntilVisible(writing, 160);
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(writing).dy, lessThanOrEqualTo(592.5));
        expect(tester.takeException(), isNull);
        await tap(tester, writing);
        expect(find.text('英语 · 书面表达'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('practice-type-single')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        if (scale > 1)
          await preview.capture(
            tester,
            'content-category-settings-320-large-0.8.5',
          );
        final enter = find.widgetWithText(FilledButton, '进入练习');
        await tester.ensureVisible(enter);
        await tester.pumpAndSettle();
        expect(tester.getBottomRight(enter).dy, lessThanOrEqualTo(592.5));
        if (scale > 1)
          await preview.capture(
            tester,
            'content-category-settings-bottom-320-large-0.8.5',
          );
        expect(tester.takeException(), isNull);
        await clean(tester, state);
      },
    );
  }
}
