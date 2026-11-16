// Rendering-work regressions, not device FPS measurements.
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/ios_theme.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/question_content.dart';

import 'continuous_practice_widget_test.dart' as fixture;
import 'teaching_test.dart' as teaching;
import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

class _PreviewState extends UiPreviewState {
  void pulse() => notifyListeners();
}

Future<void> mount(
  WidgetTester tester,
  AppState state, {
  double width = 390,
  double height = 844,
  double bottom = 24,
  double scale = 1,
  Widget? page,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  tester.view.padding = FakeViewPadding(top: 24, bottom: bottom);
  tester.view.viewPadding = FakeViewPadding(top: 24, bottom: bottom);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(() {
    state.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: preview.captureBoundary,
      child: page == null
          ? StudyApp(state: state)
          : MaterialApp(
              theme: preview.previewTheme(),
              builder: (context, child) => SafeArea(
                top: false,
                child: LayoutBuilder(
                  builder: (context, bounds) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(size: bounds.biggest),
                    child: child!,
                  ),
                ),
              ),
              home: page,
            ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> removePage(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> tap(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void expectChrome(WidgetTester tester, double safeBottom) {
  expect(find.byType(BackdropFilter), findsNothing);
  final bars = find.byType(CupertinoTabBar);
  if (bars.evaluate().isNotEmpty) {
    expect(tester.widget<CupertinoTabBar>(bars).backgroundColor, iosBackground);
    expect(tester.getRect(bars).bottom, lessThanOrEqualTo(safeBottom));
  }
  for (final surface in tester.widgetList<ColoredBox>(
    find.descendant(
      of: find.byType(IOSGlass),
      matching: find.byType(ColoredBox),
    ),
  )) {
    expect(surface.color.a, 1);
  }
}

Json practice({int cursor = 0, bool firstSubmitted = false}) => {
  'questions': [fixture.question('first'), fixture.question('second')],
  'subject_id': 'math',
  'mode': 'all',
  'session_id': 'render-clock-session',
  'cursor': cursor,
  'answers': firstSubmitted
      ? {
          '0': ['A'],
        }
      : <String, dynamic>{},
  'submitted': firstSubmitted ? [0] : <int>[],
  'durations': {'0': 4, '1': 9},
};

PracticePage practicePage(AppState state) => PracticePage(
  state: state,
  questions: List<Json>.from(state.practice!['questions']),
  resume: state.practice,
);

void main() {
  setUpAll(preview.loadPreviewFonts);

  testWidgets(
    'student chrome is opaque, safe and interactive while theme is reused',
    (tester) async {
      final state = _PreviewState();
      await mount(tester, state);
      final theme = tester.widget<MaterialApp>(find.byType(MaterialApp)).theme;
      expectChrome(tester, 820);
      await preview.capture(tester, 'render-performance-home-390-0.8.2');
      state.busy = true;
      state.pulse();
      await tester.pump();
      expect(
        identical(
          tester.widget<MaterialApp>(find.byType(MaterialApp)).theme,
          theme,
        ),
        isTrue,
      );
      await tap(
        tester,
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('复习'),
        ),
      );
      expect(
        tester
            .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
            .currentIndex,
        1,
      );
      expect(find.text('把错过的题，变成真正掌握的知识。'), findsOneWidget);
      expectChrome(tester, 820);
      expect(tester.takeException(), isNull);
      await removePage(tester);
    },
  );

  testWidgets(
    'teacher 320 chrome has no implicit Cupertino blur and retains tab actions',
    (tester) async {
      final store = fixture.StreamStore();
      final state =
          AppState(
              store,
              Api(
                store,
                client: MockClient(
                  (request) async => http.Response(
                    jsonEncode(
                      request.url.path.endsWith('/catalog')
                          ? teaching.teachingCatalog()
                          : [],
                    ),
                    200,
                    headers: {
                      'content-type': 'application/json; charset=utf-8',
                    },
                  ),
                ),
              )..consented = true,
            )
            ..ready = true
            ..user = {
              'id': 'render-teacher',
              'role': 'teacher',
              'activated': true,
              'name': '测试教师',
            };
      await mount(
        tester,
        state,
        width: 320,
        height: 640,
        bottom: 48,
        scale: 1.3,
      );
      expectChrome(tester, 592);
      await preview.capture(tester, 'render-performance-teacher-320-0.8.2');
      await tap(
        tester,
        find.descendant(
          of: find.byType(CupertinoTabBar),
          matching: find.text('班级'),
        ),
      );
      expect(
        tester
            .widget<CupertinoTabBar>(find.byType(CupertinoTabBar))
            .currentIndex,
        1,
      );
      expect(find.text('我的班级'), findsOneWidget);
      expectChrome(tester, 592);
      expect(tester.takeException(), isNull);
      await removePage(tester);
    },
  );

  testWidgets(
    'clock ticks update seconds without recreating question and option widgets and keep periodic stash',
    (tester) async {
      final store = fixture.StreamStore();
      final state = fixture.school(store, (_) async => fixture.ok([]))
        ..practice = practice();
      await mount(tester, state, page: practicePage(state));
      final stem = find.byWidgetPredicate(
        (widget) => widget is QuestionContent && widget.text == '本批题目first',
      );
      final option = find.byWidgetPredicate(
        (widget) => widget is QuestionContent && widget.text == '选项甲',
      );
      final originalStem = tester.widget<QuestionContent>(stem);
      final originalOption = tester.widget<QuestionContent>(option);
      expect(find.text('4秒'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('6秒'), findsOneWidget);
      expect(
        identical(tester.widget<QuestionContent>(stem), originalStem),
        isTrue,
      );
      expect(
        identical(tester.widget<QuestionContent>(option), originalOption),
        isTrue,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(fixture.persisted(store, state)['practice']['durations']['0'], 9);
      expect(
        identical(tester.widget<QuestionContent>(stem), originalStem),
        isTrue,
      );
      expectChrome(tester, 820);
      await preview.capture(tester, 'render-performance-practice-390-0.8.2');
      await removePage(tester);
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resumed 320 clock pauses in background, submits exact duration and switches questions correctly',
    (tester) async {
      final store = fixture.StreamStore();
      final state = fixture.school(store, (_) async => fixture.ok([]))
        ..practice = practice(cursor: 1, firstSubmitted: true);
      await mount(
        tester,
        state,
        width: 320,
        height: 640,
        bottom: 48,
        scale: 1.3,
        page: practicePage(state),
      );
      expect(find.text('9秒'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('11秒'), findsOneWidget);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(seconds: 4));
      expect(find.text('11秒'), findsOneWidget);
      expect(fixture.persisted(store, state)['practice']['durations']['1'], 11);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('12秒'), findsOneWidget);
      final submit = find.widgetWithText(FilledButton, '提交答案');
      final bounds = tester.getRect(submit);
      expect(bounds.height, greaterThanOrEqualTo(44));
      expect(bounds.bottom, lessThanOrEqualTo(592));
      expectChrome(tester, 592);
      await preview.capture(tester, 'render-performance-practice-320-0.8.2');
      await tap(tester, find.text('选项甲'));
      await tap(tester, submit);
      expect(state.queue, hasLength(1));
      expect(state.queue.single['duration_seconds'], 12);
      expect(
        fixture.persisted(store, state)['queue'][0]['duration_seconds'],
        12,
      );
      await tester.pump(const Duration(seconds: 2));
      await tester.scrollUntilVisible(
        find.byIcon(Icons.timer_outlined),
        -180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('12秒'), findsOneWidget);
      await tap(tester, find.widgetWithText(TextButton, '上一题'));
      expect(find.text('4秒'), findsOneWidget);
      await tap(tester, find.widgetWithText(FilledButton, '下一题'));
      expect(find.text('12秒'), findsOneWidget);
      expect(state.practice!['durations']['1'], 12);
      expect(tester.takeException(), isNull);
      await removePage(tester);
    },
  );
}
