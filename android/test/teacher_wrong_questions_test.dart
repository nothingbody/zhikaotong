import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/teacher_student_analytics.dart';
import 'package:zhikaotong/teacher_wrong_questions.dart';

import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

const schoolClass = {'id': 'c1', 'name': '升学一班'};
const pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/K1sAAAAASUVORK5CYII=';
final imageHash = sha256.convert(base64Decode(pixel)).toString();
http.Response reply(dynamic body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AppState stateFor(
  Future<http.Response> Function(http.Request) handler, {
  String role = 'teacher',
}) {
  final store = UiPreviewStore();
  return AppState(
      store,
      Api(store, client: MockClient(handler))..consented = true,
    )
    ..ready = true
    ..user = {'id': 't1', 'role': role, 'name': '王老师'};
}

Json wrongRow(String id, {String subject = 'math', bool media = false}) => {
  'question': {
    ...previewQuestion(),
    'id': id,
    'subject_id': subject,
    'stem': '错题$id：已知集合A、B，求它们的交集。${media ? ' {{img:$imageHash}}' : ''}',
    'explanation': '原资料未提供解析。',
    if (media)
      'media': {
        imageHash: {
          'mime': 'image/png',
          'data': pixel,
          'width': 1,
          'height': 1,
        },
      },
  },
  'error_count': 3,
  'correct_streak': 0,
  'last_error_at': '2026-11-03T04:20:00Z',
};
Json roster({bool active = true}) => {
  'class': schoolClass,
  'students': [
    if (active)
      {
        'id': 's1',
        'name': '甲同学',
        'username': 'alpha',
        'status': 'active',
        'current_wrong_count': 21,
      },
    {
      'id': 'left',
      'name': '已离班学生',
      'username': 'left',
      'status': 'left',
      'current_wrong_count': 99,
    },
  ],
  'wrong_summary': {
    'wrong_questions': active ? 21 : 0,
    'students_with_wrong': active ? 1 : 0,
    'student_count': active ? 1 : 0,
  },
};
Json wrongBook({
  int page = 1,
  String subject = '',
  bool empty = false,
  bool media = false,
}) => {
  'class': schoolClass,
  'student': {
    'id': 's1',
    'name': '甲同学',
    'username': 'alpha',
    'status': 'active',
  },
  'available_subjects': [
    {'id': 'math', 'name': '数学'},
    {'id': 'english', 'name': '英语'},
  ],
  'subjects': [
    {'subject_id': 'math', 'name': '数学', 'total': empty ? 0 : 20},
    {'subject_id': 'english', 'name': '英语', 'total': empty ? 0 : 1},
  ],
  'scope': 'current_class_and_student_subjects_active_wrong_published',
  'total': empty
      ? 0
      : subject == 'english'
      ? 1
      : 21,
  'page': page,
  'page_size': 20,
  'has_more': !empty && subject.isEmpty && page == 1,
  'items': empty
      ? <Json>[]
      : subject == 'english'
      ? [wrongRow('english', subject: 'english')]
      : page == 2
      ? [wrongRow('page2')]
      : List.generate(20, (i) => wrongRow('q${i + 1}', media: media && i == 0)),
};
Json analytics({int days = 30, String subject = ''}) => {
  'class': schoolClass,
  'student': {
    'id': 's1',
    'name': '甲同学',
    'username': 'alpha',
    'status': 'active',
  },
  'available_subjects': [
    {'id': 'math', 'name': '数学'},
    {'id': 'legacy', 'name': '历史授权科目'},
  ],
  'summary': {'answered': 20, 'correct': 3, 'wrong': 17, 'accuracy': 15},
  'period': {'start': '2026-11-01', 'end': '2026-11-03', 'days': days},
  'lifetime': {},
  'subjects': [],
  'types': [],
  'daily': [],
  'classwork': {},
  'wrong_book': {
    'total': subject == 'legacy' ? 0 : 21,
    'subjects': [],
    'scope': 'current_class_and_student_subjects_active_wrong_published',
  },
};

Future<void> mount(
  WidgetTester tester,
  AppState state,
  Widget page, {
  double width = 390,
  double height = 844,
  double scale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    state.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: preview.previewTheme(),
      builder: (context, child) => RepaintBoundary(
        key: preview.captureBoundary,
        child: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, bounds) => MediaQuery(
              data: MediaQuery.of(context).copyWith(size: bounds.biggest),
              child: child!,
            ),
          ),
        ),
      ),
      home: page,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> reach(
  WidgetTester tester,
  Finder target, {
  double delta = 300,
}) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find
        .descendant(
          of: find.byType(ListView).last,
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
}

Future<void> enterFirst(WidgetTester tester) async {
  final row = find.byKey(const ValueKey('teacher-wrong-question-q1'));
  await reach(tester, row);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void safeTarget(
  WidgetTester tester,
  Finder target,
  double width,
  double height,
) {
  final bounds = tester.getRect(target);
  expect(bounds.height, greaterThanOrEqualTo(44));
  expect(bounds.left, greaterThanOrEqualTo(0));
  expect(bounds.right, lessThanOrEqualTo(width));
  expect(bounds.bottom, lessThanOrEqualTo(height - 24));
}

void main() {
  setUpAll(preview.loadPreviewFonts);
  testWidgets(
    'class roster opens current wrong questions and read only answer with original image',
    (tester) async {
      final requests = <http.Request>[];
      var rosterCalls = 0, wrongCalls = 0;
      final state = stateFor((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/wrong-questions')) {
          wrongCalls++;
          return reply(wrongBook(media: true));
        }
        rosterCalls++;
        return reply(roster());
      });
      await mount(
        tester,
        state,
        TeacherClassStudentsPage(state: state, schoolClass: schoolClass),
      );
      expect(find.text('错题合计 21题 · 1位学生有错题'), findsOneWidget);
      expect(find.text('已离班学生'), findsNothing);
      final entry = find.byKey(const ValueKey('teacher-student-wrong-s1'));
      await reach(tester, entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(TeacherWrongQuestionsPage), findsOneWidget);
      expect(find.text('当前错题 21题'), findsOneWidget);
      expect(find.text('累计答错 3次'), findsWidgets);
      await enterFirst(tester);
      expect(find.text('教师只读 · 题库当前版本'), findsOneWidget);
      await reach(tester, find.byType(Image));
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('原图'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭图片'));
      await tester.pumpAndSettle();
      await reach(tester, find.text('参考答案'));
      expect(find.text('B'), findsOneWidget);
      expect(find.text('暂无解题讲解'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('提交答案'), findsNothing);
      expect(state.queue, isEmpty);
      expect(state.practice, isNull);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(wrongCalls, 3);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(rosterCalls, 2);
      expect(requests.every((r) => r.method == 'GET'), true);
      expect(
        requests.every((r) => r.headers['X-Question-Content'] == 'media-v1'),
        true,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'analytics current question count is separate from period errors and opens all currently allowed subjects',
    (tester) async {
      final urls = <Uri>[];
      final state = stateFor((request) async {
        urls.add(request.url);
        return reply(
          request.url.path.endsWith('/analytics')
              ? analytics(
                  days: int.parse(request.url.queryParameters['days']!),
                  subject: request.url.queryParameters['subject_id'] ?? '',
                )
              : wrongBook(),
        );
      });
      await mount(
        tester,
        state,
        TeacherStudentAnalyticsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(find.text('21题'), findsOneWidget);
      await tester.tap(find.text('近7天'));
      await tester.pumpAndSettle();
      expect(find.text('21题'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('历史授权科目').last);
      await tester.pumpAndSettle();
      expect(find.text('0题'), findsOneWidget);
      final entry = find.byKey(const ValueKey('teacher-analytics-open-wrong'));
      await reach(tester, entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(urls.last.path.endsWith('/wrong-questions'), true);
      expect(urls.last.queryParameters.containsKey('subject_id'), false);
      expect(urls.last.queryParameters.containsKey('days'), false);
      expect(find.text('当前错题 21题'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'wrong question list paginates and changing allowed subject resets to page one',
    (tester) async {
      final urls = <Uri>[];
      final state = stateFor((request) async {
        urls.add(request.url);
        return reply(
          wrongBook(
            page: int.parse(request.url.queryParameters['page']!),
            subject: request.url.queryParameters['subject_id'] ?? '',
          ),
        );
      });
      await mount(
        tester,
        state,
        TeacherWrongQuestionsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      final next = find.widgetWithText(OutlinedButton, '下一页');
      await reach(tester, next);
      await tester.tap(next);
      await tester.pumpAndSettle();
      expect(urls.last.queryParameters, {'page': '2', 'page_size': '20'});
      await reach(
        tester,
        find.byKey(const ValueKey('teacher-wrong-question-page2')),
      );
      expect(
        find.byKey(const ValueKey('teacher-wrong-question-q1')),
        findsNothing,
      );
      await reach(
        tester,
        find.byType(DropdownButtonFormField<String>),
        delta: -250,
      );
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('英语 · 1题').last);
      await tester.pumpAndSettle();
      expect(urls.last.queryParameters, {
        'subject_id': 'english',
        'page': '1',
        'page_size': '20',
      });
      expect(find.text('当前错题 1题'), findsOneWidget);
      await reach(
        tester,
        find.byKey(const ValueKey('teacher-wrong-question-english')),
      );
      expect(find.text('下一页'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty current book has a useful state and never renders answer actions',
    (tester) async {
      final state = stateFor((_) async => reply(wrongBook(empty: true)));
      await mount(
        tester,
        state,
        TeacherWrongQuestionsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(find.text('当前错题 0题'), findsOneWidget);
      expect(find.text('当前没有错题'), findsOneWidget);
      expect(find.text('下一页'), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'network retry recovers then removed member clears identity question and subject metadata',
    (tester) async {
      var status = 500;
      final state = stateFor(
        (_) async => status == 200
            ? reply(wrongBook())
            : reply({'detail': '不可访问'}, status),
      );
      await mount(
        tester,
        state,
        TeacherWrongQuestionsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(find.text('不可访问'), findsOneWidget);
      status = 200;
      await tester.tap(find.text('重新验证并加载'));
      await tester.pumpAndSettle();
      expect(find.text('甲同学的错题'), findsOneWidget);
      status = 404;
      await tester.tap(find.byTooltip('刷新学生错题'));
      await tester.pump();
      expect(find.text('甲同学的错题'), findsNothing);
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byKey(const ValueKey('teacher-wrong-total')), findsNothing);
      await tester.pumpAndSettle();
      expect(find.textContaining('当前无权查看此学生或科目'), findsOneWidget);
      expect(find.textContaining('错题q1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'opening a previously loaded card revalidates removed membership before revealing reference answer',
    (tester) async {
      var removed = false, calls = 0;
      final state = stateFor((_) async {
        calls++;
        return removed
            ? reply({'detail': '学生已离班'}, 404)
            : reply(wrongBook(media: true));
      });
      await mount(
        tester,
        state,
        TeacherWrongQuestionsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(find.text('甲同学的错题'), findsOneWidget);
      final card = find.byKey(const ValueKey('teacher-wrong-question-q1'));
      await reach(tester, card);
      removed = true;
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('当前无权查看此学生或科目'), findsOneWidget);
      expect(find.text('错题详情'), findsNothing);
      expect(find.text('参考答案'), findsNothing);
      expect(find.text('甲同学的错题'), findsNothing);
      expect(
        find.byKey(const ValueKey('teacher-wrong-question-q1')),
        findsNothing,
      );
      expect(find.byType(DropdownButtonFormField<String>), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(state.queue, isEmpty);
      expect(state.practice, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'background removes even a zoomed original and foreground rechecks revoked access',
    (tester) async {
      var deny = false, calls = 0;
      final state = stateFor((_) async {
        calls++;
        return deny
            ? reply({'detail': '教师已解绑'}, 403)
            : reply(wrongBook(media: true));
      });
      await mount(
        tester,
        state,
        TeacherWrongQuestionsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      await enterFirst(tester);
      await reach(tester, find.byType(Image));
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('错题q1'), findsNothing);
      deny = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.textContaining('当前无权查看此学生或科目'), findsOneWidget);
      expect(find.text('甲同学 · 数学'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'session switch clears a pending detail response and never reuses old student data for new teacher',
    (tester) async {
      final pending = Completer<http.Response>();
      var calls = 0;
      final state = stateFor((_) async {
        calls++;
        return calls <= 2 ? reply(wrongBook(media: true)) : pending.future;
      });
      await mount(
        tester,
        state,
        TeacherWrongQuestionsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      await enterFirst(tester);
      await tester.tap(find.byTooltip('重新核验错题权限'));
      await tester.pump();
      state.api.invalidateSession();
      state.user = {'id': 't2', 'role': 'teacher', 'name': '另一位老师'};
      state.notifyListeners();
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.textContaining('错题q1'), findsNothing);
      pending.complete(reply(wrongBook(media: true)));
      await tester.pumpAndSettle();
      expect(find.textContaining('登录状态已变化'), findsOneWidget);
      expect(find.text('甲同学 · 数学'), findsNothing);
      await tester.tap(find.text('重新验证并加载'));
      await tester.pumpAndSettle();
      expect(calls, 3);
      expect(find.textContaining('登录状态已变化'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('student role cannot request teacher wrong questions', (
    tester,
  ) async {
    var calls = 0;
    final state = stateFor((_) async {
      calls++;
      return reply(wrongBook());
    }, role: 'student');
    await mount(
      tester,
      state,
      TeacherWrongQuestionsPage(
        state: state,
        schoolClass: schoolClass,
        studentId: 's1',
      ),
    );
    expect(calls, 0);
    expect(find.textContaining('登录状态已变化'), findsOneWidget);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });

  for (final width in [390.0, 320.0]) {
    testWidgets(
      'teacher current wrong workflow at${width.toInt()} with large text and system safe bottom',
      (tester) async {
        final height = width == 320 ? 568.0 : 844.0;
        final state = stateFor(
          (request) async => reply(
            request.url.path.endsWith('/wrong-questions')
                ? wrongBook()
                : roster(),
          ),
        );
        await mount(
          tester,
          state,
          TeacherClassStudentsPage(state: state, schoolClass: schoolClass),
          width: width,
          height: height,
          scale: width == 320 ? 1.35 : 1,
        );
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-wrong-roster-${width.toInt()}-0.8.1',
        );
        final entry = find.byKey(const ValueKey('teacher-student-wrong-s1'));
        await reach(tester, entry);
        safeTarget(tester, entry, width, height);
        await tester.tap(entry);
        await tester.pumpAndSettle();
        final field = find.byType(DropdownButtonFormField<String>);
        await reach(tester, field);
        safeTarget(tester, field, width, height);
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-wrong-list-${width.toInt()}-0.8.1',
        );
        await enterFirst(tester);
        await reach(tester, find.text('参考答案'));
        expect(find.text('B'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-wrong-answer-${width.toInt()}-0.8.1',
        );
        safeTarget(tester, find.byType(BackButton), width, height);
      },
    );
  }
}
