// Actual StudyApp layout checks with simulated OS insets. Isolated data only.
// Captures show Flutter renders, not screenshots from an Android device.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/teaching.dart';

import 'teaching_test.dart' as teaching;
import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;
import 'warm_ui_preview_test.dart' as warm;

const _boundary = ValueKey('adaptive-app-render');

class _Screen {
  final String name;
  final Size size;
  final double bottom, scale, left, right;
  const _Screen(
    this.name,
    this.size, {
    this.bottom = 48,
    this.scale = 1,
    this.left = 0,
    this.right = 0,
  });
  double get safeBottom => size.height - bottom;
}

const _screens = [
  _Screen('320-short-three-key', Size(320, 640)),
  _Screen('360-three-key', Size(360, 720)),
  _Screen('390-gesture', Size(390, 844), bottom: 24),
  _Screen('390-no-inset', Size(390, 844), bottom: 0),
  _Screen('320-short-large', Size(320, 640), scale: 1.3),
  _Screen('landscape-gesture', Size(844, 390), bottom: 24, left: 24, right: 24),
  _Screen(
    'landscape-three-key-large',
    Size(844, 390),
    scale: 1.3,
    left: 24,
    right: 24,
  ),
  _Screen(
    'landscape-side-keys',
    Size(844, 390),
    bottom: 0,
    scale: 1.3,
    left: 24,
    right: 48,
  ),
];

void _metrics(WidgetTester tester, _Screen screen, {double keyboard = 0}) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = screen.size;
  tester.view.viewPadding = FakeViewPadding(
    top: 24,
    bottom: screen.bottom,
    left: screen.left,
    right: screen.right,
  );
  tester.view.padding = FakeViewPadding(
    top: 24,
    bottom: keyboard == 0 ? screen.bottom : 0,
    left: screen.left,
    right: screen.right,
  );
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  tester.platformDispatcher.textScaleFactorTestValue = screen.scale;
}

Future<void> _mount(WidgetTester tester, AppState state, _Screen screen) async {
  _metrics(tester, screen);
  addTearDown(() {
    // The Flutter binding has already unmounted/pumped the tree and
    // unregistered TestTextInput before package:test teardown callbacks run.
    // Only reset resources owned by this fixture here; do not drive input or
    // rebuild another widget tree after the binding's cleanup.
    state.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    tester.view.resetViewPadding();
    tester.view.resetViewInsets();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
  await tester.pumpWidget(
    RepaintBoundary(
      key: _boundary,
      child: StudyApp(state: state),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _push(WidgetTester tester, Widget page) async {
  final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);
  unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => page)));
  await tester.pumpAndSettle();
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_boundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final folder = Directory('../runtime/ui-previews');
    await folder.create(recursive: true);
    await File(
      '${folder.path}/adaptive-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _expectAppBounds(WidgetTester tester, _Screen screen) {
  // This checks StudyApp's real boundary, not a SafeArea added by the fixture.
  final bounds = tester.getRect(find.byType(Scaffold).last);
  expect(bounds.left, closeTo(screen.left, .5));
  expect(bounds.right, closeTo(screen.size.width - screen.right, .5));
  expect(bounds.bottom, closeTo(screen.safeBottom, .5));
}

void _expectStickyAction(
  WidgetTester tester,
  Finder action,
  _Screen screen, {
  double keyboard = 0,
}) {
  final bounds = tester.getRect(action);
  final availableBottom = keyboard > 0
      ? screen.size.height - keyboard
      : screen.safeBottom;
  expect(bounds.height, greaterThanOrEqualTo(44));
  expect(bounds.bottom, lessThanOrEqualTo(availableBottom));
  // A second copy of the 48px system inset must not become blank app padding.
  expect(availableBottom - bounds.bottom, inInclusiveRange(6.0, 30.0));
  expect(bounds.left, greaterThanOrEqualTo(screen.left));
  expect(bounds.right, lessThanOrEqualTo(screen.size.width - screen.right));
}

Future<void> _tab(WidgetTester tester, int index, {int count = 4}) async {
  final finder = find.byType(CupertinoTabBar);
  final rect = tester.getRect(finder);
  await tester.tapAt(
    Offset(rect.left + rect.width * (index + .5) / count, rect.top + 22),
  );
  await tester.pumpAndSettle();
  expect(tester.widget<CupertinoTabBar>(finder).currentIndex, index);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(preview.loadPreviewFonts);

  for (final screen in _screens) {
    testWidgets('StudyApp ${screen.name} reserves OS navigation once', (
      tester,
    ) async {
      final state = warm.WarmStudentState(resume: true);
      await _mount(tester, state, screen);
      _expectAppBounds(tester, screen);
      final tabs = tester.getRect(find.byType(CupertinoTabBar));
      expect(tabs.bottom, closeTo(screen.safeBottom, .5));
      expect(tabs.height, inInclusiveRange(44.0, 70.0));
      expect(tester.takeException(), isNull);
      await _capture(tester, 'home-${screen.name}');

      if (screen.name == '360-three-key') {
        // This common small portrait should not need a long dashboard scroll.
        for (final name in ['语文', '数学', '英语', '思想政治', '机械综合']) {
          final subject = find.text(name);
          expect(subject, findsOneWidget);
          expect(tester.getRect(subject).bottom, lessThan(tabs.top));
        }
      }

      await _tab(tester, 1);
      expect(find.byType(ReviewPage), findsOneWidget);
      await _tab(tester, 2);
      expect(find.byType(ClassesPage), findsOneWidget);
      await _tab(tester, 3);
      expect(find.byType(ProfilePage), findsOneWidget);
      await _tab(tester, 0);

      final resume = find.widgetWithText(FilledButton, '继续刷题');
      await tester.ensureVisible(resume);
      await tester.tap(resume);
      await tester.pumpAndSettle();
      expect(find.byType(PracticePage), findsOneWidget);
      _expectAppBounds(tester, screen);
      _expectStickyAction(
        tester,
        find.widgetWithText(FilledButton, '提交答案'),
        screen,
      );
      expect(tester.takeException(), isNull);
      await _capture(tester, 'practice-${screen.name}');
    });
  }

  for (final screen in [_screens[1], _screens[2], _screens[6]]) {
    testWidgets('teacher footer ${screen.name} stays above system keys', (
      tester,
    ) async {
      final state = teaching.teachingState(teaching.TeachingMemoryStore());
      await _mount(tester, state, screen);
      _expectAppBounds(tester, screen);
      final tabs = tester.getRect(find.byType(CupertinoTabBar));
      expect(tabs.bottom, closeTo(screen.safeBottom, .5));
      await tester.ensureVisible(find.text('创建班级练习卷'));
      await tester.tap(find.text('创建班级练习卷'));
      await tester.pumpAndSettle();
      expect(find.byType(PaperBuilderPage), findsOneWidget);
      _expectAppBounds(tester, screen);
      final create = find.widgetWithText(FilledButton, '生成并预览练习卷');
      _expectStickyAction(tester, create, screen);
      await tester.tap(create);
      await tester.pumpAndSettle();
      expect(find.text('请填写卷名，总题量须为1–100题。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'builder-${screen.name}');
    });
  }

  testWidgets('class assignment action leaves a three-key navigation band', (
    tester,
  ) async {
    final screen = _screens[0];
    final state = teaching.teachingState(
      teaching.TeachingMemoryStore(),
      teacher: false,
    );
    await _mount(tester, state, screen);
    await _push(
      tester,
      AssignmentAttemptPage(state: state, assignmentId: 'task-1'),
    );
    _expectAppBounds(tester, screen);
    final submit = find.widgetWithText(FilledButton, '整卷提交');
    _expectStickyAction(tester, submit, screen);
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('确认交卷？'), findsOneWidget);
    await tester.tap(find.text('继续答题'));
    await tester.pumpAndSettle();
    expect(find.byType(CupertinoAlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'assignment-three-key');
  });

  testWidgets('login keyboard consumes IME but not a duplicate system band', (
    tester,
  ) async {
    final screen = _screens[1];
    const keyboard = 280.0;
    final state = warm.WarmStudentState()..user = null;
    await _mount(tester, state, screen);
    _metrics(tester, screen, keyboard: keyboard);
    await tester.pumpAndSettle();
    final account = find.byType(TextField).first;
    await tester.ensureVisible(account);
    await tester.enterText(account, 'preview_student');
    await tester.pumpAndSettle();
    final submit = find.widgetWithText(FilledButton, '登录');
    await tester.ensureVisible(submit);
    await tester.pumpAndSettle();
    final scroll = tester.getRect(find.byType(SingleChildScrollView));
    expect(scroll.bottom, closeTo(screen.size.height - keyboard, .5));
    expect(tester.getRect(submit).bottom, lessThanOrEqualTo(scroll.bottom));
    await tester.tap(submit);
    await tester.pumpAndSettle();
    expect(find.text('请输入账号和密码'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _capture(tester, 'login-keyboard');
  });

  testWidgets(
    'fill keyboard keeps the sticky action reachable and saves answers',
    (tester) async {
      final screen = _screens[1];
      const keyboard = 280.0;
      final question = previewQuestion(type: 'fill');
      final state = warm.WarmStudentState()
        ..practice = {
          'questions': [question],
          'cursor': 0,
          'answers': <String, dynamic>{},
          'submitted': <int>[],
          'durations': <String, dynamic>{},
        };
      await _mount(tester, state, screen);
      await _push(
        tester,
        PracticePage(
          state: state,
          questions: [question],
          resume: state.practice,
        ),
      );
      _metrics(tester, screen, keyboard: keyboard);
      await tester.pumpAndSettle();
      final scroll = find.byType(Scrollable).first;
      for (final entry in ['交集', '并集'].asMap().entries) {
        final input = find.byKey(
          ValueKey('fill-${question['id']}-${entry.key}'),
        );
        await tester.scrollUntilVisible(input, 150, scrollable: scroll);
        await tester.enterText(input, entry.value);
        await tester.pumpAndSettle();
      }
      final submit = find.widgetWithText(FilledButton, '提交答案');
      _expectStickyAction(tester, submit, screen, keyboard: keyboard);
      expect(tester.widget<FilledButton>(submit).onPressed, isNotNull);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(state.queue, hasLength(1));
      expect(state.queue.single['selected'], ['交集', '并集']);
      expect(state.practice!['submitted'], [0]);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'fill-keyboard-submitted');
    },
  );

  testWidgets(
    'short-screen 50-question sheet reaches last item without clipping',
    (tester) async {
      final screen = _screens[4];
      final questions = List<Json>.generate(
        50,
        (i) => {...previewQuestion(), 'id': 'adaptive-$i'},
      );
      final state = warm.WarmStudentState()
        ..practice = {
          'questions': questions,
          'cursor': 0,
          'answers': {
            '0': ['B'],
          },
          'submitted': [0],
          'durations': {'0': 5},
        };
      await _mount(tester, state, screen);
      await _push(
        tester,
        PracticePage(
          state: state,
          questions: questions,
          resume: state.practice,
        ),
      );
      await tester.tap(find.byTooltip('答题卡'));
      await tester.pumpAndSettle();
      final last = find.widgetWithText(FilledButton, '50');
      await tester.scrollUntilVisible(
        last,
        200,
        scrollable: find
            .descendant(
              of: find.byType(BottomSheet),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      // Let the scroll offset reach the rendered frame before reading pixels.
      await tester.pumpAndSettle();
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(screen.safeBottom));
      await _capture(tester, 'answer-card-50-short-large');
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.text('练习 50 / 50'), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(state.practice!['cursor'], 49);
      expect(state.practice!['answers']['0'], ['B']);
      expect(state.practice!['submitted'], [0]);
      expect(tester.takeException(), isNull);
    },
  );
}
