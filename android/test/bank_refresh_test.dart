import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

class BankStore extends LocalStore {
  final values = <String, dynamic>{};
  bool failNext = false;
  @override
  Future<dynamic> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  @override
  Future<void> write(String key, dynamic value) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<void> secureWrite(String key, String? value) async {}
}

Json question(String id, [int version = 1]) => {
  'id': id,
  'subject_id': 'math',
  'version': version,
  'type': 'single',
  'stem': id,
  'options': [
    {'key': 'A', 'text': '正确'},
    {'key': 'B', 'text': '错误'},
  ],
  'answer': ['A'],
};
Json bankPackage(int version, List<String> ids) {
  final questions = ids.map((id) => question(id, version)).toList();
  return {
    'version': version,
    'subject_id': 'math',
    'questions': questions,
    'checksum': sha256
        .convert(utf8.encode(jsonEncode(canonical(questions))))
        .toString(),
  };
}

Json manifest([List<String> ids = const ['keep', 'new']]) => {
  'version': 2,
  'questions': [
    for (final id in ids) {'id': id, 'subject_id': 'math'},
  ],
  'question_ids': ids,
  'subjects': [
    {'id': 'math', 'name': '数学', 'count': ids.length},
  ],
};
Json historyRecord() => {
  'client_uuid': 'saved-demo-answer',
  'question_id': 'demo',
  'question_version': 1,
  'selected': ['A'],
  'duration_seconds': 3,
};
Json identity(String id) => {
  'id': id,
  'role': 'student',
  'activated': true,
  'must_change_password': false,
  'consent_version': 'v1',
};

AppState school(
  BankStore store,
  Future<http.Response> Function(http.Request) handler,
) {
  final api = Api(store, client: MockClient(handler))
    ..consented = true
    ..access = 'access';
  return AppState(store, api)
    ..user = identity('student-1')
    ..config = {'agreement_version': 'v1'};
}

http.Response ok(dynamic value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  for (final savedVersion in <int?>[1, null, 2]) {
    test(
      'confirmed same-ID content revision retires only older or unversioned continuation ($savedVersion)',
      () async {
        final store = BankStore();
        final saved = question('keep', savedVersion ?? 1);
        if (savedVersion == null) saved.remove('version');
        final state =
            school(
                store,
                (request) async => request.url.path.endsWith('/manifest')
                    ? ok(manifest(['keep']))
                    : ok(bankPackage(2, ['keep'])),
              )
              ..queue = [historyRecord()]
              ..practice = {
                'questions': [saved],
                'cursor': 0,
                'answers': {
                  '0': ['A'],
                },
              }
              ..offline = {
                'math': bankPackage(1, ['keep']),
              };
        await state.persist();
        await state.refreshBank();
        expect(state.queue, [historyRecord()]);
        expect(state.offline['math']['version'], 2);
        if (savedVersion == 2) {
          expect(state.practice, isNotNull);
        } else {
          expect(state.practice, isNull);
          expect(state.bankNotice, contains('旧版练习已结束'));
        }
        final restarted = school(
          store,
          (_) async => throw http.ClientException('offline'),
        );
        await restarted.loadLocal();
        expect(restarted.queue, [historyRecord()]);
        expect(restarted.practice == null, savedVersion != 2);
        state.dispose();
        restarted.dispose();
      },
    );
  }

  test(
    'confirmed bank refresh replaces downloads and retires practice without losing queued answers',
    () async {
      final store = BankStore();
      final state =
          school(
              store,
              (request) async => request.url.path.endsWith('/manifest')
                  ? ok(manifest())
                  : ok(bankPackage(2, ['keep', 'new'])),
            )
            ..offline = {
              'math': bankPackage(1, ['demo', 'keep']),
            }
            ..queue = [historyRecord()]
            ..markQueue = [
              {'question_id': 'demo', 'kind': 'favorite', 'active': true},
              {'question_id': 'keep', 'kind': 'favorite', 'active': true},
            ]
            ..favorites = {'demo', 'keep'}
            ..doubts = {'demo'}
            ..practice = {
              'questions': [question('demo'), question('keep')],
              'cursor': 1,
              'answers': {
                '0': ['A'],
              },
            };
      await state.persist();
      await state.refreshBank();
      expect(state.queue, [historyRecord()]);
      expect(state.markQueue.single['question_id'], 'keep');
      expect(state.practice, isNull);
      expect(state.bankNotice, contains('已保存的作答'));
      expect(state.favorites, {'keep'});
      expect(state.doubts, isEmpty);
      expect(state.offline['math']['version'], 2);
      expect(state.cachedQuestions('math', 'all').map((q) => q['id']), [
        'keep',
        'new',
      ]);
      final restarted = school(
        store,
        (_) async => throw http.ClientException('offline'),
      );
      await restarted.loadLocal();
      expect(restarted.queue, [historyRecord()]);
      expect(restarted.practice, isNull);
      expect(restarted.availableQuestions!.keys, containsAll(['keep', 'new']));
      state.dispose();
      restarted.dispose();
    },
  );

  test(
    'failed new checksum preserves old bytes but cannot start old-version content after a confirmed correction',
    () async {
      final store = BankStore();
      final state =
          school(store, (request) async {
              if (request.url.path.endsWith('/manifest')) return ok(manifest());
              if (request.url.path.endsWith('/package'))
                return ok({
                  ...bankPackage(2, ['keep', 'new']),
                  'checksum': 'corrupt',
                });
              throw http.ClientException('offline');
            })
            ..offline = {
              'math': bankPackage(1, ['demo', 'keep']),
            };
      await state.refreshBank();
      expect(state.offline['math']['version'], 1);
      expect(
        verifyPackage(Map<String, dynamic>.from(state.offline['math'])),
        true,
      );
      await expectLater(
        state.questions('math', 'all', 20),
        throwsA(isA<AppError>()),
      );
      final restarted = school(
        store,
        (_) async => throw http.ClientException('offline'),
      );
      await restarted.loadLocal();
      await expectLater(
        restarted.questions('math', 'all', 20),
        throwsA(isA<AppError>()),
      );
      await expectLater(
        restarted.record(question('keep'), ['A'], 1),
        throwsA(isA<AppError>()),
      );
      await expectLater(
        restarted.record(question('demo'), ['A'], 1),
        throwsA(isA<AppError>()),
      );
      state.dispose();
      restarted.dispose();
    },
  );

  test(
    '404, malformed and unreachable manifests preserve unconfirmed offline data',
    () async {
      for (final response in [404, 0, 200]) {
        final store = BankStore();
        final state =
            school(store, (_) async {
                if (response == 0) throw http.ClientException('offline');
                return response == 404
                    ? http.Response('{"detail":"old server"}', 404)
                    : ok({});
              })
              ..offline = {
                'math': bankPackage(1, ['demo']),
              }
              ..queue = [historyRecord()]
              ..markQueue = [
                {'question_id': 'demo'},
              ]
              ..practice = {
                'questions': [question('demo')],
              };
        await state.refreshBank();
        expect(state.bankManifest, isNull);
        expect(state.practice, isNotNull);
        expect(state.queue, [historyRecord()]);
        expect(state.markQueue.length, 1);
        expect(state.cachedQuestions('math', 'all').single['id'], 'demo');
        state.dispose();
      }
    },
  );

  test(
    'explicit empty published bank retires all current practice but preserves answer outbox',
    () async {
      final store = BankStore();
      final state =
          school(
              store,
              (request) async => request.url.path.endsWith('/manifest')
                  ? ok(manifest([]))
                  : ok(bankPackage(2, [])),
            )
            ..offline = {
              'math': bankPackage(1, ['demo']),
            }
            ..queue = [historyRecord()]
            ..practice = {
              'questions': [question('demo')],
            };
      await state.refreshBank();
      expect(state.availableQuestions, isEmpty);
      expect(state.cachedQuestions('math', 'all'), isEmpty);
      expect(state.queue, [historyRecord()]);
      expect(state.practice, isNull);
      state.dispose();
    },
  );

  test(
    'reload reconciles manifest before uploading old answers and drops only retired marks',
    () async {
      final paths = <String>[];
      Json? uploaded;
      final store = BankStore();
      final state =
          school(store, (request) async {
              final path = request.url.path;
              paths.add(path);
              if (path.endsWith('/public/config'))
                return ok({'agreement_version': 'v1'});
              if (path.endsWith('/manifest')) return ok(manifest());
              if (path.endsWith('/records/batch')) {
                uploaded = jsonDecode(request.body);
                return ok({'accepted': 1});
              }
              if (path.endsWith('/student/dashboard')) return ok({'stats': {}});
              if (path.endsWith('/subjects') || path.endsWith('/classes'))
                return ok([]);
              if (path.endsWith('/student/marks')) return ok(['demo', 'keep']);
              return ok({'ok': true});
            })
            ..queue = [historyRecord()]
            ..markQueue = [
              {'question_id': 'demo', 'kind': 'favorite', 'active': true},
              {'question_id': 'keep', 'kind': 'favorite', 'active': true},
            ];
      await state.reload();
      expect(
        paths.indexOf('/api/bank/manifest'),
        lessThan(paths.indexOf('/api/student/records/batch')),
      );
      expect(uploaded!['records'], [historyRecord()]);
      expect(paths, contains('/api/student/marks/keep'));
      expect(paths, isNot(contains('/api/student/marks/demo')));
      expect(state.queue, isEmpty);
      expect(state.markQueue, isEmpty);
      expect(state.favorites, {'keep'});
      state.dispose();
    },
  );

  test(
    'failed manifest persistence leaves durable historical outbox and retry is safe',
    () async {
      final store = BankStore();
      final state =
          school(
              store,
              (request) async => request.url.path.endsWith('/manifest')
                  ? ok(manifest())
                  : ok(bankPackage(2, ['keep', 'new'])),
            )
            ..offline = {
              'math': bankPackage(1, ['demo', 'keep']),
            }
            ..queue = [historyRecord()]
            ..practice = {
              'questions': [question('demo')],
            };
      await state.persist();
      final original = jsonEncode(store.values['data_${state.cacheKey}']);
      store.failNext = true;
      await expectLater(state.refreshBank(), throwsStateError);
      expect(state.queue, [historyRecord()]);
      expect(jsonEncode(store.values['data_${state.cacheKey}']), original);
      await state.refreshBank();
      final restarted = school(store, (_) async => ok({}));
      await restarted.loadLocal();
      expect(restarted.queue, [historyRecord()]);
      expect(restarted.practice, isNull);
      state.dispose();
      restarted.dispose();
    },
  );

  test('late manifest response cannot overwrite another user cache', () async {
    final response = Completer<http.Response>();
    final store = BankStore();
    final state = school(store, (_) => response.future)
      ..offline = {
        'math': bankPackage(1, ['demo']),
      };
    final pending = state.refreshBank();
    state.api.invalidateSession();
    state.user = identity('student-2');
    await state.loadLocal();
    state.offline = {
      'math': bankPackage(9, ['other-user']),
    };
    await state.persist();
    final before = jsonEncode(store.values['data_${state.cacheKey}']);
    response.complete(ok(manifest()));
    await pending;
    expect(state.offline['math']['version'], 9);
    expect(state.bankManifest, isNull);
    expect(jsonEncode(store.values['data_${state.cacheKey}']), before);
    state.dispose();
  });

  test('late downloaded package cannot enter another user cache', () async {
    final response = Completer<http.Response>(), started = Completer<void>();
    final store = BankStore();
    final state =
        school(store, (request) async {
            if (request.url.path.endsWith('/manifest')) return ok(manifest());
            started.complete();
            return response.future;
          })
          ..offline = {
            'math': bankPackage(1, ['demo']),
          };
    final pending = state.refreshBank();
    await started.future;
    state.api.invalidateSession();
    state.user = identity('student-2');
    await state.loadLocal();
    state.offline = {
      'math': bankPackage(9, ['other-user']),
    };
    await state.persist();
    final before = jsonEncode(store.values['data_${state.cacheKey}']);
    response.complete(ok(bankPackage(2, ['keep', 'new'])));
    await pending;
    expect(state.offline['math']['version'], 9);
    expect(jsonEncode(store.values['data_${state.cacheKey}']), before);
    state.dispose();
  });

  test('late answer upload cannot clear the next user outbox', () async {
    final response = Completer<http.Response>();
    final store = BankStore();
    final state = school(store, (_) => response.future)
      ..queue = [historyRecord()];
    final pending = state.sync();
    state.api.invalidateSession();
    state.user = identity('student-2');
    await state.loadLocal();
    state.queue = [
      {...historyRecord(), 'client_uuid': 'next-user'},
    ];
    await state.persist();
    response.complete(ok({'accepted': 1}));
    await pending;
    expect(state.queue.single['client_uuid'], 'next-user');
    expect(
      store.values['data_${state.cacheKey}']['queue'].single['client_uuid'],
      'next-user',
    );
    state.dispose();
  });

  test(
    'online questions from a newer release refresh availability before allowing an answer',
    () async {
      final paths = <String>[];
      final store = BankStore();
      final state = school(store, (request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/questions'))
          return ok([question('just-added', 3)]);
        if (request.url.path.endsWith('/manifest'))
          return ok({
            ...manifest(['just-added']),
            'version': 3,
          });
        return ok({});
      })..bankManifest = manifest(['keep']);
      final questions = await state.questions('math', 'all', 10);
      expect(questions.single['id'], 'just-added');
      expect(paths, ['/api/questions', '/api/bank/manifest']);
      expect(state.questionAvailable(questions.single), true);
      state.user!['activated'] = false;
      await state.record(questions.single, ['A'], 3);
      expect(state.queue.single['question_id'], 'just-added');
      expect(state.queue.single['question_version'], 3);
      state.dispose();
    },
  );

  test(
    'new online questions are not returned when their availability cannot be confirmed',
    () async {
      final store = BankStore();
      final state =
          school(store, (request) async {
              if (request.url.path.endsWith('/questions'))
                return ok([question('just-added', 3)]);
              throw http.ClientException('offline during update');
            })
            ..bankManifest = manifest(['keep'])
            ..offline = {
              'math': bankPackage(2, ['keep']),
            };
      await expectLater(
        state.questions('math', 'all', 10),
        throwsA(
          isA<AppError>().having((failure) => failure.status, 'status', 409),
        ),
      );
      expect(state.availableQuestions!.keys, ['keep']);
      expect(state.queue, isEmpty);
      state.dispose();
    },
  );

  testWidgets(
    'an open retired practice cannot restore itself through its timer or disposal',
    (tester) async {
      final store = BankStore();
      final state = school(store, (_) async => ok(manifest(['keep'])))
        ..queue = [historyRecord()]
        ..practice = {
          'questions': [question('demo')],
        };
      await tester.pumpWidget(
        MaterialApp(
          home: PracticePage(state: state, questions: [question('demo')]),
        ),
      );
      await state.refreshBank();
      await tester.pump(const Duration(seconds: 6));
      expect(find.text('题库已更新'), findsOneWidget);
      expect(state.practice, isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(state.practice, isNull);
      expect(store.values['data_${state.cacheKey}']['practice'], isNull);
      expect(state.queue, [historyRecord()]);
      state.dispose();
    },
  );
}
