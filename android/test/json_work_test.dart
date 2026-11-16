import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/json_work.dart';

final largeMedia = List.filled(90 * 1024, 'A').join();
Json progress(String subject, {bool submitted = false}) => {
  'mode': 'all',
  'subject_id': subject,
  'session_id': 'session-$subject',
  'questions': [
    {
      'id': 'q-$subject',
      'subject_id': subject,
      'version': 1,
      'media': {
        'image': {'data': largeMedia},
      },
    },
  ],
  'cursor': 0,
  'answers': {
    '0': ['B'],
  },
  'submitted': submitted ? [0] : <int>[],
};

class NativeStorage {
  final files = <String, String>{};
  final secure = <String, String>{};
  final calls = <MethodCall>[];
  Future<void> Function(MethodCall)? beforeWrite;
  Future<dynamic> handle(MethodCall call) async {
    calls.add(call);
    final args = Map<String, dynamic>.from(call.arguments as Map);
    final key = args['key'] as String;
    switch (call.method) {
      case 'read':
        return files[key];
      case 'write':
        await beforeWrite?.call(call);
        files[key] = args['value'] as String;
        return null;
      case 'delete':
        files.remove(key);
        return null;
      case 'secureRead':
        return secure[key];
      case 'secureWrite':
        if (args['value'] == null) {
          secure.remove(key);
        } else {
          secure[key] = args['value'] as String;
        }
        return null;
      default:
        throw StateError('Unexpected native method ${call.method}');
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeStorage native;
  setUp(() {
    native = NativeStorage();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalStore.channel, native.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(LocalStore.channel, null);
  });

  test(
    'snapshot isolates every mutable JSON container and shares original immutable media string',
    () {
      final shared = {
        'value': [1, true, null, 2.5, '中文\n😀'],
      };
      final source = {'first': shared, 'second': shared, 'media': largeMedia};
      final snapshot = JsonSnapshot.capture(source);
      expect(snapshot.value, jsonDecode(jsonEncode(source)));
      expect(snapshot.isLarge, true);
      expect(identical(snapshot.value['media'], largeMedia), true);
      expect(identical(snapshot.value['first'], shared), false);
      expect(
        identical(snapshot.value['first'], snapshot.value['second']),
        false,
      );
      (shared['value'] as List).add('later');
      source['media'] = 'replaced';
      expect(snapshot.value['first']['value'], [1, true, null, 2.5, '中文\n😀']);
      expect(snapshot.value['media'], largeMedia);
    },
  );

  test(
    'snapshot rejects cycles nonstring keys and nonJSON scalar values while repeated references remain legal',
    () {
      final cycle = <dynamic>[];
      cycle.add(cycle);
      expect(
        () => JsonSnapshot.capture(cycle),
        throwsA(isA<JsonCyclicError>()),
      );
      final objectCycle = <String, dynamic>{};
      objectCycle['self'] = objectCycle;
      expect(
        () => JsonSnapshot.capture(objectCycle),
        throwsA(isA<JsonCyclicError>()),
      );
      for (final invalid in [
        DateTime.utc(2026),
        {1, 2},
        {1: 'wrong key'},
        double.nan,
        double.infinity,
        Object(),
      ]) {
        expect(
          () => JsonSnapshot.capture(invalid),
          throwsA(isA<JsonUnsupportedObjectError>()),
        );
      }
      for (final scalar in [null, true, false, 0, -1, 1.25, '']) {
        expect(JsonSnapshot.capture(scalar).value, scalar);
      }
    },
  );

  test(
    'work threshold detects ASCII media multibyte text and escaped control characters without changing JSON values',
    () {
      final small = {
        'text': '中文\n😀',
        'answer': [true, null, 1.0],
      };
      final unicode = {'text': List.filled(24000, '题').join()};
      final escaped = {'text': List.filled(12000, '\u0001').join()};
      expect(JsonSnapshot.capture(small).isLarge, false);
      expect(JsonSnapshot.capture(unicode).isLarge, true);
      expect(JsonSnapshot.capture(escaped).isLarge, true);
      expect(isLargeJsonText(jsonEncode(small)), false);
      expect(isLargeJsonText(jsonEncode(unicode)), true);
      for (final value in [
        small,
        unicode,
        escaped,
        {'data': largeMedia},
      ]) {
        final encoded = encodeJsonValue(JsonSnapshot.capture(value).value);
        expect(encoded, jsonEncode(value));
        expect(decodeJsonText(encoded), value);
        expect(decodeJsonBytes(utf8.encode(encoded)), value);
      }
    },
  );

  test(
    'prepared shuffled options are independent of caller maps and retain untouched original image payload',
    () {
      final question = {
        'id': 'q1',
        'stem': '选择合适的水果',
        'type': 'single',
        'options': [
          {'key': 'A', 'text': '苹果'},
          {'key': 'B', 'text': '梨'},
          {'key': 'C', 'text': '桃'},
        ],
        'answer': ['B'],
        'extra': {'media': largeMedia},
      };
      final before = jsonEncode(question);
      final prepared = preparePracticeQuestions(
        [question],
        shuffleOptions: true,
        random: Random(4),
      );
      prepared.single['options'][0]['text'] = 'changed';
      expect(jsonEncode(question), before);
      expect(identical(prepared.single['extra']['media'], largeMedia), true);
      expect(prepared.single['answer'], ['B']);
    },
  );

  test(
    'LocalStore keeps JSON string channel protocol and freezes mutable small and large writes at invocation',
    () async {
      final store = LocalStore();
      final small = {
        'answers': ['A'],
      };
      final big = {
        'data': largeMedia,
        'answers': ['B'],
      };
      final writes = [store.write('small', small), store.write('large', big)];
      (small['answers'] as List).add('changed');
      (big['answers'] as List).clear();
      big['data'] = 'changed';
      await Future.wait(writes);
      expect(native.calls.map((c) => c.method), ['write', 'write']);
      for (final call in native.calls) {
        final args = call.arguments as Map;
        expect(args.keys.toSet(), {'key', 'value'});
        expect(args['value'], isA<String>());
      }
      expect(jsonDecode(native.files['small']!), {
        'answers': ['A'],
      });
      expect(jsonDecode(native.files['large']!), {
        'data': largeMedia,
        'answers': ['B'],
      });
      expect(await store.read('small'), {
        'answers': ['A'],
      });
      expect(await store.read('large'), {
        'data': largeMedia,
        'answers': ['B'],
      });
    },
  );

  test(
    'large write cannot overtake later small write delete read or secure operations and resurrect deleted data',
    () async {
      final store = LocalStore();
      final operations = <Future<dynamic>>[
        store.write('same', {'data': largeMedia}),
        store.write('same', {'data': 'latest'}),
        store.remove('same'),
        store.secureWrite('refresh', 'secret-token'),
        store.secureRead('refresh'),
        store.read('same'),
      ];
      final results = await Future.wait(operations);
      expect(native.calls.map((c) => c.method), [
        'write',
        'write',
        'delete',
        'secureWrite',
        'secureRead',
        'read',
      ]);
      expect(results[4], 'secret-token');
      expect(results[5], isNull);
      expect(native.files.containsKey('same'), false);
      expect(jsonDecode((native.calls[0].arguments as Map)['value']), {
        'data': largeMedia,
      });
      expect(jsonDecode((native.calls[1].arguments as Map)['value']), {
        'data': 'latest',
      });
      await store.secureWrite('refresh', null);
      expect(await store.secureRead('refresh'), isNull);
    },
  );

  test(
    'failed native write and malformed read surface to caller while later queued operations still run',
    () async {
      var fail = true;
      native.beforeWrite = (_) async {
        if (fail) {
          fail = false;
          throw PlatformException(code: 'STORAGE_ERROR');
        }
      };
      final store = LocalStore();
      final rejected = expectLater(
        store.write('failed', {'data': largeMedia}),
        throwsA(isA<PlatformException>()),
      );
      final later = store.write('kept', {'answer': 'B'});
      await Future.wait([rejected, later]);
      expect(native.files['failed'], isNull);
      expect(await store.read('kept'), {'answer': 'B'});
      native.files['broken'] = '[bad json';
      final invalid = expectLater(store.read('broken'), throwsFormatException);
      await Future.wait([invalid, store.remove('broken')]);
      expect(native.files.containsKey('broken'), false);
      expect(
        () => store.write('invalid', {'nonJSON': Object()}),
        throwsA(isA<JsonUnsupportedObjectError>()),
      );
      await store.write('after-invalid', true);
      expect(await store.read('after-invalid'), true);
    },
  );

  test(
    'AppState persists exact call-time outbox and practice despite queued writes and later mutations',
    () async {
      final gate = Completer<void>(), entered = Completer<void>();
      native.beforeWrite = (_) async {
        if (!entered.isCompleted) {
          entered.complete();
          await gate.future;
        }
      };
      final state = AppState(LocalStore())
        ..user = {'id': 'student', 'activated': false};
      addTearDown(state.dispose);
      state.queue = [
        {
          'client_uuid': 'original',
          'selected': ['A'],
        },
      ];
      state.practice = progress('math');
      final first = state.persist();
      state.queue.single['selected'] = ['B'];
      state.practice!['submitted'] = [0];
      final second = state.persist();
      await entered.future;
      final firstValue = jsonDecode(
        (native.calls.first.arguments as Map)['value'],
      );
      expect(firstValue['queue'].single['selected'], ['A']);
      expect(firstValue['practice']['submitted'], isEmpty);
      gate.complete();
      await Future.wait([first, second]);
      final disk = jsonDecode(native.files['data_${state.cacheKey}']!);
      expect(disk['queue'].single['selected'], ['B']);
      expect(disk['practice']['submitted'], [0]);
    },
  );

  test(
    'record failed async durable write retains historical answers and retry atomically saves outbox plus submitted practice',
    () async {
      final state = AppState(LocalStore())
        ..user = {'id': 'student', 'activated': false};
      addTearDown(state.dispose);
      state.queue = [
        {
          'client_uuid': 'historical',
          'selected': ['A'],
        },
      ];
      final previous = progress('math');
      state.practice = previous;
      await state.persist();
      var fail = true;
      native.beforeWrite = (_) async {
        if (fail) {
          fail = false;
          throw PlatformException(code: 'STORAGE_ERROR');
        }
      };
      await expectLater(
        state.record(
          {'id': 'q-math', 'version': 1},
          ['B'],
          7,
          practiceState: progress('math', submitted: true),
        ),
        throwsA(isA<PlatformException>()),
      );
      expect(state.queue.map((v) => v['client_uuid']), ['historical']);
      expect(state.practice, previous);
      expect(
        jsonDecode(
          native.files['data_${state.cacheKey}']!,
        )['practice']['submitted'],
        isEmpty,
      );
      await state.record(
        {'id': 'q-math', 'version': 1},
        ['B'],
        7,
        practiceState: progress('math', submitted: true),
      );
      final disk = jsonDecode(native.files['data_${state.cacheKey}']!);
      expect(disk['queue'], hasLength(2));
      expect(disk['queue'].first['client_uuid'], 'historical');
      expect(disk['queue'].last['selected'], ['B']);
      expect(
        disk['queue'].last['client_uuid'],
        state.queue.last['client_uuid'],
      );
      expect(disk['practice']['submitted'], [0]);
    },
  );

  test(
    'rollback compensation failure preserves the original answer save error',
    () async {
      final state = AppState(LocalStore())
        ..user = {'id': 'student', 'activated': false};
      addTearDown(state.dispose);
      state.queue = [
        {'client_uuid': 'historical'},
      ];
      final previous = progress('math');
      state.practice = previous;
      var writes = 0;
      native.beforeWrite = (_) async {
        throw PlatformException(
          code: ++writes == 1 ? 'ORIGINAL_SAVE' : 'COMPENSATION_SAVE',
        );
      };
      await expectLater(
        state.record(
          {'id': 'q-math', 'version': 1},
          ['B'],
          7,
          practiceState: progress('math', submitted: true),
        ),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'ORIGINAL_SAVE',
          ),
        ),
      );
      expect(writes, 2);
      expect(state.queue.single['client_uuid'], 'historical');
      expect(state.practice, same(previous));
      expect(state.savedPractice('math')!['submitted'], isEmpty);
    },
  );

  test(
    'late failed record never restores old account practice into a new session',
    () async {
      final state = AppState(LocalStore())
        ..user = {'id': 'old', 'activated': false};
      addTearDown(state.dispose);
      state.practice = progress('math');
      final gate = Completer<void>(), entered = Completer<void>();
      native.beforeWrite = (_) async {
        entered.complete();
        await gate.future;
        throw PlatformException(code: 'STORAGE_ERROR');
      };
      final failed = expectLater(
        state.record(
          {'id': 'q-math', 'version': 1},
          ['B'],
          7,
          practiceState: progress('math', submitted: true),
        ),
        throwsA(isA<PlatformException>()),
      );
      await entered.future;
      state.api.invalidateSession();
      state.user = {'id': 'new', 'activated': false};
      state.queue = [
        {
          'client_uuid': 'new-answer',
          'selected': ['C'],
        },
      ];
      state.practices.clear();
      state.practice = null;
      final next = progress('english');
      state.practice = next;
      gate.complete();
      await failed;
      expect(state.practice, same(next));
      expect(state.practices.keys, ['all:english']);
      expect(state.queue.single['client_uuid'], 'new-answer');
      expect(state.savedPractice('math'), isNull);
    },
  );

  for (final hadMathSlot in [true, false]) {
    test(
      'late failed record repairs durable archived scope while preserving newer English activation (old math slot: $hadMathSlot)',
      () async {
        final state = AppState(LocalStore())
          ..user = {'id': 'student', 'activated': false};
        addTearDown(state.dispose);
        state.queue = [
          {
            'client_uuid': 'historical',
            'selected': ['A'],
          },
        ];
        final oldMath = progress('math')
          ..['answers'] = {
            '0': ['A'],
          };
        if (hadMathSlot) state.practice = oldMath;
        final gate = Completer<void>(), entered = Completer<void>();
        var writes = 0;
        native.beforeWrite = (_) async {
          if (++writes == 1) {
            entered.complete();
            await gate.future;
            throw PlatformException(code: 'STORAGE_ERROR');
          }
        };
        final failed = expectLater(
          state.record(
            {'id': 'q-math', 'version': 1},
            ['B'],
            7,
            practiceState: progress('math', submitted: true),
          ),
          throwsA(isA<PlatformException>()),
        );
        await entered.future;
        final next = progress('english')
          ..['answers'] = {
            '0': ['D'],
          };
        final activated = state.activatePractice(next);
        gate.complete();
        await Future.wait([failed, activated]);
        expect(state.practice, same(next));
        expect(state.savedPractice('english'), next);
        expect(state.lastOrdinaryPracticeScope, 'all:english');
        expect(state.queue.single['client_uuid'], 'historical');
        if (hadMathSlot) {
          expect(state.savedPractice('math'), same(oldMath));
          expect(state.savedPractice('math')!['submitted'], isEmpty);
          expect(state.savedPractice('math')!['answers'], {
            '0': ['A'],
          });
        } else {
          expect(state.savedPractice('math'), isNull);
          expect(state.practices.containsKey('all:math'), false);
        }
        final restarted = AppState(LocalStore())
          ..user = {'id': 'student', 'activated': false};
        addTearDown(restarted.dispose);
        await restarted.loadLocal();
        expect(restarted.practice, next);
        expect(restarted.savedPractice('english'), next);
        expect(restarted.lastOrdinaryPracticeScope, 'all:english');
        expect(restarted.queue, [
          {
            'client_uuid': 'historical',
            'selected': ['A'],
          },
        ]);
        expect(restarted.savedPractice('math'), hadMathSlot ? oldMath : isNull);
        final disk = jsonDecode(native.files['data_${state.cacheKey}']!);
        expect(disk['practice']['subject_id'], 'english');
        expect(disk['practice']['answers'], {
          '0': ['D'],
        });
        expect(disk['queue'], [
          {
            'client_uuid': 'historical',
            'selected': ['A'],
          },
        ]);
      },
    );
  }

  test(
    'small and large API responses decode identically and preserve errors plus media capability header',
    () async {
      final bodies = [
        {'text': '中文\n😀'},
        {'text': '中文\n😀', 'data': largeMedia},
      ];
      final seen = <http.Request>[];
      final api = Api(
        LocalStore(),
        client: MockClient((request) async {
          seen.add(request);
          if (request.url.path.endsWith('/denied')) {
            return http.Response(
              jsonEncode({'detail': '当前科目已撤销', 'padding': largeMedia}),
              403,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          return http.Response(
            jsonEncode(
              request.url.path.endsWith('/large') ? bodies.last : bodies.first,
            ),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      )..consented = true;
      addTearDown(api.client.close);
      expect(await api.call('GET', '/small'), bodies.first);
      expect(await api.call('GET', '/large'), bodies.last);
      await expectLater(
        api.call('GET', '/denied'),
        throwsA(
          isA<AppError>()
              .having((e) => e.status, 'status', 403)
              .having((e) => e.message, 'message', '当前科目已撤销'),
        ),
      );
      expect(
        seen.every((r) => r.headers['X-Question-Content'] == 'media-v1'),
        true,
      );
    },
  );

  test('late large API response cannot cross an invalidated session', () async {
    final pending = Completer<http.Response>(), entered = Completer<void>();
    final api = Api(
      LocalStore(),
      client: MockClient((_) async {
        entered.complete();
        return pending.future;
      }),
    )..consented = true;
    addTearDown(api.client.close);
    final result = expectLater(
      api.call('GET', '/large'),
      throwsA(isA<AppError>().having((e) => e.status, 'status', 401)),
    );
    await entered.future;
    api.invalidateSession();
    pending.complete(http.Response(jsonEncode({'data': largeMedia}), 200));
    await result;
  });

  test(
    'async package validation matches canonical algorithm and freezes mutable package before worker scheduling',
    () async {
      for (final data in ['small', largeMedia]) {
        final questions = [
          {'id': 'q1', 'stem': '中文', 'media': data},
        ];
        final digest = sha256
            .convert(utf8.encode(jsonEncode(canonical(questions))))
            .toString();
        final package = {'questions': questions, 'checksum': digest};
        expect(verifyPackage(package), true);
        final pending = verifyPackageAsync(package);
        questions.single['stem'] = 'after-call';
        expect(await pending, true);
        expect(verifyPackage(package), false);
        expect(await verifyPackageAsync(package), false);
      }
    },
  );
}
