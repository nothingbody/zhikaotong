import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';

const seed = '0123456789abcdef0123456789abcdef';
const poolHash =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

class ContinuousStore extends LocalStore {
  final values = <String, dynamic>{};
  @override
  Future<dynamic> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  @override
  Future<void> write(String key, dynamic value) async {
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<void> secureWrite(String key, String? value) async {}
}

Json question(String id, {int version = 3}) => {
  'id': id,
  'subject_id': 'math',
  'version': version,
  'type': 'single',
  'stem': '请选择正确的计算结果',
  'options': [
    {'key': 'A', 'text': '一'},
    {'key': 'B', 'text': '二'},
    {'key': 'C', 'text': '三'},
    {'key': 'D', 'text': '四'},
  ],
  'answer': ['A'],
};

Json page({int offset = 0, int total = 3, int version = 3}) => {
  'version': version,
  'total': total,
  'offset': offset,
  'next_offset': offset + 2,
  'has_more': offset + 2 < total,
  'seed': seed,
  'pool_hash': poolHash,
  'questions': [
    question('q-$offset', version: version),
    question('q-${offset + 1}', version: version),
  ],
};

Json manifest(int version, List<String> ids) => {
  'version': version,
  'questions': [
    for (final id in ids) {'id': id, 'subject_id': 'math'},
  ],
  'subjects': [
    {'id': 'math'},
  ],
};

http.Response ok(dynamic body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AppState school(
  ContinuousStore store,
  Future<http.Response> Function(http.Request) handler,
) =>
    AppState(
        store,
        Api(store, client: MockClient(handler))
          ..consented = true
          ..access = 'school-token',
      )
      ..user = {
        'id': 'student-1',
        'role': 'student',
        'activated': true,
        'must_change_password': false,
        'consent_version': 'v1',
      }
      ..config = {'agreement_version': 'v1'};

Matcher appFailure([int? status]) => throwsA(
  status == null
      ? isA<AppError>()
      : isA<AppError>().having((failure) => failure.status, 'status', status),
);

void main() {
  test(
    'first page explicitly requests twenty online subject questions',
    () async {
      late http.Request sent;
      final state = school(ContinuousStore(), (request) async {
        sent = request;
        return ok(page());
      });
      addTearDown(state.dispose);

      final result = await state.continuousQuestions('math');

      expect(sent.method, 'GET');
      expect(sent.url.path, '/api/questions/continuous');
      expect(sent.url.queryParameters, {
        'subject_id': 'math',
        'mode': 'all',
        'limit': '20',
        'offset': '0',
        'shuffle': 'false',
      });
      expect(sent.headers['X-Question-Content'], 'media-v1');
      expect(result, page());
    },
  );

  test(
    'later page retains server cursor and prepares original option keys',
    () async {
      late http.Request sent;
      final source = page(offset: 20, total: 22);
      final state = school(ContinuousStore(), (request) async {
        sent = request;
        return ok(source);
      });
      addTearDown(state.dispose);

      final result = await state.continuousQuestions(
        'math',
        type: 'single',
        difficulty: 2,
        random: true,
        shuffleOptions: true,
        seed: seed,
        offset: 20,
        version: 3,
        poolHash: poolHash,
      );

      expect(sent.url.queryParameters, {
        'subject_id': 'math',
        'mode': 'all',
        'limit': '20',
        'offset': '20',
        'shuffle': 'true',
        'type': 'single',
        'difficulty': '2',
        'seed': seed,
        'version': '3',
        'pool_hash': poolHash,
      });
      for (final field in [
        'version',
        'total',
        'offset',
        'next_offset',
        'has_more',
        'seed',
        'pool_hash',
      ]) {
        expect(result[field], source[field]);
      }
      for (final q in result['questions'] as List) {
        final options = (q['options'] as List).cast<Map>();
        expect(options.map((option) => option['key']).toSet(), {
          'A',
          'B',
          'C',
          'D',
        });
        expect(options.map((option) => option['display_key']), [
          'A',
          'B',
          'C',
          'D',
        ]);
        expect(q['answer'], ['A']);
      }
      expect((source['questions'] as List).first['options_shuffled'], isNull);
    },
  );

  test(
    'new round requests a fresh seed while pinning version and pool',
    () async {
      late http.Request sent;
      final state = school(ContinuousStore(), (request) async {
        sent = request;
        return ok(page());
      });
      addTearDown(state.dispose);
      await state.continuousQuestions(
        'math',
        random: true,
        version: 3,
        poolHash: poolHash,
      );
      expect(sent.url.queryParameters.containsKey('seed'), isFalse);
      expect(sent.url.queryParameters['offset'], '0');
      expect(sent.url.queryParameters['version'], '3');
      expect(sent.url.queryParameters['pool_hash'], poolHash);
    },
  );

  final malformed = <String, dynamic Function()>{
    'non-object response': () => [],
    'string version': () => page()..['version'] = '3',
    'negative version': () => page()..['version'] = -1,
    'negative total': () => page()..['total'] = -1,
    'string total': () => page()..['total'] = '3',
    'wrong offset': () => page()..['offset'] = 1,
    'wrong next offset': () => page()..['next_offset'] = 1,
    'next offset exceeds total': () => page(total: 1),
    'false more flag': () => page()..['has_more'] = false,
    'non-boolean more flag': () => page()..['has_more'] = 1,
    'uppercase seed': () => page()..['seed'] = seed.toUpperCase(),
    'short seed': () => page()..['seed'] = 'abc',
    'missing pool hash': () => page()..remove('pool_hash'),
    'uppercase pool hash': () => page()..['pool_hash'] = poolHash.toUpperCase(),
    'invalid question list': () => page()..['questions'] = {},
    'non-object question': () => page()..['questions'] = ['q-0', 'q-1'],
    'empty question identity': () => page()..['questions'][0]['id'] = '',
    'duplicate question identity': () => page()..['questions'][1]['id'] = 'q-0',
    'question version differs from page': () =>
        page()..['questions'][0]['version'] = 2,
    'string question version': () => page()..['questions'][0]['version'] = '3',
    'question from another subject': () =>
        page()..['questions'][0]['subject_id'] = 'english',
    'empty nonterminal page': () => {
      ...page(),
      'next_offset': 0,
      'questions': [],
    },
    'more than twenty questions': () => {
      ...page(total: 21),
      'next_offset': 21,
      'has_more': false,
      'questions': List.generate(21, (index) => question('q-$index')),
    },
  };
  for (final entry in malformed.entries) {
    test('rejects ${entry.key} before exposing a batch', () async {
      final state = school(ContinuousStore(), (_) async => ok(entry.value()));
      addTearDown(state.dispose);
      await expectLater(state.continuousQuestions('math'), appFailure());
    });
  }

  test(
    'terminal empty page is valid and preserves its exhausted cursor',
    () async {
      final terminal = {
        ...page(),
        'total': 0,
        'next_offset': 0,
        'has_more': false,
        'questions': [],
      };
      final state = school(ContinuousStore(), (_) async => ok(terminal));
      addTearDown(state.dispose);
      expect(await state.continuousQuestions('math'), terminal);
    },
  );

  test('response version must match the pinned round version', () async {
    final state = school(ContinuousStore(), (_) async => ok(page(version: 4)));
    addTearDown(state.dispose);
    await expectLater(
      state.continuousQuestions('math', version: 3, poolHash: poolHash),
      appFailure(),
    );
  });

  test('negative cursor is rejected before making a request', () async {
    var sent = 0;
    final state = school(ContinuousStore(), (_) async {
      sent++;
      return ok(page());
    });
    addTearDown(state.dispose);
    await expectLater(
      state.continuousQuestions('math', offset: -1),
      appFailure(),
    );
    expect(sent, 0);
  });

  for (final changed in ['seed', 'pool_hash']) {
    test('later page rejects a changed $changed', () async {
      final changedPage = page(offset: 20, total: 22)
        ..[changed] = changed == 'seed'
            ? '11111111111111111111111111111111'
            : 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
      final state = school(ContinuousStore(), (_) async => ok(changedPage));
      addTearDown(state.dispose);
      await expectLater(
        state.continuousQuestions(
          'math',
          offset: 20,
          seed: seed,
          version: 3,
          poolHash: poolHash,
        ),
        appFailure(),
      );
    });
  }

  for (final absent in ['seed', 'version', 'poolHash']) {
    test('later page requires pinned $absent', () async {
      var sent = 0;
      final state = school(ContinuousStore(), (_) async {
        sent++;
        return ok(page(offset: 20, total: 22));
      });
      addTearDown(state.dispose);
      await expectLater(
        state.continuousQuestions(
          'math',
          offset: 20,
          seed: absent == 'seed' ? null : seed,
          version: absent == 'version' ? null : 3,
          poolHash: absent == 'poolHash' ? null : poolHash,
        ),
        appFailure(),
      );
      expect(sent, 0);
    });
  }

  test(
    'network failure never falls back or changes saved practice and outbox',
    () async {
      final store = ContinuousStore();
      final state =
          school(store, (_) async => throw http.ClientException('offline'))
            ..practice = {
              'questions': [question('saved')],
              'cursor': 0,
            }
            ..queue = [
              {
                'client_uuid': 'saved-answer',
                'question_id': 'saved',
                'question_version': 3,
              },
            ]
            ..offline = {
              'math': {
                'subject_id': 'math',
                'questions': [question('cached')],
              },
            };
      addTearDown(state.dispose);
      await state.persist();
      final beforePractice = jsonDecode(jsonEncode(state.practice));
      final beforeQueue = jsonDecode(jsonEncode(state.queue));
      final beforeDisk = jsonDecode(jsonEncode(store.values));
      await expectLater(state.continuousQuestions('math'), appFailure(0));
      expect(state.practice, beforePractice);
      expect(state.queue, beforeQueue);
      expect(store.values, beforeDisk);
      expect(state.offlineMode, isFalse);
    },
  );

  test('teacher cannot request student continuous questions', () async {
    var sent = 0;
    final state = school(ContinuousStore(), (_) async {
      sent++;
      return ok(page());
    })..user!['role'] = 'teacher';
    addTearDown(state.dispose);
    await expectLater(state.continuousQuestions('math'), appFailure(403));
    expect(sent, 0);
  });

  test('late response cannot enter a different user session', () async {
    final started = Completer<void>();
    final response = Completer<http.Response>();
    final state = school(ContinuousStore(), (_) {
      started.complete();
      return response.future;
    });
    addTearDown(state.dispose);
    final request = state.continuousQuestions('math');
    await started.future;
    state.api.invalidateSession();
    state.user = {...state.user!, 'id': 'student-2'};
    response.complete(ok(page()));
    await expectLater(request, appFailure(401));
    expect(state.practice, isNull);
    expect(state.queue, isEmpty);
  });

  test('409 refreshes bank manifest but remains 409 for the caller', () async {
    final paths = <String>[];
    final state =
        school(ContinuousStore(), (request) async {
            paths.add(request.url.path);
            if (request.url.path.endsWith('/manifest'))
              return ok(manifest(4, ['new']));
            return ok({'detail': '题库范围已变化，请重新开始'}, status: 409);
          })
          ..queue = [
            {'client_uuid': 'historical-answer', 'question_version': 3},
          ];
    addTearDown(state.dispose);
    await expectLater(state.continuousQuestions('math'), appFailure(409));
    expect(paths, ['/api/questions/continuous', '/api/bank/manifest']);
    expect(state.bankManifest?['version'], 4);
    expect(state.queue.single['client_uuid'], 'historical-answer');
  });

  test('failed manifest refresh does not hide an original 409', () async {
    final state = school(ContinuousStore(), (request) async {
      if (request.url.path.endsWith('/manifest'))
        throw http.ClientException('offline');
      return ok({'detail': '题库范围已变化'}, status: 409);
    });
    addTearDown(state.dispose);
    await expectLater(state.continuousQuestions('math'), appFailure(409));
  });

  test(
    'newer page must be confirmed against the refreshed bank manifest',
    () async {
      final paths = <String>[];
      final state = school(ContinuousStore(), (request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/manifest'))
          return ok(manifest(3, ['q-0', 'q-1']));
        return ok(page());
      })..bankManifest = manifest(2, ['old']);
      addTearDown(state.dispose);
      final result = await state.continuousQuestions('math');
      expect(result['version'], 3);
      expect(state.bankManifest?['version'], 3);
      expect(paths, ['/api/questions/continuous', '/api/bank/manifest']);
    },
  );

  test(
    'unconfirmed newer page is rejected instead of leaking unavailable questions',
    () async {
      final state = school(ContinuousStore(), (request) async {
        if (request.url.path.endsWith('/manifest'))
          throw http.ClientException('offline');
        return ok(page());
      })..bankManifest = manifest(2, ['old']);
      addTearDown(state.dispose);
      await expectLater(state.continuousQuestions('math'), appFailure(409));
    },
  );
}
