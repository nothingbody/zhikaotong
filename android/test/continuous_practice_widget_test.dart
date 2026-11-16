import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

import 'ui_render_test.dart' as preview;

const roundSeed = '0123456789abcdef0123456789abcdef';
const nextRoundSeed = '11111111111111111111111111111111';
const poolHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class StreamStore extends LocalStore {
  final values = <String, dynamic>{};
  bool failNext = false;
  Completer<void>? gateNextWrite;
  @override
  Future<dynamic> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  @override
  Future<void> write(String key, dynamic value) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    final gate = gateNextWrite;
    gateNextWrite = null;
    if (gate != null) await gate.future;
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<void> secureWrite(String key, String? value) async {}
}

Json question(String id) => {
  'id': id,
  'subject_id': 'math',
  'version': 3,
  'type': 'single',
  'stem': '本批题目$id',
  'options': [
    {'key': 'A', 'text': '选项甲'},
    {'key': 'B', 'text': '选项乙'},
  ],
  'answer': ['A'],
  'explanation': '原题解析',
  'source': '原题来源',
};

Json initialPractice({String id = 'first', bool hasMore = true}) => {
  'questions': [question(id)],
  'cursor': 0,
  'answers': {
    '0': ['A'],
  },
  'submitted': [0],
  'durations': {'0': 7},
  'stream': {
    'session_id': 'saved-stream-session',
    'subject_id': 'math',
    'type': null,
    'difficulty': null,
    'shuffle': false,
    'shuffle_options': false,
    'round': 1,
    'answered': 0,
    'correct': 0,
    'study_seconds': 0,
    'seed': roundSeed,
    'version': 3,
    'pool_hash': poolHash,
    'offset': 0,
    'next_offset': 1,
    'has_more': hasMore,
    'total': hasMore ? 2 : 1,
  },
};

Json savedAnswer({String id = 'first'}) => {
  'client_uuid': 'already-saved-record',
  'question_id': id,
  'question_version': 3,
  'selected': ['A'],
  'duration_seconds': 7,
};

Json nextPage({String id = 'second', bool newRound = false}) => {
  'questions': [question(id)],
  'version': 3,
  'pool_hash': poolHash,
  'seed': newRound ? nextRoundSeed : roundSeed,
  'offset': newRound ? 0 : 1,
  'next_offset': newRound ? 1 : 2,
  'has_more': false,
  'total': newRound ? 1 : 2,
};

http.Response ok(dynamic body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AppState school(
  StreamStore store,
  Future<http.Response> Function(http.Request) handler,
) =>
    AppState(
        store,
        Api(store, client: MockClient(handler))
          ..consented = true
          ..access = 'school-token',
      )
      // A non-activated fixture keeps the historical outbox local and avoids the
      // automatic uploader. Continuous page fetching still uses the real method.
      ..user = {'id': 'stream-student', 'role': 'student', 'activated': false};

Json persisted(StreamStore store, AppState state) =>
    Map<String, dynamic>.from(store.values['data_${state.cacheKey}']);

Future<void> mount(WidgetTester tester, AppState state) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    state.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final practice = state.practice!;
  await tester.pumpWidget(
    MaterialApp(
      home: PracticePage(
        state: state,
        questions: (practice['questions'] as List)
            .map((item) => Map<String, dynamic>.from(item))
            .toList(),
        resume: practice,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapAction(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pumpAndSettle();
}

void expectFreshBatch(AppState state, {String id = 'second', int round = 1}) {
  final practice = state.practice!;
  expect((practice['questions'] as List).map((q) => q['id']), [id]);
  expect(practice['cursor'], 0);
  expect(practice['answers'], isEmpty);
  expect(practice['submitted'], isEmpty);
  expect(practice['durations'], isEmpty);
  expect(practice['stream']['round'], round);
  expect(practice['stream']['answered'], 1);
  expect(practice['stream']['correct'], 1);
  expect(practice['stream']['study_seconds'], 7);
}

void main() {
  setUpAll(preview.loadPreviewFonts);
  testWidgets(
    'advancing persists only the fresh current batch and old totals',
    (tester) async {
      final store = StreamStore();
      late http.Request sent;
      final state =
          school(store, (request) async {
              sent = request;
              return ok(nextPage());
            })
            ..practice = initialPractice()
            ..queue = [savedAnswer()];
      await state.persist();
      await mount(tester, state);

      await tapAction(tester, '下一题');

      expectFreshBatch(state);
      expect(persisted(store, state)['practice'], state.practice);
      expect(state.queue, [savedAnswer()]);
      expect(sent.url.queryParameters['offset'], '1');
      expect(sent.url.queryParameters['seed'], roundSeed);
      expect(sent.url.queryParameters['version'], '3');
      expect(sent.url.queryParameters['pool_hash'], poolHash);
      expect(find.text('本批题目second'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'offline next batch preserves submission and retries same cursor',
    (tester) async {
      final store = StreamStore();
      final requests = <Map<String, String>>[];
      final original = initialPractice();
      final state =
          school(store, (request) async {
              requests.add(request.url.queryParameters);
              if (requests.length == 1) throw http.ClientException('offline');
              return ok(nextPage());
            })
            ..practice = original
            ..queue = [savedAnswer()];
      await state.persist();
      await mount(tester, state);

      await tapAction(tester, '下一题');

      expect(state.practice, {
        ...original,
        'mode': 'all',
        'subject_id': 'math',
        'question_type': null,
        'category_id': null,
        'category_name': '全部题目',
        'session_id': original['stream']['session_id'],
      });
      expect(
        AppState.practiceScope(state.practice!),
        AppState.practiceScope(original),
      );
      expect(persisted(store, state)['practice'], original);
      expect(state.queue, [savedAnswer()]);
      expect(find.text('重试加载题目'), findsOneWidget);
      expect(find.text('本批题目first'), findsOneWidget);

      await tapAction(tester, '重试加载题目');

      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
      expectFreshBatch(state);
      expect(state.queue, [savedAnswer()]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'restart advances an already submitted batch without recording again',
    (tester) async {
      final store = StreamStore();
      final beforeRestart = school(store, (_) async => ok(nextPage()))
        ..practice = initialPractice()
        ..queue = [savedAnswer()];
      await beforeRestart.persist();
      beforeRestart.dispose();
      final restarted = school(store, (_) async => ok(nextPage()));
      await restarted.loadLocal();
      await mount(tester, restarted);
      expect(find.text('下一题'), findsOneWidget);
      expect(find.text('提交答案'), findsNothing);

      await tapAction(tester, '下一题');

      expectFreshBatch(restarted);
      expect(restarted.queue, [savedAnswer()]);
      expect(persisted(store, restarted)['queue'], [savedAnswer()]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new round clears same-ID answer and timing and creates a fresh UUID',
    (tester) async {
      final store = StreamStore();
      late http.Request sent;
      final state =
          school(store, (request) async {
              sent = request;
              return ok(nextPage(id: 'same', newRound: true));
            })
            ..practice = initialPractice(id: 'same', hasMore: false)
            ..queue = [savedAnswer(id: 'same')];
      await state.persist();
      await mount(tester, state);

      await tapAction(tester, '继续新一轮');

      expectFreshBatch(state, id: 'same', round: 2);
      expect(state.practice!['stream']['seed'], nextRoundSeed);
      expect(sent.url.queryParameters['offset'], '0');
      expect(sent.url.queryParameters.containsKey('seed'), isFalse);
      expect(sent.url.queryParameters['version'], '3');
      expect(sent.url.queryParameters['pool_hash'], poolHash);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '提交答案'))
            .onPressed,
        isNull,
      );

      await tester.pump(const Duration(seconds: 2));
      await tester.tap(find.text('选项甲'));
      await tester.pump();
      await tapAction(tester, '提交答案');

      expect(state.queue, hasLength(2));
      expect(state.queue.map((record) => record['question_id']), [
        'same',
        'same',
      ]);
      expect(
        state.queue[1]['client_uuid'],
        isNot(state.queue[0]['client_uuid']),
      );
      expect(state.queue[1]['duration_seconds'], lessThan(7));
      expect(state.practice!['submitted'], [0]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('409 ends stream and timer or disposal cannot restore it', (
    tester,
  ) async {
    final store = StreamStore();
    final state =
        school(store, (_) async => ok({'detail': '题库范围已变化'}, status: 409))
          ..practice = initialPractice()
          ..queue = [savedAnswer()];
    await state.persist();
    await mount(tester, state);

    await tapAction(tester, '下一题');

    expect(find.text('题库已更新'), findsOneWidget);
    expect(state.practice, isNull);
    expect(state.queue, [savedAnswer()]);
    await tester.pump(const Duration(seconds: 6));
    expect(state.practice, isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(state.practice, isNull);
    expect(persisted(store, state)['practice'], isNull);
    expect(persisted(store, state)['queue'], [savedAnswer()]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed batch write restores old batch and retries the same offset',
    (tester) async {
      final store = StreamStore();
      final requests = <Map<String, String>>[];
      final original = initialPractice();
      final state =
          school(store, (request) async {
              requests.add(request.url.queryParameters);
              return ok(nextPage());
            })
            ..practice = original
            ..queue = [savedAnswer()];
      await state.persist();
      await mount(tester, state);
      store.failNext = true;

      await tapAction(tester, '下一题');

      expect(state.practice, {
        ...original,
        'mode': 'all',
        'subject_id': 'math',
        'question_type': null,
        'category_id': null,
        'category_name': '全部题目',
        'session_id': original['stream']['session_id'],
      });
      expect(
        AppState.practiceScope(state.practice!),
        AppState.practiceScope(original),
      );
      expect(persisted(store, state)['practice'], original);
      expect(find.text('本批题目first'), findsOneWidget);
      expect(find.text('重试加载题目'), findsOneWidget);
      expect(state.queue, [savedAnswer()]);

      await tapAction(tester, '重试加载题目');

      expect(requests, hasLength(2));
      expect(requests[1], requests[0]);
      expectFreshBatch(state);
      expect(persisted(store, state)['practice'], state.practice);
      expect(state.queue, [savedAnswer()]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('same-ID fill input controller is empty on a new round', (
    tester,
  ) async {
    final store = StreamStore();
    final fillQuestion = {
      ...question('same-fill'),
      'type': 'fill',
      'stem': '填写原题答案：___。',
      'options': [],
      'answer': [
        ['答案甲'],
      ],
    };
    final initial = initialPractice(id: 'same-fill', hasMore: false)
      ..['questions'] = [fillQuestion]
      ..['answers'] = {
        '0': ['答案甲'],
      };
    final next = nextPage(id: 'same-fill', newRound: true)
      ..['questions'] = [fillQuestion];
    final state = school(store, (_) async => ok(next))
      ..practice = initial
      ..queue = [savedAnswer(id: 'same-fill')];
    await state.persist();
    await mount(tester, state);

    final fillInput = find.descendant(
      of: find.byType(TextFormField),
      matching: find.byType(EditableText),
    );
    expect(tester.widget<EditableText>(fillInput).controller.text, '答案甲');
    await tapAction(tester, '继续新一轮');

    expectFreshBatch(state, id: 'same-fill', round: 2);
    final field = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(field.initialValue, '');
    expect(field.enabled, isTrue);
    expect(tester.widget<EditableText>(fillInput).controller.text, '');
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '提交答案'))
          .onPressed,
      isNull,
    );
    expect(state.queue, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  for (final width in [390.0, 320.0]) {
    testWidgets('continuous completed-round layout at${width.toInt()}px', (
      tester,
    ) async {
      final store = StreamStore();
      final state = school(store, (_) async => ok(nextPage()));
      final initial = initialPractice(id: 'layout', hasMore: false);
      initial['questions'][0]['stem'] = '若 x＋3＝8，则 x 的值是（ ）。';
      initial['questions'][0]['options'] = [
        {'key': 'A', 'text': '5'},
        {'key': 'B', 'text': '3'},
      ];
      initial['questions'][0]['explanation'] = '等式两边同时减去3，得到 x＝5。';
      initial['questions'][0]['source'] = '界面回归测试题';
      initial['stream'].addAll({
        'offset': 79,
        'next_offset': 80,
        'total': 80,
        'answered': 79,
        'correct': 65,
        'study_seconds': 624,
      });
      state.practice = initial;
      await state.persist();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        state.dispose();
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await preview.mountPage(
        tester,
        PracticePage(
          state: state,
          questions: (initial['questions'] as List)
              .map((item) => Map<String, dynamic>.from(item))
              .toList(),
          resume: initial,
        ),
        width: width,
        height: 844,
        push: true,
      );
      expect(find.text('持续刷题 · 第1轮'), findsOneWidget);
      expect(find.text('本轮第80 / 80题 · 累计已答80题'), findsOneWidget);
      expect(find.text('继续新一轮'), findsOneWidget);
      expect(find.text('本轮题池已完成，可继续新一轮。每轮内题目不重复。'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await preview.capture(tester, 'continuous-${width.toInt()}');
    });
  }

  for (final accountChanges in [false, true]) {
    testWidgets(
      'stale finish dialog cannot clear a replacement ${accountChanges ? 'account' : 'stream'}',
      (tester) async {
        final store = StreamStore();
        final state = school(store, (_) async => ok(nextPage()))
          ..practice = initialPractice()
          ..queue = [savedAnswer()];
        await state.persist();
        await mount(tester, state);
        await tester.tap(find.byTooltip('结束本次练习'));
        await tester.pumpAndSettle();
        expect(find.text('又完成了一次积累'), findsOneWidget);

        final replacement = initialPractice(id: 'replacement')
          ..['stream']['session_id'] = 'replacement-stream-session';
        final replacementQueue = [
          {
            ...savedAnswer(id: 'replacement'),
            'client_uuid': 'replacement-record',
          },
        ];
        if (accountChanges) {
          state.api.invalidateSession();
          state.user = {
            'id': 'replacement-student',
            'role': 'student',
            'activated': false,
          };
        }
        state.practice = replacement;
        state.queue = replacementQueue;
        await state.persist();
        final before = jsonDecode(jsonEncode(store.values));

        await tapAction(tester, '完成练习');

        expect(identical(state.practice, replacement), isTrue);
        expect(state.queue, replacementQueue);
        expect(store.values, before);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('late finish save cannot pop a replacement route', (
    tester,
  ) async {
    final store = StreamStore();
    final state = school(store, (_) async => ok(nextPage()))
      ..practice = initialPractice()
      ..queue = [savedAnswer()];
    await state.persist();
    await mount(tester, state);
    await tester.tap(find.byTooltip('结束本次练习'));
    await tester.pumpAndSettle();
    final gate = Completer<void>();
    store.gateNextWrite = gate;

    await tester.tap(find.text('完成练习'));
    await tester.pump();
    expect(state.practice, isNull);

    final replacement = initialPractice(id: 'replacement')
      ..['stream']['session_id'] = 'replacement-stream-session';
    state.practice = replacement;
    final newSave = state.persist();
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => const Scaffold(body: Text('替换后的练习页面')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    gate.complete();
    await tester.pump();
    await newSave;
    await tester.pumpAndSettle();

    expect(find.text('替换后的练习页面'), findsOneWidget);
    expect(find.text('又完成了一次积累'), findsNothing);
    expect(identical(state.practice, replacement), isTrue);
    expect(state.queue, [savedAnswer()]);
    expect(persisted(store, state)['practice'], replacement);
    expect(tester.takeException(), isNull);
  });
}
