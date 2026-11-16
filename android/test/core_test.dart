import 'dart:convert';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';

class MemoryStore extends LocalStore {
  final Map<String, dynamic> values = {};
  bool fail = false;
  int secureReads = 0;
  @override
  Future<dynamic> read(String key) async => values[key];
  @override
  Future<void> write(String key, dynamic value) async {
    if (fail) throw StateError('disk full');
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<String?> secureRead(String key) async {
    secureReads++;
    return null;
  }

  @override
  Future<void> secureWrite(String key, String? value) async {
    values['secure_$key'] = value;
  }
}

void main() {
  test('multiple selection only scores exact complete answer', () {
    expect(isCorrect(['A', 'C'], {'A', 'C'}), isTrue);
    expect(isCorrect(['A', 'C'], {'A'}), isFalse);
    expect(isCorrect(['A', 'C'], {'A', 'B', 'C'}), isFalse);
    expect(isCorrect(['A'], <String>{}), isFalse);
  });
  test('UUID is RFC4122 v4 and unique for outbox retries', () {
    final ids = List.generate(1000, (_) => uuid());
    expect(ids.toSet().length, ids.length);
    expect(
      ids.every(
        (id) => RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(id),
      ),
      isTrue,
    );
  });
  test('package checksum is canonical UTF8 JSON and detects corruption', () {
    final questions = [
      {
        'stem': '测试中文',
        'id': 'q1',
        'options': [
          {'text': '甲', 'key': 'A'},
        ],
      },
    ];
    final digest = sha256
        .convert(utf8.encode(jsonEncode(canonical(questions))))
        .toString();
    expect(verifyPackage({'questions': questions, 'checksum': digest}), isTrue);
    questions.first['stem'] = '篡改内容';
    expect(
      verifyPackage({'questions': questions, 'checksum': digest}),
      isFalse,
    );
  });
  test('no session read or network before local privacy consent', () async {
    final store = MemoryStore();
    final state = AppState(store);
    await state.init();
    expect(state.api.consented, isFalse);
    expect(store.secureReads, 0);
    expect(state.user, isNull);
    await expectLater(
      state.api.call('GET', '/public/config'),
      throwsA(isA<AppError>()),
    );
    state.dispose();
  });
  test(
    'answer is durably queued and survives app restart with same UUID',
    () async {
      final store = MemoryStore();
      final state = AppState(store)
        ..user = {'id': 'student-1', 'activated': false};
      await state.record({'id': 'question-1'}, {'A'}, 4);
      expect(state.queue.length, 1);
      final id = state.queue.single['client_uuid'];
      final restarted = AppState(store)
        ..user = {'id': 'student-1', 'activated': false};
      await restarted.loadLocal();
      expect(restarted.queue.single['client_uuid'], id);
      expect(restarted.queue.single['duration_seconds'], 4);
      final otherUser = AppState(store)
        ..user = {'id': 'student-2', 'activated': false};
      await otherUser.loadLocal();
      expect(otherUser.queue, isEmpty);
      state.dispose();
      restarted.dispose();
      otherUser.dispose();
    },
  );
  test('failed durable write does not acknowledge record in memory', () async {
    final store = MemoryStore()..fail = true;
    final state = AppState(store)
      ..user = {'id': 'student-1', 'activated': false};
    await expectLater(
      state.record({'id': 'question-1'}, {'A'}, 4),
      throwsStateError,
    );
    expect(state.queue, isEmpty);
    state.dispose();
  });
  test(
    'outbox and submitted practice are persisted atomically before sync',
    () async {
      final store = MemoryStore();
      final state = AppState(store)
        ..user = {'id': 'student-1', 'activated': false};
      await state.record(
        {'id': 'question-2', 'version': 'v4'},
        {'B'},
        12,
        practiceState: {
          'cursor': 1,
          'submitted': [1],
        },
      );
      final restarted = AppState(store)
        ..user = {'id': 'student-1', 'activated': false};
      await restarted.loadLocal();
      expect(restarted.practice!['submitted'], [1]);
      expect(restarted.queue.single['question_id'], 'question-2');
      expect(restarted.queue.single['question_version'], 'v4');
      expect(
        restarted.queue.single['client_uuid'],
        state.queue.single['client_uuid'],
      );
      state.dispose();
      restarted.dispose();
    },
  );
  test('late refresh cannot restore a cleared session', () async {
    final store = MemoryStore();
    final response = Completer<http.Response>();
    final api = Api(store, client: MockClient((_) => response.future))
      ..consented = true
      ..refresh = 'old';
    final pending = api.refreshSession();
    api.invalidateSession();
    response.complete(
      http.Response(
        jsonEncode({
          'access_token': 'late_access',
          'refresh_token': 'late_refresh',
        }),
        200,
      ),
    );
    await expectLater(pending, throwsA(isA<AppError>()));
    expect(api.access, isNull);
    expect(api.refresh, isNull);
    expect(store.values['secure_refresh'], isNull);
    api.client.close();
  });
  test(
    'authoritative auth denial never falls back to cached questions',
    () async {
      final store = MemoryStore();
      final api = Api(
        store,
        client: MockClient(
          (_) async => http.Response('{"detail":"consent required"}', 403),
        ),
      )..consented = true;
      final state = AppState(store, api)
        ..user = {'id': 's1', 'activated': false}
        ..offline = {
          's': {
            'subject_id': 's',
            'questions': [
              {'id': 'cached'},
            ],
          },
        };
      await expectLater(
        state.questions('s', 'all', 10),
        throwsA(isA<AppError>().having((e) => e.status, 'status', 403)),
      );
      state.dispose();
    },
  );
  test(
    'student and teacher app revokes tokens issued to an admin role',
    () async {
      final store = MemoryStore();
      bool revoked = false;
      final api = Api(
        store,
        client: MockClient((request) async {
          if (request.url.path.endsWith('/public/config'))
            return http.Response('{"agreement_version":"v1"}', 200);
          if (request.url.path.endsWith('/auth/login'))
            return http.Response(
              '{"access_token":"staff_access","refresh_token":"staff_refresh","user":{"id":"admin","role":"admin"}}',
              200,
            );
          if (request.url.path.endsWith('/auth/logout')) {
            revoked =
                request.headers['Authorization'] == 'Bearer staff_access' &&
                jsonDecode(request.body)['refresh_token'] == 'staff_refresh';
            return http.Response('{"ok":true}', 200);
          }
          return http.Response('{}', 404);
        }),
      )..consented = true;
      final state = AppState(store, api);
      await expectLater(
        state.login('admin', 'password'),
        throwsA(isA<AppError>()),
      );
      expect(revoked, isTrue);
      expect(api.access, isNull);
      expect(store.values['secure_refresh'], isNull);
      state.dispose();
    },
  );
  test(
    'knowledge type difficulty and random mode reach practice API',
    () async {
      final store = MemoryStore();
      Map<String, String> query = {};
      final api = Api(
        store,
        client: MockClient((request) async {
          query = request.url.queryParameters;
          return http.Response('[{"id":"q1"}]', 200);
        }),
      )..consented = true;
      final state = AppState(store, api);
      final result = await state.questions(
        'math',
        'all',
        5,
        knowledgeId: 'knowledge-2',
        type: 'multiple',
        difficulty: 2,
        random: true,
      );
      expect(result.single['id'], 'q1');
      expect(query, {
        'subject_id': 'math',
        'mode': 'all',
        'limit': '5',
        'shuffle': 'true',
        'knowledge_id': 'knowledge-2',
        'type': 'multiple',
        'difficulty': '2',
      });
      state.dispose();
    },
  );
}
