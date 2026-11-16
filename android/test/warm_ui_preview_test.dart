// Isolated Flutter widget renders for the selected warm-paper redesign.
// These are not screenshots captured on an Android device and never use live data.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/teacher_student_analytics.dart';
import 'package:zhikaotong/teaching.dart';

import 'teacher_student_analytics_test.dart' as analytics;
import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

const _boundary = ValueKey('warm-ui-render');
const _seed = '0123456789abcdef0123456789abcdef';
const _hash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _subjects = [
  {'id': 'chinese', 'name': '语文', 'total': 125},
  {'id': 'math', 'name': '数学', 'total': 80},
  {'id': 'english', 'name': '英语', 'total': 663},
  {'id': 'politics', 'name': '思想政治', 'total': 172},
  {'id': 'mechanics', 'name': '机械专业综合理论', 'total': 817},
];
const _class = {'id': 'warm-class', 'name': '2027机械升学一班'};

http.Response _response(dynamic value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Json _streamPractice(Json question, {bool answered = false}) => {
  'questions': [question],
  'cursor': 0,
  'answers': <String, dynamic>{},
  'submitted': <int>[],
  'durations': <String, dynamic>{},
  'stream': {
    'session_id': 'warm-isolated-session',
    'subject_id': 'math',
    'type': null,
    'difficulty': null,
    'shuffle': false,
    'shuffle_options': false,
    'round': 1,
    'answered': answered ? 12 : 0,
    'correct': answered ? 10 : 0,
    'study_seconds': answered ? 480 : 0,
    'seed': _seed,
    'version': 3,
    'pool_hash': _hash,
    'offset': answered ? 12 : 0,
    'next_offset': answered ? 13 : 1,
    'has_more': true,
    'total': 80,
  },
};

class WarmStudentState extends AppState {
  final List<http.Request> requests;
  WarmStudentState({bool resume = false})
    : this._(UiPreviewStore(), <http.Request>[], resume);
  WarmStudentState._(UiPreviewStore storage, this.requests, bool resume)
    : super(
        storage,
        Api(
          storage,
          client: MockClient((request) async {
            requests.add(request);
            final path = request.url.path;
            if (path.endsWith('/questions/continuous')) {
              final offset = int.parse(
                request.url.queryParameters['offset'] ?? '0',
              );
              return _response({
                'questions': [
                  {...previewQuestion(), 'id': 'warm-question-$offset'},
                ],
                'version': 3,
                'seed': _seed,
                'pool_hash': _hash,
                'offset': offset,
                'next_offset': offset + 1,
                'total': 80,
                'has_more': true,
              });
            }
            if (path.endsWith('/bank/version')) {
              return _response({
                'version': 3,
                'subjects': [
                  for (final row in _subjects) {...row, 'count': row['total']},
                ],
              });
            }
            if (path.endsWith('/student/assignments')) {
              return _response([
                {
                  'id': 'warm-task',
                  'paper_title': '集合与函数巩固练习',
                  'class_name': _class['name'],
                  'question_count': 10,
                  'full_score': 10,
                  'submitted': false,
                  'available': true,
                },
              ]);
            }
            if (path.endsWith('/student/deletion')) {
              return _response({'status': 'none', 'execute_at': null});
            }
            if (path.endsWith('/questions') ||
                path.endsWith('/student/wrong')) {
              return _response([previewQuestion()]);
            }
            return _response(<dynamic>[]);
          }),
        )..consented = true,
      ) {
    final sample = UiPreviewState();
    ready = true;
    user = {
      ...sample.user!,
      'id': 'warm-student',
      'name': '林同学',
      'username': 'lin_2027',
    };
    config = sample.config;
    dashboard = {...sample.dashboard, 'announcements': <dynamic>[]};
    subjects = [for (final row in _subjects) Map<String, dynamic>.from(row)];
    classes = [
      {
        ..._class,
        'teacher_name': '陈老师',
        'status': 'active',
        'visibility': config['teacher_visibility'],
      },
    ];
    favorites = {'favorite-a', 'favorite-b', 'favorite-c'};
    doubts = {'doubt-a'};
    if (resume) practice = _streamPractice(previewQuestion(), answered: true);
    sample.dispose();
  }

  @override
  Future<void> reload() async {}
  @override
  Future<void> sync() async {}
  @override
  void scheduleSync() {}
}

Json _catalog() => {
  'subjects': [
    for (final row in _subjects)
      {
        'id': row['id'],
        'name': row['name'],
        'available': {
          'single': row['total'],
          'multiple': 0,
          'fill': 0,
          'judge': 0,
        },
      },
  ],
  'classes': [
    {
      ..._class,
      'subject_ids': [for (final row in _subjects) row['id']],
    },
  ],
};

Json _paper() => {
  'id': 'warm-paper',
  'title': '集合与函数巩固练习',
  'question_count': 1,
  'full_score': 2,
  'shuffle_questions': true,
  'shuffle_options': false,
  'created_at': '2026-11-02T08:00:00Z',
  'rules': [
    {'subject_id': 'math', 'type': 'single', 'count': 1, 'score': 2},
  ],
  'questions': [
    {...previewQuestion(), 'score': 2},
  ],
};

AppState _teacher({List<http.Request>? requests}) {
  final store = UiPreviewStore();
  final api = Api(
    store,
    client: MockClient((request) async {
      requests?.add(request);
      final path = request.url.path;
      if (path.endsWith('/analytics')) {
        final result = analytics.aggregate(
          classId: '${_class['id']}',
          days: int.parse(request.url.queryParameters['days'] ?? '30'),
          subject: request.url.queryParameters['subject_id'] ?? '',
        );
        result['class'] = _class;
        result['student'] = {
          'id': 's1',
          'name': '林同学',
          'username': 'lin_2027',
          'status': 'active',
        };
        return _response(result);
      }
      if (path.endsWith('/students')) {
        return _response({
          'class': _class,
          'students': [
            {
              'id': 's1',
              'name': '林同学',
              'username': 'lin_2027',
              'status': 'active',
            },
            {
              'id': 's2',
              'name': '许同学',
              'username': 'xu_2027',
              'status': 'active',
            },
            {
              'id': 'left',
              'name': '已离班样例',
              'username': 'left',
              'status': 'left',
            },
          ],
        });
      }
      if (path.endsWith('/teaching/catalog')) return _response(_catalog());
      if (path.endsWith('/teaching/papers')) return _response([_paper()]);
      if (path.endsWith('/teaching/assignments')) {
        return _response([
          {
            'id': 'warm-task',
            'paper_title': _paper()['title'],
            'class_name': _class['name'],
            'submitted_count': 1,
            'recipient_count': 2,
          },
        ]);
      }
      if (path.contains('/teaching/papers/')) return _response(_paper());
      return _response({});
    }),
  )..consented = true;
  return AppState(store, api)
    ..ready = true
    ..user = {
      'id': 'warm-teacher',
      'name': '陈老师',
      'role': 'teacher',
      'username': 'chen_teacher',
      'must_change_password': false,
    };
}

Future<void> _fonts() => preview.loadPreviewFonts();

Future<void> _mount(
  WidgetTester tester,
  Widget page, {
  double width = 390,
  double scale = 1,
  bool safeArea = false,
  bool push = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: key,
      theme: preview.previewTheme(),
      builder: (context, child) => RepaintBoundary(
        key: _boundary,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            padding: safeArea
                ? const EdgeInsets.only(top: 24, bottom: 20)
                : EdgeInsets.zero,
          ),
          child: child!,
        ),
      ),
      home: push ? const Scaffold() : page,
    ),
  );
  if (push) {
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => page));
  }
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
    final folder = Directory(
      '${Directory.current.parent.path}/runtime/ui-previews',
    );
    await folder.create(recursive: true);
    await File(
      '${folder.path}/warm-$name.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
}

Future<void> _tapTab(WidgetTester tester, int index, int count) async {
  final tab = find.byType(CupertinoTabBar);
  final rectangle = tester.getRect(tab);
  await tester.tapAt(
    Offset(
      rectangle.left + rectangle.width * (index + .5) / count,
      rectangle.top + 22,
    ),
  );
  await tester.pumpAndSettle();
  expect(tester.widget<CupertinoTabBar>(tab).currentIndex, index);
}

Future<void> _tapText(WidgetTester tester, String label) async {
  final finder = find.text(label).last;
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(_fonts);

  for (final compact in [false, true]) {
    final width = compact ? 320.0 : 390.0;
    final scale = compact ? 1.3 : 1.0;
    final suffix = compact ? '320-large' : '390';
    for (final screen in ['home', 'login', 'review', 'classes', 'profile']) {
      testWidgets('warm $screen $suffix reads and navigates', (tester) async {
        final state = WarmStudentState(resume: true);
        await _mount(
          tester,
          screen == 'login' ? LoginPage(state: state) : HomeShell(state: state),
          width: width,
          scale: scale,
          safeArea: compact,
        );
        final index = {'review': 1, 'classes': 2, 'profile': 3}[screen];
        if (index != null) await _tapTab(tester, index, 4);
        expect(tester.takeException(), isNull);
        expect(find.textContaining('待归类'), findsNothing);
        expect(find.textContaining('下载离线题库'), findsNothing);
        expect(find.textContaining('自建题库'), findsNothing);
        await _capture(tester, '$screen-$suffix');
        if (screen == 'home') {
          await _tapText(tester, '继续刷题');
          expect(find.byType(PracticePage), findsOneWidget);
          expect(state.queue, isEmpty);
          expect(tester.takeException(), isNull);
          await _capture(tester, 'continued-practice-$suffix');
        }
        await _clean(tester, state);
      });
    }

    testWidgets(
      'warm practice settings $suffix starts shuffled continuous mode',
      (tester) async {
        final state = WarmStudentState();
        await _mount(
          tester,
          Scaffold(
            body: Builder(
              builder: (context) => Center(
                child: TextButton(
                  key: const ValueKey('open-warm-settings'),
                  onPressed: () =>
                      openPractice(context, state, subject: 'math'),
                  child: const Text('打开练习设置'),
                ),
              ),
            ),
          ),
          width: width,
          scale: scale,
          safeArea: compact,
        );
        await tester.tap(find.byKey(const ValueKey('open-warm-settings')));
        await tester.pumpAndSettle();
        await _capture(tester, 'practice-settings-$suffix');
        for (final label in ['题目乱序', '选项乱序']) {
          await _tapText(tester, label);
        }
        final start = find.byType(FilledButton).last;
        await tester.ensureVisible(start);
        await tester.tap(start);
        await tester.pumpAndSettle();
        expect(find.byType(PracticePage), findsOneWidget);
        final request = state.requests.firstWhere(
          (request) => request.url.path.endsWith('/questions/continuous'),
        );
        expect(request.url.queryParameters['subject_id'], 'math');
        expect(request.url.queryParameters['shuffle'], 'true');
        expect(state.practice!['stream']['shuffle_options'], true);
        expect(state.queue, isEmpty);
        expect(tester.takeException(), isNull);
        await _capture(tester, 'new-continuous-$suffix');
        await _clean(tester, state);
      },
    );

    for (final screen in [
      'teacher',
      'builder',
      'paper',
      'roster',
      'analytics',
    ]) {
      testWidgets('warm $screen $suffix layout and entry', (tester) async {
        final state = _teacher();
        final page = switch (screen) {
          'teacher' => TeacherShell(
            state: state,
            onPassword: (_) {},
            onLegal: (_) {},
          ),
          'builder' => PaperBuilderPage(state: state, catalog: _catalog()),
          'paper' => TeacherPaperPage(
            state: state,
            paperId: 'warm-paper',
            catalog: _catalog(),
          ),
          'roster' => TeacherClassStudentsPage(
            state: state,
            schoolClass: _class,
          ),
          _ => TeacherStudentAnalyticsPage(
            state: state,
            schoolClass: _class,
            studentId: 's1',
          ),
        };
        await _mount(
          tester,
          page,
          width: width,
          scale: scale,
          safeArea: compact,
          push: screen != 'teacher',
        );
        expect(tester.takeException(), isNull);
        await _capture(tester, '$screen-$suffix');
        if (screen == 'teacher') {
          await _tapText(tester, '创建班级练习卷');
          expect(find.byType(PaperBuilderPage), findsOneWidget);
        }
        if (screen == 'roster') {
          expect(find.text('已离班样例'), findsNothing);
          await _tapText(tester, '林同学');
          expect(find.byType(TeacherStudentAnalyticsPage), findsOneWidget);
        }
        if (screen == 'analytics') {
          await tester.scrollUntilVisible(
            find.text('错误分布'),
            260,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await _capture(tester, 'analytics-errors-$suffix');
          await tester.scrollUntilVisible(
            find.text('本班任务成绩'),
            300,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          await _capture(tester, 'analytics-classwork-$suffix');
        }
        expect(tester.takeException(), isNull);
        await _clean(tester, state);
      });
    }
  }

  testWidgets(
    'warm second round home shows round progress rather than lifetime answers',
    (tester) async {
      final state = WarmStudentState()
        ..practice = _streamPractice(previewQuestion());
      final stream = state.practice!['stream'] as Map;
      stream['round'] = 2;
      stream['answered'] = 80;
      stream['correct'] = 70;
      stream['offset'] = 0;
      await _mount(tester, HomeShell(state: state));
      expect(find.text('全部题目 · 综合练习 · 第2轮 · 已练0 / 80题'), findsOneWidget);
      expect(find.textContaining('已练80 / 80题'), findsNothing);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'second-round-home-390');
      await _clean(tester, state);
    },
  );

  testWidgets(
    'warm 50 question answer card scrolls to last question without losing saved answers',
    (tester) async {
      final questions = List<Json>.generate(
        50,
        (index) => {
          ...previewQuestion(),
          'id': 'warm-fifty-$index',
          'stem': '第${index + 1}题：已知集合A与B，求它们的交集。',
        },
      );
      final saved = <String, dynamic>{
        'client_uuid': 'warm-fifty-saved-record',
        'question_id': 'warm-fifty-0',
        'question_version': 3,
        'selected': ['B'],
        'duration_seconds': 7,
        'answered_at': '2026-11-03T02:00:00Z',
      };
      final state = WarmStudentState()
        ..practice = {
          'questions': questions,
          'cursor': 0,
          'answers': {
            '0': ['B'],
          },
          'submitted': [0],
          'durations': {'0': 7},
        }
        ..queue = [saved];
      await state.persist();
      await _mount(
        tester,
        PracticePage(
          state: state,
          questions: questions,
          resume: state.practice,
        ),
        width: 320,
        scale: 1.3,
        safeArea: true,
        push: true,
      );
      await tester.tap(find.byTooltip('答题卡'));
      await tester.pumpAndSettle();
      final lastQuestion = find.widgetWithText(FilledButton, '50');
      final sheetScroll = find
          .descendant(
            of: find.byType(BottomSheet),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        lastQuestion,
        240,
        scrollable: sheetScroll,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _capture(tester, 'answer-card-50-320-large');
      await tester.tap(lastQuestion);
      await tester.pumpAndSettle();
      expect(find.text('练习 50 / 50'), findsOneWidget);
      expect(find.byType(BottomSheet), findsNothing);
      // The existing periodic stash persists navigation after five seconds.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(state.practice!['cursor'], 49);
      expect(state.practice!['submitted'], [0]);
      expect(state.practice!['answers']['0'], ['B']);
      expect(state.queue, [saved]);
      final persisted =
          (state.store as UiPreviewStore).values['data_${state.cacheKey}'];
      expect(persisted['practice']['cursor'], 49);
      expect(persisted['queue'], [saved]);
      expect(tester.takeException(), isNull);
      await _capture(tester, 'practice-question-50-320-large');
      await _clean(tester, state);
    },
  );

  for (final answered in [0, 3]) {
    testWidgets(
      'warm home distinguishes $answered answers from an absent accuracy',
      (tester) async {
        final state = WarmStudentState();
        state.dashboard['stats'] = {
          ...state.dashboard['stats'] as Map,
          'answered': answered,
          'correct': 0,
          'accuracy': 0,
          'today_answered': 0,
          'streak': 0,
        };
        await _mount(tester, HomeShell(state: state));
        expect(find.text(answered == 0 ? '正确率—' : '正确率0%'), findsOneWidget);
        expect(find.text(answered == 0 ? '正确率0%' : '正确率—'), findsNothing);
        expect(tester.takeException(), isNull);
        await _capture(
          tester,
          answered == 0 ? 'empty-home-390' : 'all-wrong-home-390',
        );
        await _clean(tester, state);
      },
    );
  }

  // The optional source is an existing, unmodified local Word import preview.
  // This test renders actual retained images/formulas, not a replacement drawing.
  final wordSource = File('../runtime/word-reconciled-preview.json');
  if (!wordSource.existsSync()) {
    test(
      'warm original Word continuous media preview requires local source',
      () {},
      skip: true,
    );
  } else {
    final source = jsonDecode(wordSource.readAsStringSync()) as Map;
    final original = (source['questions'] as List).cast<Map>().firstWhere(
      (row) => row['source_index'] == 1046,
    );
    for (final width in [390.0, 320.0]) {
      testWidgets(
        'warm original Word continuous media ${width.toInt()} before and after answer',
        (tester) async {
          final question = Map<String, dynamic>.from(original)
            ..['id'] = original['source_key']
            ..['version'] = 3
            ..['subject_id'] = 'math';
          final state = WarmStudentState()
            ..practice = _streamPractice(question);
          await _mount(
            tester,
            PracticePage(
              state: state,
              questions: [question],
              resume: state.practice,
            ),
            width: width,
            scale: width == 320 ? 1.3 : 1,
            safeArea: width == 320,
            push: true,
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)),
          );
          await tester.pumpAndSettle();
          expect(find.byType(Image), findsWidgets);
          expect(find.textContaining('图片缺失或校验失败'), findsNothing);
          await _capture(tester, 'continuous-media-${width.toInt()}-question');
          final inputs = find.byType(TextFormField);
          // Long original stems are built lazily; first scroll until the input
          // exists, rather than calling ensureVisible on an unbuilt child.
          await tester.scrollUntilVisible(
            inputs,
            260,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.pumpAndSettle();
          final input = inputs.first;
          final expectedAnswer = ((question['answer'] as List).first as List)
              .first
              .toString();
          await tester.enterText(input, expectedAnswer);
          tester.testTextInput.hide();
          // enterText dispatches onChanged, but does not rebuild the sticky
          // action. Pump before tapping, so this tests an enabled submit button.
          await tester.pumpAndSettle();
          expect(state.practice!['answers']['0'], [expectedAnswer]);
          final submitButton = find.widgetWithText(FilledButton, '提交答案');
          expect(
            tester.widget<FilledButton>(submitButton).onPressed,
            isNotNull,
          );
          await _tapText(tester, '提交答案');
          expect(state.queue, hasLength(1));
          expect(state.queue.single['question_id'], question['id']);
          expect(state.practice!['submitted'], [0]);
          await _capture(tester, 'continuous-media-${width.toInt()}-submitted');
          expect(tester.takeException(), isNull);
          await _clean(tester, state);
        },
      );
    }
  }
}
