import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/teaching.dart';

import 'ui_render_test.dart' as preview;

class TeachingMemoryStore extends LocalStore {
  final values = <String, dynamic>{};
  int writes = 0;
  int? failOnWrite;
  @override
  Future<dynamic> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  @override
  Future<void> write(String key, dynamic value) async {
    writes++;
    if (writes == failOnWrite) throw StateError('disk full');
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> secureWrite(String key, String? value) async {
    values['secure_$key'] = value;
  }
}

Json sampleChoice() => {
  'id': 'choice-1',
  'type': 'single',
  'stem': '下列哪个数字是偶数？',
  'options': [
    {'key': 'A', 'text': '2'},
    {'key': 'B', 'text': '3'},
    {'key': 'C', 'text': '5'},
    {'key': 'D', 'text': '7'},
  ],
  'answer': ['A'],
  'explanation': '偶数可以被2整除。',
  'score': 1,
  'blank_count': 0,
};
Json teachingCatalog() => {
  'subjects': [
    {
      'id': 'math',
      'name': '数学',
      'available': {'single': 2, 'multiple': 0, 'fill': 0, 'judge': 0},
    },
  ],
  'classes': [
    {
      'id': 'class-1',
      'name': '机械升学一班',
      'subject_ids': ['math'],
    },
  ],
};

AppState teachingState(
  TeachingMemoryStore store, {
  bool teacher = true,
  List<String>? paths,
}) {
  final api = Api(
    store,
    client: MockClient((request) async {
      paths?.add(request.url.path);
      dynamic value;
      switch (request.url.path) {
        case '/api/public/config':
          value = {'agreement_version': 'new-agreement'};
        case '/api/auth/login':
          value = {
            'access_token': 'teacher-token',
            'refresh_token': 'teacher-refresh',
            'user': {
              'id': 'teacher-1',
              'username': 'teacher',
              'name': '陈老师',
              'role': 'teacher',
              'activated': false,
              'must_change_password': false,
            },
          };
        case '/api/management/dashboard':
          value = {'classes': 1, 'students': 2};
        case '/api/management/classes':
          value = teachingCatalog()['classes'];
        case '/api/teaching/catalog':
          value = teachingCatalog();
        case '/api/teaching/papers':
          value = [];
        case '/api/teaching/assignments':
          value = [];
        case '/api/student/assignments/task-1':
          value = {
            'id': 'task-1',
            'paper_title': '数学周练',
            'class_name': '机械升学一班',
            'question_count': 1,
            'full_score': 1,
            'submitted': false,
            'result': null,
            'questions': [
              {...sampleChoice()}
                ..remove('answer')
                ..remove('explanation'),
            ],
          };
        default:
          return http.Response('{}', 404);
      }
      return http.Response(
        jsonEncode(value),
        200,
        headers: {'content-type': 'application/json'},
      );
    }),
  )..consented = true;
  return AppState(store, api)
    ..ready = true
    ..user = teacher
        ? {
            'id': 'teacher-1',
            'role': 'teacher',
            'name': '陈老师',
            'username': 'teacher',
            'activated': false,
            'must_change_password': false,
          }
        : {'id': 'student-1', 'role': 'student', 'activated': true};
}

void main() {
  setUpAll(preview.loadPreviewFonts);
  test(
    'teacher login does not call student APIs or require student activation',
    () async {
      final store = TeachingMemoryStore(), paths = <String>[];
      final state = teachingState(store, paths: paths)..user = null;
      await state.login('teacher', '123456');
      expect(state.isTeacher, true);
      expect(state.activated, true);
      expect(state.needsConsent, false);
      expect(paths.any((path) => path.contains('/student/')), false);
      expect(paths, contains('/api/management/dashboard'));
      await expectLater(
        state.record(sampleChoice(), ['A'], 1),
        throwsA(isA<AppError>().having((error) => error.status, 'status', 403)),
      );
      state.dispose();
    },
  );

  test(
    'option shuffle retains canonical keys, score and school package unchanged; resume retains order',
    () async {
      final original = sampleChoice();
      final before = jsonEncode(original);
      final shuffled = preparePracticeQuestions(
        [original],
        shuffleOptions: true,
        random: Random(8),
      ).single;
      expect(jsonEncode(original), before);
      expect(
        jsonRows(shuffled['options']).map((option) => option['display_key']),
        ['A', 'B', 'C', 'D'],
      );
      expect(shuffled['answer'], ['A']);
      expect(scoreQuestion(shuffled, ['A']), true);
      final currentLabel = jsonRows(
        shuffled['options'],
      ).firstWhere((option) => option['key'] == 'A')['display_key'];
      expect(formatQuestionAnswer(shuffled), currentLabel);
      expect(formatSelectedAnswer(shuffled, ['A']), currentLabel);
      final store = TeachingMemoryStore();
      final state = AppState(store)
        ..user = {'id': 'student-1', 'activated': false}
        ..practice = {
          'questions': [shuffled],
        };
      await state.record(shuffled, ['A'], 2, practiceState: state.practice);
      final resumed = AppState(store)
        ..user = {'id': 'student-1', 'activated': false};
      await resumed.loadLocal();
      expect(
        jsonEncode(resumed.practice!['questions']),
        jsonEncode([shuffled]),
      );
      expect(resumed.queue.single['selected'], ['A']);
      expect(
        canShuffleOptions({
          ...sampleChoice(),
          'options': [
            {'key': 'A', 'text': '甲'},
            {'key': 'B', 'text': '以上都正确'},
          ],
        }),
        false,
      );
      expect(
        canShuffleOptions({...sampleChoice(), 'stem': 'A与B两项都对吗？'}),
        false,
      );
      expect(canShuffleOptions({...sampleChoice(), 'type': 'judge'}), false);
      expect(canShuffleOptions({...sampleChoice(), 'type': 'fill'}), false);
      state.dispose();
      resumed.dispose();
    },
  );

  test(
    'class-task retry persists exact UUID/body separate from autonomous practice and users',
    () async {
      final store = TeachingMemoryStore();
      final first = AssignmentDraft(store, 'assignment_server1_user1_task1')
        ..answers = {
          'choice-1': ['A'],
        };
      final body = await first.submission([sampleChoice()]);
      first.answers['choice-1'] = ['B'];
      expect(await first.submission([sampleChoice()]), body);
      final restarted = AssignmentDraft(
        store,
        'assignment_server1_user1_task1',
      );
      await restarted.load();
      expect(await restarted.submission([sampleChoice()]), body);
      final otherUser = AssignmentDraft(
        store,
        'assignment_server1_user2_task1',
      );
      await otherUser.load();
      expect(otherUser.answers, isEmpty);
      expect(otherUser.pending, isNull);
      final otherServer = AssignmentDraft(
        store,
        'assignment_server2_user1_task1',
      );
      await otherServer.load();
      expect(otherServer.answers, isEmpty);
      expect(store.values.keys.any((key) => key.startsWith('data_')), false);
    },
  );

  test(
    'failed pending-submit disk write recovers with same durable UUID/body',
    () async {
      final store = TeachingMemoryStore()..failOnWrite = 2;
      final draft = AssignmentDraft(store, 'assignment_disk')
        ..answers = {
          'choice-1': ['A'],
        };
      await expectLater(draft.submission([sampleChoice()]), throwsStateError);
      final pending = jsonDecode(jsonEncode(draft.pending));
      expect(pending['client_uuid'], isNotEmpty);
      expect(store.values['assignment_disk']['pending'], isNull);
      final recovered = await draft.submission([sampleChoice()]);
      expect(recovered, pending);
      expect(store.values['assignment_disk']['pending'], pending);
    },
  );

  testWidgets(
    'teacher role opens teacher shell instead of student activation',
    (tester) async {
      final store = TeachingMemoryStore();
      final state = teachingState(store)
        ..config = {'agreement_version': 'new-agreement'};
      await tester.pumpWidget(StudyApp(state: state));
      await tester.pumpAndSettle();
      expect(find.byType(TeacherShell), findsOneWidget);
      expect(find.byType(ActivationPage), findsNothing);
      expect(find.text('创建班级练习卷'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'task submit uses canonical key and locks exact retry after lost response',
    (tester) async {
      final store = TeachingMemoryStore();
      final submissions = <Json>[];
      final choice = sampleChoice();
      choice['options'] = [
        {'key': 'C', 'display_key': 'A', 'text': '5'},
        {'key': 'A', 'display_key': 'B', 'text': '2'},
        {'key': 'B', 'display_key': 'C', 'text': '3'},
        {'key': 'D', 'display_key': 'D', 'text': '7'},
      ];
      final safe = Map<String, dynamic>.from(choice)
        ..remove('answer')
        ..remove('explanation');
      final api = Api(
        store,
        client: MockClient((request) async {
          if (request.method == 'POST') {
            submissions.add(
              Map<String, dynamic>.from(jsonDecode(request.body)),
            );
            if (submissions.length == 1)
              throw http.ClientException('connection interrupted');
            return http.Response(
              jsonEncode({
                'assignment_id': 'task-1',
                'score': 1,
                'full_score': 1,
                'correct': 1,
                'total': 1,
                'submitted_at': '2026-11-02T15:00:00Z',
                'questions': [
                  {
                    ...choice,
                    'selected': ['A'],
                    'correct': true,
                    'awarded_score': 1,
                  },
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode({
              'id': 'task-1',
              'paper_title': '数学周练',
              'class_name': '一班',
              'questions': [safe],
              'result': null,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      )..consented = true;
      final state = AppState(store, api)
        ..user = {'id': 'student-1', 'role': 'student', 'activated': true};
      await tester.pumpWidget(
        MaterialApp(
          home: AssignmentAttemptPage(state: state, assignmentId: 'task-1'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('参考答案'), findsNothing);
      expect(
        find.text('2'),
        findsOneWidget,
        reason: tester.allWidgets
            .whereType<Text>()
            .map((text) => text.data)
            .join(' | '),
      );
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('整卷提交'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认交卷').last);
      await tester.pumpAndSettle();
      expect(submissions.single['answers'], [
        {
          'question_id': 'choice-1',
          'selected': ['A'],
        },
      ]);
      await tester.scrollUntilVisible(
        find.text('3'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      final tile = tester.widget<ListTile>(
        find.ancestor(of: find.text('3'), matching: find.byType(ListTile)),
      );
      expect(tile.onTap, isNull);
      expect(state.queue, isEmpty);
      await tester.tap(find.text('重试交卷'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认交卷').last);
      await tester.pumpAndSettle();
      expect(submissions.last, submissions.first);
      expect(find.textContaining('参考答案：B'), findsOneWidget);
      expect(find.textContaining('你的答案：B'), findsOneWidget);
      expect(state.queue, isEmpty);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  for (final width in [390.0, 320.0]) {
    for (final screen in ['teacher', 'builder', 'task']) {
      testWidgets('$screen layout ${width.toInt()}px at130percent', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final store = TeachingMemoryStore(),
            state = teachingState(store, teacher: screen != 'task');
        final page = switch (screen) {
          'teacher' => TeacherShell(
            state: state,
            onPassword: (_) {},
            onLegal: (_) {},
          ),
          'builder' => PaperBuilderPage(
            state: state,
            catalog: teachingCatalog(),
          ),
          _ => AssignmentAttemptPage(state: state, assignmentId: 'task-1'),
        };
        await tester.pumpWidget(
          MaterialApp(
            theme: preview.previewTheme(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(1.3)),
              child: child!,
            ),
            home: RepaintBoundary(key: preview.captureBoundary, child: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('知识点'), findsNothing);
        expect(find.textContaining('待归类'), findsNothing);
        expect(find.textContaining('下载题库'), findsNothing);
        expect(find.textContaining('离线题库'), findsNothing);
        if (screen == 'builder') {
          expect(
            tester
                .widget<TextField>(find.widgetWithText(TextField, '抽取题量'))
                .controller!
                .text,
            '2',
          );
        }
        await preview.capture(tester, 'teaching-$screen-${width.toInt()}');
        await tester.pumpWidget(const SizedBox());
        state.dispose();
      });
    }
  }
}
