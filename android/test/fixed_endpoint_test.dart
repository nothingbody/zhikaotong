import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/service_endpoint.dart';
import 'package:zhikaotong/teaching.dart';

class EndpointStore extends LocalStore {
  final values = <String, dynamic>{};
  String? failOnceKey;
  int secretReads = 0;
  @override
  Future<dynamic> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));
  @override
  Future<void> write(String key, dynamic value) async {
    if (failOnceKey == key) {
      failOnceKey = null;
      throw StateError('disk temporarily unavailable');
    }
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<String?> secureRead(String key) async {
    secretReads++;
    return values['secret_$key'] as String?;
  }

  @override
  Future<void> secureWrite(String key, String? value) async {
    values['secret_$key'] = value;
  }
}

String cache(String origin, String user) =>
    sha256.convert(utf8.encode('$origin|$user')).toString().substring(0, 32);
Json cachedRecord(String id) => {
  'client_uuid': id,
  'question_id': 'q',
  'selected': ['A'],
  'duration_seconds': 3,
};
Json package(int version) {
  final questions = [
    {'id': 'q', 'version': version},
  ];
  return {
    'version': version,
    'subject_id': 'math',
    'questions': questions,
    'checksum': sha256
        .convert(utf8.encode(jsonEncode(canonical(questions))))
        .toString(),
  };
}

class FakeSchool {
  final paths = <Uri>[];
  String user = 'student-1';
  bool rejectRefresh = false;
  late final client = MockClient((request) async {
    paths.add(request.url);
    final path = request.url.path;
    dynamic value;
    if (path == '/api/public/config') {
      value = {'agreement_version': 'v1'};
    } else if (path == '/api/auth/login') {
      value = {
        'access_token': 'new-access',
        'refresh_token': 'new-refresh',
        'user': identity,
      };
    } else if (path == '/api/auth/me') {
      if (request.headers['authorization'] == null)
        return http.Response('{"detail":"refresh"}', 401);
      value = identity;
    } else if (path == '/api/auth/refresh') {
      if (rejectRefresh) return http.Response('{"detail":"expired"}', 401);
      value = {
        'access_token': 'refreshed-access',
        'refresh_token': 'refreshed-token',
        'user': identity,
      };
    } else {
      return http.Response('{}', 404);
    }
    return http.Response(
      jsonEncode(value),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  Json get identity => {
    'id': user,
    'role': 'student',
    'activated': false,
    'must_change_password': false,
  };
}

void main() {
  test(
    'stored URL never changes the bundled endpoint, even before a login',
    () async {
      final store = EndpointStore()
        ..values.addAll({
          'privacy_accepted': true,
          'server': 'https://untrusted.example',
        });
      final school = FakeSchool();
      final api = Api(store, client: school.client);
      final state = AppState(store, api);
      await state.init();
      await state.login('student', 'password');
      expect(api.base, serviceBaseUrl);
      expect(school.paths, isNotEmpty);
      expect(school.paths.every((uri) => uri.origin == serviceBaseUrl), true);
      state.dispose();
    },
  );

  test(
    'privacy gate prevents refresh reads and HTTP despite a known legacy endpoint',
    () async {
      final store = EndpointStore()
        ..values.addAll({
          'server': 'http://localhost:18100',
          'secret_refresh': 'old',
          'last_user': {'id': 'student-1'},
        });
      final school = FakeSchool();
      final state = AppState(store, Api(store, client: school.client));
      await state.init();
      expect(school.paths, isEmpty);
      expect(store.secretReads, 0);
      expect(store.values.containsKey('legacy_service_origin'), false);
      state.dispose();
    },
  );

  test(
    'verified user migration merges outboxes, uses latest valid package and preserves current practice',
    () async {
      final store = EndpointStore()
        ..values['server'] = 'http://localhost:18100';
      final oldKey = cache('http://localhost:18100', 'student-1');
      final newKey = cache(serviceBaseUrl, 'student-1');
      final old = {
        'queue': [cachedRecord('old-1'), cachedRecord('shared')],
        'mark_queue': [
          {
            'question_id': 'q',
            'kind': 'favorite',
            'active': true,
            'updated_at': '2026-11-01T00:00:00Z',
          },
        ],
        'offline': {'math': package(3)},
        'practice': {'cursor': 2},
        'favorites': ['q'],
      };
      store.values['data_$oldKey'] = old;
      store.values['data_$newKey'] = {
        'queue': [cachedRecord('shared'), cachedRecord('new-2')],
        'mark_queue': [
          {
            'question_id': 'q',
            'kind': 'favorite',
            'active': false,
            'updated_at': '2026-11-02T00:00:00Z',
          },
        ],
        'offline': {'math': package(2)},
        'practice': {'cursor': 4},
      };
      final before = jsonEncode(old);
      final school = FakeSchool();
      final state = AppState(
        store,
        Api(store, client: school.client)..consented = true,
      );
      await state.login('student', 'password');
      expect(state.queue.map((item) => item['client_uuid']).toSet(), {
        'old-1',
        'shared',
        'new-2',
      });
      expect(state.markQueue.length, 1);
      expect(state.markQueue.single['active'], false);
      expect(state.favorites.contains('q'), false);
      expect(state.offline['math']['version'], 3);
      expect(state.practice!['cursor'], 4);
      expect(store.values['fixed_endpoint_migration_$newKey'], true);
      expect(jsonEncode(store.values['data_$oldKey']), before);
      // A stale source copy is not reimported after a successful upload emptied it.
      store.values['data_$newKey']['queue'] = [];
      await state.login('student', 'password');
      expect(state.queue, isEmpty);
      state.dispose();
    },
  );

  test(
    'expired legacy session can log in again and recover the original practice and queue',
    () async {
      final store = EndpointStore()
        ..values.addAll({
          'privacy_accepted': true,
          'server': 'http://10.0.2.2:18100',
          'last_user': {
            'id': 'student-1',
            'role': 'student',
            'activated': false,
          },
          'secret_refresh': 'expired',
        });
      final key = cache('http://10.0.2.2:18100', 'student-1');
      store.values['data_$key'] = {
        'queue': [cachedRecord('old')],
        'practice': {'cursor': 7},
      };
      final school = FakeSchool()..rejectRefresh = true;
      final state = AppState(store, Api(store, client: school.client));
      await state.init();
      expect(state.user, isNull);
      expect(store.values['last_user'], isNull);
      expect(store.values['legacy_service_origin'], 'http://10.0.2.2:18100');
      await state.login('student', 'password');
      expect(state.queue.single['client_uuid'], 'old');
      expect(state.practice!['cursor'], 7);
      expect(store.values['data_$key']['queue'].length, 1);
      state.dispose();
    },
  );

  test(
    'failed marker write retries migration without duplicating or deleting an old record',
    () async {
      final store = EndpointStore()
        ..values['server'] = 'http://127.0.0.1:18100';
      final oldKey = cache('http://127.0.0.1:18100', 'student-1');
      final newKey = cache(serviceBaseUrl, 'student-1');
      store.values['data_$oldKey'] = {
        'queue': [cachedRecord('durable-id')],
      };
      store.failOnceKey = 'fixed_endpoint_migration_$newKey';
      final school = FakeSchool();
      final state = AppState(
        store,
        Api(store, client: school.client)..consented = true,
      );
      await expectLater(
        state.login('student', 'password'),
        throwsA(isA<AppError>()),
      );
      expect(state.user, isNull);
      expect(store.values['data_$oldKey']['queue'].length, 1);
      await state.login('student', 'password');
      expect(state.queue.single['client_uuid'], 'durable-id');
      expect(store.values['fixed_endpoint_migration_$newKey'], true);
      state.dispose();
    },
  );

  test('unknown server and other user caches are never imported', () async {
    final store = EndpointStore()..values['server'] = 'https://other.example';
    final unknown = cache('https://other.example', 'student-1');
    final another = cache('http://localhost:18100', 'student-2');
    store.values['data_$unknown'] = {
      'queue': [cachedRecord('unknown')],
    };
    store.values['data_$another'] = {
      'queue': [cachedRecord('another-user')],
    };
    final school = FakeSchool();
    final state = AppState(
      store,
      Api(store, client: school.client)..consented = true,
    );
    await state.login('student', 'password');
    expect(state.queue, isEmpty);
    expect(store.values['data_$unknown']['queue'].length, 1);
    expect(store.values['data_$another']['queue'].length, 1);
    state.dispose();
  });

  test(
    'task migration copies a frozen UUID/body durably and never overwrites a new draft',
    () async {
      final store = EndpointStore();
      final original = {
        'answers': {
          'q': ['A'],
        },
        'pending': {
          'client_uuid': 'fixed-submission-id',
          'answers': [
            {
              'question_id': 'q',
              'selected': ['A'],
            },
          ],
        },
      };
      store.values['old-task'] = original;
      final copied = AssignmentDraft(
        store,
        'new-task',
        legacyKeys: ['old-task'],
      );
      await copied.load();
      expect(copied.pending, original['pending']);
      expect(store.values['new-task'], original);
      expect(store.values['old-task'], original);
      store.values['new-task']['pending']['client_uuid'] = 'newer-id';
      final next = AssignmentDraft(store, 'new-task', legacyKeys: ['old-task']);
      await next.load();
      expect(next.pending!['client_uuid'], 'newer-id');
      store.failOnceKey = 'failed-task';
      await expectLater(
        AssignmentDraft(store, 'failed-task', legacyKeys: ['old-task']).load(),
        throwsStateError,
      );
      expect(store.values['failed-task'], isNull);
      expect(store.values['old-task'], original);
    },
  );

  test(
    'service transport rejects changed origins and plaintext before reading certificate assets',
    () async {
      final client = SchoolServiceClient();
      for (final address in [
        'http://api.example.invalid:18443/api/public/config',
        'https://api.example.invalid/api/public/config',
        'https://untrusted.example:18443/api/public/config',
      ]) {
        await expectLater(
          client.send(http.Request('GET', Uri.parse(address))),
          throwsA(isA<http.ClientException>()),
        );
      }
      client.close();
    },
  );

  testWidgets(
    'login only displays school account and password, without any address controls',
    (tester) async {
      final store = EndpointStore();
      final state = AppState(store)..ready = true;
      await tester.pumpWidget(MaterialApp(home: LoginPage(state: state)));
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.text('服务器设置'), findsNothing);
      expect(find.text('学校服务器地址'), findsNothing);
      expect(find.byType(ExpansionTile), findsNothing);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
