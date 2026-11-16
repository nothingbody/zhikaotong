import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/teaching.dart';

import 'teaching_test.dart' as fixture;
import 'ui_render_test.dart' as preview;

const assignment = {
  'id': 'task-1',
  'paper_id': 'paper-1',
  'paper_title': '数学课堂巩固',
  'class_name': '升学一班',
  'question_count': 2,
  'submitted_count': 1,
  'recipient_count': 2,
};
const pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/K1sAAAAASUVORK5CYII=';
final imageHash = sha256.convert(base64Decode(pixel)).toString();

Json submitted({bool allCorrect = false, bool image = false}) => {
  'assignment': assignment,
  'student': {
    'id': 'student-1',
    'name': '甲同学',
    'username': 'alpha',
    'role': 'student',
  },
  'result': {
    'assignment_id': 'task-1',
    'score': allCorrect ? 5 : 3,
    'full_score': 5,
    'correct': allCorrect ? 2 : 1,
    'total': 2,
    'submitted_at': '2026-11-03T03:20:00Z',
    'questions': [
      {
        ...fixture.sampleChoice(),
        'stem': '需要讲评的偶数判断${image ? ' {{img:$imageHash}}' : ''}',
        'score': 2,
        'awarded_score': allCorrect ? 2 : 0,
        'correct': allCorrect,
        'selected': [allCorrect ? 'A' : 'B'],
        if (image)
          'media': {
            imageHash: {
              'mime': 'image/png',
              'data': pixel,
              'width': 1,
              'height': 1,
            },
          },
      },
      {
        ...fixture.sampleChoice(),
        'id': 'choice-2',
        'stem': '已经答对的整数题',
        'score': 3,
        'awarded_score': 3,
        'correct': true,
        'selected': ['A'],
      },
    ],
  },
};

Json resultList({bool allCorrect = false}) => {
  'assignment': assignment,
  'results': [
    {
      'user_id': 'student-1',
      'name': '甲同学',
      'username': 'alpha',
      'submitted': true,
      'correct': allCorrect ? 2 : 1,
      'total': 2,
      'score': allCorrect ? 5 : 3,
      'full_score': 5,
      'submitted_at': '2026-11-03T03:20:00Z',
    },
    {
      'user_id': 'student-2',
      'name': '乙同学',
      'username': 'beta',
      'submitted': false,
      'correct': null,
      'total': 2,
    },
  ],
};

http.Response reply(dynamic value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AppState school(
  fixture.TeachingMemoryStore store,
  Future<http.Response> Function(http.Request) handler,
) => AppState(store, Api(store, client: MockClient(handler))..consented = true)
  ..ready = true
  ..user = {'id': 'teacher-1', 'role': 'teacher', 'name': '陈老师'};

Widget detail(AppState state) => TeacherAssignmentStudentResultPage(
  state: state,
  assignment: assignment,
  studentId: 'student-1',
);

Future<void> mount(
  WidgetTester tester,
  Widget page, {
  double width = 390,
  double height = 844,
  double scale = 1,
  bool settle = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  await tester.pumpWidget(
    MaterialApp(
      theme: preview.previewTheme(),
      builder: (context, child) => RepaintBoundary(
        key: preview.captureBoundary,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            padding: const EdgeInsets.only(top: 24, bottom: 24),
          ),
          child: child!,
        ),
      ),
      home: page,
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

Future<void> clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> reveal(WidgetTester tester, Finder target) async {
  final scrollable = find
      .descendant(
        of: find.byType(ListView).last,
        matching: find.byType(Scrollable),
      )
      .first;
  await tester.scrollUntilVisible(target, 180, scrollable: scrollable);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(preview.loadPreviewFonts);

  testWidgets(
    'grade roster opens the selected student wrong answers read only',
    (tester) async {
      final store = fixture.TeachingMemoryStore();
      final requests = <http.Request>[];
      final state = school(store, (request) async {
        requests.add(request);
        return request.url.path.endsWith('/results')
            ? reply(resultList())
            : reply(submitted());
      });
      state.queue = [
        {'client_uuid': 'keep-autonomous-history'},
      ];
      final practice = <String, dynamic>{'questions': <Json>[], 'cursor': 3};
      state.practice = practice;
      final oldQueue = jsonEncode(state.queue);
      await mount(
        tester,
        TeachingResultsPage(state: state, assignment: assignment),
      );
      await reveal(tester, find.text('查看本卷错题'));
      expect(find.text('本卷错题 1题'), findsOneWidget);
      expect(find.text('查看本卷错题'), findsOneWidget);
      await tester.tap(find.text('查看本卷错题'));
      await tester.pumpAndSettle();
      expect(
        requests.last.url.path,
        '/api/teaching/assignments/task-1/students/student-1/result',
      );
      expect(requests.last.headers['X-Question-Content'], 'media-v1');
      expect(find.text('只看错题（1题）'), findsOneWidget);
      expect(find.textContaining('已经答对的整数题'), findsNothing);
      await reveal(tester, find.textContaining('学生作答：B'));
      expect(find.textContaining('参考答案：A'), findsOneWidget);
      await reveal(tester, find.text('只看错题（1题）'));
      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();
      await reveal(tester, find.textContaining('已经答对的整数题'));
      expect(find.textContaining('已经答对的整数题'), findsOneWidget);
      expect(requests.every((request) => request.method == 'GET'), true);
      expect(jsonEncode(state.queue), oldQueue);
      expect(identical(state.practice, practice), true);
      expect(store.writes, 0);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets('a full score remains viewable and can reveal the whole paper', (
    tester,
  ) async {
    final state = school(
      fixture.TeachingMemoryStore(),
      (_) async => reply(submitted(allCorrect: true)),
    );
    await mount(tester, detail(state));
    await reveal(tester, find.text('本卷全部答对'));
    expect(find.text('只看错题（0题）'), findsOneWidget);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await reveal(tester, find.textContaining('已经答对的整数题'));
    expect(find.textContaining('已经答对的整数题'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await clean(tester, state);
  });

  for (final status in [409, 503]) {
    testWidgets('unsubmitted or failed result $status can be retried safely', (
      tester,
    ) async {
      var failed = true;
      final requests = <http.Request>[];
      final state = school(fixture.TeachingMemoryStore(), (request) async {
        requests.add(request);
        return failed
            ? reply({'detail': '网络临时不可用'}, status)
            : reply(submitted());
      });
      await mount(tester, detail(state));
      expect(
        find.textContaining(status == 409 ? '尚未交卷' : '网络临时不可用'),
        findsOneWidget,
      );
      expect(find.textContaining('甲同学'), findsNothing);
      failed = false;
      await tester.tap(find.text('重新验证并加载'));
      await tester.pumpAndSettle();
      expect(find.text('只看错题（1题）'), findsOneWidget);
      expect(requests, hasLength(2));
      expect(requests.every((request) => request.method == 'GET'), true);
      await clean(tester, state);
    });
  }

  for (final deniedStatus in [403, 404]) {
    testWidgets('access $deniedStatus clears the student snapshot on refresh', (
      tester,
    ) async {
      var denied = false;
      final state = school(
        fixture.TeachingMemoryStore(),
        (_) async => denied
            ? reply({'detail': '学生已离班'}, deniedStatus)
            : reply(submitted()),
      );
      await mount(tester, detail(state));
      expect(find.textContaining('甲同学'), findsOneWidget);
      denied = true;
      await tester.tap(find.byTooltip('刷新学生本卷作答'));
      await tester.pumpAndSettle();
      expect(find.textContaining('当前无权查看此学生作答'), findsOneWidget);
      expect(find.textContaining('甲同学'), findsNothing);
      expect(find.textContaining('学生作答：'), findsNothing);
      expect(find.textContaining('需要讲评的偶数判断'), findsNothing);
      await clean(tester, state);
    });
  }

  testWidgets(
    'background disposes the image viewer and resume rechecks access',
    (tester) async {
      var denied = false, calls = 0;
      final state = school(fixture.TeachingMemoryStore(), (_) async {
        calls++;
        return denied
            ? reply({'detail': '当前成员已退出'}, 404)
            : reply(submitted(image: true));
      });
      await mount(tester, detail(state));
      await reveal(tester, find.byType(Image).first);
      await tester.tap(find.byType(Image).first);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
      expect(find.textContaining('甲同学'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      denied = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('当前无权查看此学生作答'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets('identity change clears detail and rejects a delayed result', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var calls = 0;
    final state = school(fixture.TeachingMemoryStore(), (_) {
      calls++;
      return pending.future;
    });
    await mount(tester, detail(state), settle: false);
    await tester.pump();
    state.api.invalidateSession();
    state.user = {'id': 'other-teacher', 'role': 'teacher'};
    await state.run(() async {});
    await tester.pump();
    pending.complete(reply(submitted()));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前账号已变更'), findsOneWidget);
    expect(find.textContaining('甲同学'), findsNothing);
    expect(find.text('只看错题（1题）'), findsNothing);
    expect(calls, 1);
    expect(tester.takeException(), isNull);
    await clean(tester, state);
  });

  for (final width in [320.0, 390.0]) {
    testWidgets(
      'read-only student paper ${width.toInt()}px keeps system inset',
      (tester) async {
        final compact = width == 320;
        final height = compact ? 568.0 : 844.0;
        final state = school(
          fixture.TeachingMemoryStore(),
          (_) async => reply(submitted()),
        );
        await mount(
          tester,
          detail(state),
          width: width,
          height: height,
          scale: compact ? 1.35 : 1,
        );
        expect(tester.takeException(), isNull);
        expect(
          tester.getRect(find.byType(ListView).last).bottom,
          lessThanOrEqualTo(height - 24),
        );
        await preview.capture(
          tester,
          'teacher-student-assignment-0.8.1-${width.toInt()}-top',
        );
        await reveal(tester, find.textContaining('学生作答：B'));
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-student-assignment-0.8.1-${width.toInt()}-wrong',
        );
        expect(find.byType(TextField), findsNothing);
        expect(find.text('提交答案'), findsNothing);
        await clean(tester, state);
      },
    );
  }
}
