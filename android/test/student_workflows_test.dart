import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/teaching.dart';

import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

class ScopeStore extends UiPreviewStore {
  bool failNext = false;
  @override
  Future<void> write(String key, dynamic value) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    await super.write(key, value);
  }
}

http.Response reply(dynamic data) => http.Response(
  jsonEncode(data),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Json q(String id, {String subject = 'math'}) => {
  ...previewQuestion(),
  'id': id,
  'subject_id': subject,
  'stem': '题目$id',
};
Json progress(String subject, {String mode = 'all'}) => {
  'questions': [q('saved-$subject', subject: subject)],
  'cursor': 0,
  'answers': {
    '0': ['B'],
  },
  'submitted': [0],
  'durations': {'0': 6},
  'subject_id': subject,
  'mode': mode,
  'session_id': 'session-$mode-$subject',
};

class WorkflowState extends AppState {
  WorkflowState(
    ScopeStore storage,
    Future<http.Response> Function(http.Request) handler,
  ) : super(
        storage,
        Api(storage, client: MockClient(handler))..consented = true,
      ) {
    ready = true;
    user = {
      'id': 'workflow-student',
      'name': '林同学',
      'role': 'student',
      'activated': true,
      'consent_version': 'draft',
    };
    config = {'agreement_version': 'draft'};
    subjects = [
      {'id': 'math', 'name': '数学', 'total': 80},
      {'id': 'english', 'name': '英语', 'total': 663},
      {'id': 'computing', 'name': '计算机基础', 'total': 0},
    ];
  }
  @override
  Future<void> sync() async {}
  @override
  void scheduleSync() {}
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

Future<void> mountCompactWorkflow(
  WidgetTester tester,
  WorkflowState state, {
  Widget? page,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 568);
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewInsets = const FakeViewPadding();
  tester.platformDispatcher.textScaleFactorTestValue = 1.35;
  addTearDown(() {
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  // Use the actual StudyApp navigator and its global system-safe viewport.
  await tester.pumpWidget(
    RepaintBoundary(
      key: preview.captureBoundary,
      child: StudyApp(state: state),
    ),
  );
  await tester.pumpAndSettle();
  if (page != null) {
    unawaited(
      Navigator.of(
        tester.element(find.byType(HomeShell)),
      ).push<void>(MaterialPageRoute<void>(builder: (_) => page)),
    );
    await tester.pumpAndSettle();
  }
  expect(tester.takeException(), isNull);
}

void expectCompactTarget(WidgetTester tester, Finder finder) {
  final bounds = tester.getRect(finder);
  expect(bounds.height, greaterThanOrEqualTo(44));
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(320));
  expect(bounds.bottom, lessThanOrEqualTo(544));
}

void main() {
  setUpAll(preview.loadPreviewFonts);

  test(
    'each subject and review scope survives restart without replacing normal progress',
    () async {
      final store = ScopeStore();
      final state = WorkflowState(store, (_) async => reply([]));
      final math = progress('math');
      final english = progress('english');
      state.queue = [
        {'client_uuid': 'history-stays', 'question_id': 'old'},
      ];
      await state.activatePractice(math);
      await state.activatePractice(english);
      await state.activatePractice(progress('math', mode: 'doubt'));
      expect(state.savedPractice('math')!['answers'], {
        '0': ['B'],
      });
      expect(state.savedPractice('english'), english);
      expect(state.homePractice, english);
      final restarted = WorkflowState(store, (_) async => reply([]));
      await restarted.loadLocal();
      expect(restarted.savedPractice('math')!['durations'], {'0': 6});
      expect(
        restarted.savedPractice('english')!['session_id'],
        'session-all-english',
      );
      expect(restarted.homePractice!['subject_id'], 'english');
      expect(restarted.queue.single['client_uuid'], 'history-stays');
      restarted.practice = null;
      expect(restarted.savedPractice('math', mode: 'doubt'), isNull);
      expect(restarted.savedPractice('math'), isNotNull);
      state.dispose();
      restarted.dispose();
    },
  );

  test(
    'legacy single progress migrates and another user cannot read it',
    () async {
      final store = ScopeStore();
      final state = WorkflowState(store, (_) async => reply([]));
      final legacy = progress('math')
        ..remove('mode')
        ..remove('subject_id')
        ..remove('session_id');
      store.values['data_${state.cacheKey}'] = {
        'practice': legacy,
        'queue': [
          {'client_uuid': 'legacy-outbox'},
        ],
      };
      await state.loadLocal();
      await state.persist();
      expect(state.savedPractice('math')!['answers'], {
        '0': ['B'],
      });
      expect(store.values['data_${state.cacheKey}']['practices'], hasLength(1));
      final other = WorkflowState(store, (_) async => reply([]))
        ..user = {'id': 'other', 'role': 'student', 'activated': true};
      await other.loadLocal();
      expect(other.practice, isNull);
      expect(other.practices, isEmpty);
      expect(other.queue, isEmpty);
      state.dispose();
      other.dispose();
    },
  );

  test(
    'failed new scope write rolls back the new slot and preserves old durable progress',
    () async {
      final store = ScopeStore();
      final state = WorkflowState(store, (_) async => reply([]));
      final math = progress('math');
      await state.activatePractice(math);
      final before = jsonEncode(store.values);
      store.failNext = true;
      await expectLater(
        state.activatePractice(progress('english')),
        throwsStateError,
      );
      expect(identical(state.practice, math), isTrue);
      expect(state.savedPractice('english'), isNull);
      expect(jsonEncode(store.values), before);
      state.dispose();
    },
  );

  test(
    'a confirmed scope reduction retires every invalid slot but never queued history',
    () async {
      final store = ScopeStore();
      final state = WorkflowState(
        store,
        (_) async => reply({
          'version': 3,
          'questions': [
            {'id': 'saved-math', 'subject_id': 'math'},
          ],
          'subjects': [
            {'id': 'math'},
          ],
        }),
      );
      await state.activatePractice(progress('math'));
      await state.activatePractice(progress('english'));
      state.queue = [
        {'client_uuid': 'unavailable-history', 'question_id': 'saved-english'},
      ];
      await state.refreshBank();
      expect(state.practice, isNull);
      expect(state.savedPractice('english'), isNull);
      expect(state.homePractice!['subject_id'], 'math');
      expect(state.queue.single['client_uuid'], 'unavailable-history');
      state.dispose();
    },
  );

  test(
    'review API sends independent kind and subject pagination with media capability',
    () async {
      final requests = <http.Request>[];
      final state = WorkflowState(ScopeStore(), (r) async {
        requests.add(r);
        return reply({
          'items': [q('doubt-1')],
          'total': 1,
          'page': 2,
          'page_size': 20,
          'has_more': false,
        });
      });
      final result = await state.reviewQuestions(
        'doubt',
        subject: 'math',
        page: 2,
      );
      expect(result['items'], hasLength(1));
      expect(requests.single.url.path, '/api/student/review');
      expect(requests.single.url.queryParameters, {
        'kind': 'doubt',
        'subject_id': 'math',
        'page': '2',
        'page_size': '20',
      });
      expect(
        requests.single.headers['X-Question-Content'] ??
            requests.single.headers['x-question-content'],
        'media-v1',
      );
      state.user = {'id': 'teacher', 'role': 'teacher'};
      await expectLater(
        state.reviewQuestions('wrong'),
        throwsA(isA<AppError>()),
      );
      expect(requests, hasLength(1));
      state.dispose();
    },
  );

  test(
    'pending badge excludes submitted and unavailable historical assignments',
    () {
      final state = WorkflowState(ScopeStore(), (_) async => reply([]));
      state.studentAssignments = [
        {'id': 'actionable', 'submitted': false, 'available': true},
        {'id': 'left-class', 'submitted': false, 'available': false},
        {'id': 'graded', 'submitted': true, 'available': true},
      ];
      expect(state.pendingAssignmentCount, 1);
      state.dispose();
    },
  );

  test('placeholder explanation is not treated as a worked solution', () {
    expect(hasQuestionExplanation({'explanation': '原资料未提供解析。'}), isFalse);
    expect(hasQuestionExplanation({'explanation': '  '}), isFalse);
    expect(hasQuestionExplanation({'explanation': '先计算交集，再核对各元素。'}), isTrue);
  });

  testWidgets('home actionable assignment count opens the real task list', (
    tester,
  ) async {
    final tasks = <Json>[
      {
        'id': 'open',
        'paper_title': '本周巩固',
        'class_name': '一班',
        'question_count': 10,
        'submitted': false,
        'available': true,
      },
      {
        'id': 'archived',
        'paper_title': '历史练习',
        'class_name': '旧班',
        'question_count': 10,
        'submitted': false,
        'available': false,
      },
      {
        'id': 'done',
        'paper_title': '已完成练习',
        'class_name': '一班',
        'question_count': 10,
        'submitted': true,
        'available': true,
        'score': 8,
        'full_score': 10,
      },
    ];
    final state = WorkflowState(ScopeStore(), (_) async => reply(tasks))
      ..assignmentsLoaded = true
      ..studentAssignments = tasks;
    await preview.mountPage(tester, HomeShell(state: state));
    await tester.ensureVisible(find.text('待完成 1 项班级练习'));
    await tester.tap(find.text('待完成 1 项班级练习'));
    await tester.pumpAndSettle();
    expect(find.byType(StudentAssignmentsPage), findsOneWidget);
    expect(find.text('本周巩固'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await clean(tester, state);
  });

  testWidgets(
    'subject continuation resumes its own saved answers without fetching a new pool',
    (tester) async {
      final requests = <String>[];
      final state = WorkflowState(ScopeStore(), (r) async {
        requests.add(r.url.path);
        return reply([]);
      });
      await state.activatePractice(progress('math'));
      await state.activatePractice(progress('english'));
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: state.subjects.first),
      );
      await tester.tap(find.text('开始本科目练习'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('practice-type-all')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('进入练习'));
      await tester.tap(find.text('进入练习'));
      await tester.pumpAndSettle();
      expect(find.text('继续已保存的练习？'), findsOneWidget);
      await preview.capture(tester, 'subject-resume-choice-0.8.0');
      await tester.tap(find.widgetWithText(CupertinoDialogAction, '继续练习'));
      await tester.pumpAndSettle();
      expect(find.byType(PracticePage), findsOneWidget);
      expect(state.practice!['subject_id'], 'math');
      expect(state.practice!['answers'], {
        '0': ['B'],
      });
      expect(state.savedPractice('english'), isNotNull);
      expect(requests, isEmpty);
      await clean(tester, state);
    },
  );

  testWidgets(
    'doubt list opens a real question and preserves the ordinary subject slot',
    (tester) async {
      final requests = <Uri>[];
      final state = WorkflowState(ScopeStore(), (r) async {
        requests.add(r.url);
        return reply({
          'items': [q('flagged')],
          'total': 1,
          'page': 1,
          'page_size': 20,
          'has_more': false,
          'subjects': [
            {'id': 'math', 'name': '数学', 'count': 1},
          ],
        });
      });
      await state.activatePractice(progress('math'));
      await preview.mountPage(tester, ReviewPage(state: state));
      await tester.scrollUntilVisible(
        find.text('我的存疑'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('我的存疑'));
      await tester.pumpAndSettle();
      expect(requests.single.queryParameters['kind'], 'doubt');
      await preview.capture(tester, 'doubt-list-0.8.0');
      await tester.tap(find.text('题目flagged'));
      await tester.pumpAndSettle();
      expect(find.byType(PracticePage), findsOneWidget);
      expect(state.practice!['mode'], 'doubt');
      expect(state.homePractice!['session_id'], 'session-all-math');
      expect(state.savedPractice('math')!['submitted'], [0]);
      await clean(tester, state);
    },
  );

  testWidgets(
    'review pagination and subject filter request the selected server scope',
    (tester) async {
      final requests = <Uri>[];
      final state = WorkflowState(ScopeStore(), (r) async {
        requests.add(r.url);
        final page = int.parse(r.url.queryParameters['page'] ?? '1');
        final english = r.url.queryParameters['subject_id'] == 'english';
        return reply({
          'items': english
              ? [q('english-only', subject: 'english')]
              : page == 1
              ? List.generate(20, (i) => q('page1-$i'))
              : [q('page2')],
          'total': english ? 1 : 21,
          'page': page,
          'page_size': 20,
          'has_more': !english && page == 1,
          'subjects': [
            {'id': 'math', 'name': '数学', 'count': 21},
            {'id': 'english', 'name': '英语', 'count': 1},
          ],
        });
      });
      await preview.mountPage(
        tester,
        ReviewQuestionsPage(state: state, kind: 'wrong'),
      );
      await tester.scrollUntilVisible(
        find.text('下一页'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('下一页'));
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['page'], '2');
      expect(find.text('题目page2'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('复习科目'),
        -500,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语 · 1题').last);
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['subject_id'], 'english');
      expect(requests.last.queryParameters['page'], '1');
      expect(find.text('题目english-only'), findsOneWidget);
      await preview.capture(tester, 'review-subject-filter-0.8.0');
      await clean(tester, state);
    },
  );

  testWidgets(
    'review clears visible questions immediately on identity change',
    (tester) async {
      final state = WorkflowState(
        ScopeStore(),
        (_) async => reply({
          'items': [q('private-list')],
          'total': 1,
          'has_more': false,
        }),
      );
      await preview.mountPage(
        tester,
        ReviewQuestionsPage(state: state, kind: 'favorite'),
      );
      expect(find.text('题目private-list'), findsOneWidget);
      state.user = {'id': 'other', 'role': 'student', 'activated': true};
      state.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('题目private-list'), findsNothing);
      expect(find.textContaining('登录身份已变化'), findsOneWidget);
      await clean(tester, state);
    },
  );

  testWidgets(
    'assigned profession is locked and disabled if no longer enabled',
    (tester) async {
      final state = WorkflowState(ScopeStore(), (_) async => reply([]));
      state.user = {
        ...state.user!,
        'activated': false,
        'subject_group_id': 'computer-group',
      };
      state.config = {
        ...state.config,
        'subject_groups': [
          {'id': 'mechanics', 'name': '机械专业'},
          {'id': 'computer-group', 'name': '计算机专业'},
        ],
      };
      await preview.mountPage(tester, ActivationPage(state: state));
      final field = tester.widget<DropdownButtonFormField<String>>(
        find.byType(DropdownButtonFormField<String>),
      );
      expect(field.initialValue, 'computer-group');
      expect(field.onChanged, isNull);
      await preview.capture(tester, 'assigned-profession-0.8.0');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      state.config['subject_groups'] = [
        {'id': 'mechanics', 'name': '机械专业'},
      ];
      await preview.mountPage(tester, ActivationPage(state: state));
      expect(find.textContaining('当前专业暂不可用'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(FilledButton),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      await clean(tester, state);
    },
  );

  testWidgets(
    '320 short large text keeps subject continuation actions reachable',
    (tester) async {
      final requests = <String>[];
      final state = WorkflowState(ScopeStore(), (request) async {
        requests.add(request.url.path);
        return reply([]);
      });
      await state.activatePractice(progress('math'));
      await state.activatePractice(progress('english'));
      await mountCompactWorkflow(
        tester,
        state,
        page: SubjectPage(state: state, subject: state.subjects.first),
      );
      final start = find.widgetWithText(FilledButton, '开始本科目练习');
      await tester.scrollUntilVisible(
        start,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expectCompactTarget(tester, start);
      await tester.tap(start);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('practice-type-all')));
      await tester.pumpAndSettle();
      final enter = find.widgetWithText(FilledButton, '进入练习');
      await tester.ensureVisible(enter);
      expectCompactTarget(tester, enter);
      await tester.tap(enter);
      await tester.pumpAndSettle();
      final resume = find.widgetWithText(CupertinoDialogAction, '继续练习');
      await tester.ensureVisible(resume);
      expectCompactTarget(tester, resume);
      expect(tester.takeException(), isNull);
      await preview.capture(tester, 'subject-resume-choice-320-large-0.8.0');
      await tester.tap(resume);
      await tester.pumpAndSettle();
      expect(find.byType(PracticePage), findsOneWidget);
      expect(state.practice!['subject_id'], 'math');
      expect(state.practice!['answers'], {
        '0': ['B'],
      });
      expect(state.savedPractice('english'), isNotNull);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets('320 short large text review subject selector remains usable', (
    tester,
  ) async {
    final requests = <Uri>[];
    final state = WorkflowState(ScopeStore(), (request) async {
      requests.add(request.url);
      final english = request.url.queryParameters['subject_id'] == 'english';
      return reply({
        'items': [
          q(
            english ? 'english-filtered' : 'math-filtered',
            subject: english ? 'english' : 'math',
          ),
        ],
        'total': 1,
        'page': 1,
        'page_size': 20,
        'has_more': false,
        'subjects': [
          {'id': 'math', 'name': '数学', 'count': 1},
          {'id': 'english', 'name': '英语', 'count': 1},
        ],
      });
    });
    await mountCompactWorkflow(
      tester,
      state,
      page: ReviewQuestionsPage(state: state, kind: 'wrong'),
    );
    final field = find.byType(DropdownButtonFormField<String>);
    await tester.scrollUntilVisible(
      field,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expectCompactTarget(tester, field);
    await tester.tap(field);
    await tester.pumpAndSettle();
    await tester.tap(find.text('英语 · 1题').last);
    await tester.pumpAndSettle();
    expect(requests.last.queryParameters['kind'], 'wrong');
    expect(requests.last.queryParameters['subject_id'], 'english');
    expect(requests.last.queryParameters['page'], '1');
    expect(find.text('题目math-filtered'), findsNothing);
    expect(find.text('题目english-filtered'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await preview.capture(tester, 'review-subject-filter-320-large-0.8.0');
    await clean(tester, state);
  });

  testWidgets(
    '320 short large text doubt pagination reaches next page and starts review',
    (tester) async {
      final requests = <Uri>[];
      final state = WorkflowState(ScopeStore(), (request) async {
        requests.add(request.url);
        final page = int.parse(request.url.queryParameters['page'] ?? '1');
        return reply({
          'items': page == 1
              ? List.generate(20, (i) => q('doubt-${i + 1}'))
              : [q('doubt-21')],
          'total': 21,
          'page': page,
          'page_size': 20,
          'has_more': page == 1,
          'subjects': [
            {'id': 'math', 'name': '数学', 'count': 21},
          ],
        });
      });
      await state.activatePractice(progress('math'));
      await mountCompactWorkflow(
        tester,
        state,
        page: ReviewQuestionsPage(state: state, kind: 'doubt'),
      );
      expect(requests.single.queryParameters['kind'], 'doubt');
      await preview.capture(tester, 'doubt-list-320-large-0.8.0');
      final next = find.widgetWithText(OutlinedButton, '下一页');
      await tester.scrollUntilVisible(
        next,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expectCompactTarget(tester, next);
      expect(tester.widget<OutlinedButton>(next).onPressed, isNotNull);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(requests.last.queryParameters['page'], '2');
      final question = find.text('题目doubt-21');
      await tester.scrollUntilVisible(
        question,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await preview.capture(tester, 'doubt-page2-320-large-0.8.0');
      await tester.tap(question);
      await tester.pumpAndSettle();
      expect(find.byType(PracticePage), findsOneWidget);
      expect(state.practice!['mode'], 'doubt');
      expect(state.practice!['answers'], isEmpty);
      expect(state.homePractice!['session_id'], 'session-all-math');
      expect(state.savedPractice('math')!['submitted'], [0]);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets(
    '320 short large text assigned profession activation scrolls to its action',
    (tester) async {
      final requests = <Uri>[];
      final state = WorkflowState(ScopeStore(), (request) async {
        requests.add(request.url);
        return reply([]);
      });
      state.user = {
        ...state.user!,
        'activated': false,
        'subject_group_id': 'computer-group',
      };
      state.config = {
        ...state.config,
        'subject_groups': [
          {'id': 'mechanics', 'name': '机械专业'},
          {'id': 'computer-group', 'name': '计算机应用专业'},
        ],
      };
      await mountCompactWorkflow(tester, state);
      expect(find.byType(ActivationPage), findsOneWidget);
      final group = find.byType(DropdownButtonFormField<String>);
      await tester.scrollUntilVisible(
        group,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final field = tester.widget<DropdownButtonFormField<String>>(group);
      expect(field.initialValue, 'computer-group');
      expect(field.onChanged, isNull);
      expect(find.text('计算机应用专业'), findsOneWidget);
      expectCompactTarget(tester, group);
      expect(tester.takeException(), isNull);
      await preview.capture(tester, 'assigned-profession-320-large-0.8.0');
      final submit = find.byType(FilledButton);
      await tester.scrollUntilVisible(
        submit,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expectCompactTarget(tester, submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(find.textContaining('请填写有效出生年份'), findsOneWidget);
      expect(requests, isEmpty);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );
}
