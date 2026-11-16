import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zhikaotong/core.dart';

import 'continuous_core_test.dart' as network;
import 'question_type_scope_test.dart' as typed;

Json categoryProgress(
  String? category, {
  String? type = 'single',
  String mode = 'all',
  String tag = 'saved',
}) {
  final value = typed.progress(type, mode: mode, tag: '$category-$tag');
  value['subject_id'] = 'english';
  value['category_id'] = category;
  (value['questions'] as List).first['subject_id'] = 'english';
  return value;
}

Json categoryQuestion(String id, String? category) => {
  ...network.question(id, version: 5),
  'subject_id': 'english',
  if (category != null) 'category_id': category,
  if (category != null)
    'category_name': category == 'reading' ? '阅读理解' : '语音辨析',
};

Json categoryManifest(List<Json> questions) => {
  'version': 5,
  'subjects': [
    {'id': 'english'},
  ],
  'questions': [
    for (final question in questions)
      {
        'id': question['id'],
        'subject_id': question['subject_id'],
        if (question['category_id'] != null)
          'category_id': question['category_id'],
        if (question['category_name'] != null)
          'category_name': question['category_name'],
      },
  ],
};

Json classifiedPage({int offset = 0}) => {
  'version': 5,
  'total': 22,
  'offset': offset,
  'next_offset': offset + 2,
  'has_more': offset + 2 < 22,
  'seed': network.seed,
  'pool_hash': network.poolHash,
  'questions': [
    categoryQuestion('reading-$offset', 'reading'),
    categoryQuestion('reading-${offset + 1}', 'reading'),
  ],
};

void main() {
  test(
    'content scopes keep legacy keys and never infer a sampled category',
    () {
      final mixed = categoryProgress(null, type: null);
      final typedAll = categoryProgress(null);
      final reading = categoryProgress('reading');
      final phonetics = categoryProgress('phonetics');
      expect(AppState.practiceScope(mixed), 'all:english');
      expect(AppState.practiceScope(typedAll), 'all:english:single');
      expect(
        AppState.practiceScope(reading),
        'all:english:single:category:reading',
      );
      expect(
        AppState.practiceScope(reading),
        isNot(AppState.practiceScope(phonetics)),
      );
      expect(
        AppState.practiceScope(categoryProgress('reading', mode: 'wrong')),
        'wrong:english:single:category:reading',
      );
      final sampled = categoryProgress('reading')..remove('category_id');
      (sampled['questions'] as List).first['category_id'] = 'reading';
      expect(AppState.practiceCategory(sampled), isNull);
      sampled['stream'] = {'category_id': 'reading'};
      expect(AppState.practiceCategory(sampled), 'reading');
      expect(
        AppState.practiceCategory({...sampled, 'category_id': null}),
        isNull,
      );
    },
  );

  test(
    'restart retains every legacy and classified answer and home continuation',
    () async {
      final store = typed.TypeScopeStore();
      final state = typed.school(store);
      addTearDown(state.dispose);
      final mixed = categoryProgress(null, type: null);
      final single = categoryProgress(null);
      final reading = categoryProgress('reading');
      final phonetics = categoryProgress('phonetics');
      state.queue = [
        {
          'client_uuid': 'historical-outbox',
          'selected': ['A'],
        },
      ];
      await state.activatePractice(mixed);
      await state.activatePractice(single);
      await state.activatePractice(reading);
      await state.activatePractice(phonetics);
      await state.activatePractice(
        categoryProgress('reading', mode: 'favorite'),
      );
      final restarted = typed.school(store);
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      for (final value in [mixed, single, reading, phonetics]) {
        final restored = restarted.savedPractice(
          'english',
          type: AppState.practiceType(value),
          categoryId: AppState.practiceCategory(value),
        );
        expect(restored!['session_id'], value['session_id']);
        expect(restored['answers'], value['answers']);
      }
      expect(restarted.homePractice!['session_id'], phonetics['session_id']);
      expect(restarted.queue.single['client_uuid'], 'historical-outbox');
      expect(restarted.practices.length, 5);
    },
  );

  test(
    'failed classified restart restores only its scope after another category starts',
    () async {
      final store = typed.TypeScopeStore();
      final state = typed.school(store);
      addTearDown(state.dispose);
      final oldReading = categoryProgress('reading');
      await state.activatePractice(oldReading);
      final gate = Completer<void>();
      store.nextWrite = gate;
      store.failNext = true;
      final failed = state.activatePractice(
        categoryProgress('reading', tag: 'failed'),
      );
      final assertion = expectLater(failed, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final phonetics = categoryProgress('phonetics');
      final switched = state.activatePractice(phonetics);
      gate.complete();
      await assertion;
      await switched;
      final restarted = typed.school(store);
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      expect(
        restarted.savedPractice(
          'english',
          type: 'single',
          categoryId: 'reading',
        )!['session_id'],
        oldReading['session_id'],
      );
      expect(restarted.homePractice!['session_id'], phonetics['session_id']);
    },
  );

  test(
    'catalog helpers keep category types separate and old missing counts unknown',
    () {
      final state = typed.school(typed.TypeScopeStore());
      addTearDown(state.dispose);
      const counts = {'single': 160, 'multiple': 0, 'judge': 80, 'fill': 0};
      state.subjects = [
        {
          'id': 'english',
          'by_type': {'single': 583, 'multiple': 0, 'judge': 80, 'fill': 0},
          'categories': [
            {'id': 'reading', 'name': '阅读理解', 'total': 240, 'by_type': counts},
            {'id': 'phonetics', 'name': '语音辨析', 'total': 31},
          ],
        },
        {'id': 'old-subject'},
      ];
      expect(state.contentCategories('english').length, 2);
      expect(state.categoryTypeCounts('english', 'reading'), counts);
      expect(state.categoryTypeCounts('english', 'phonetics'), isNull);
      expect(state.categoryTypeCounts('english', 'hidden'), isNull);
      expect(state.categoryTypeCounts('english', null)!['single'], 583);
      expect(state.categoryTypeCounts('', null), isNull);
      expect(state.contentCategories('hidden-subject'), isEmpty);
      expect(state.contentCategories(''), isEmpty);
      expect(state.categoryName('english', 'reading'), '阅读理解');
      expect(state.categoryName('english', null), '全部题目');
      expect(state.categoryName('english', 'private-id'), '所选分类');
    },
  );

  test(
    'normal and continuous requests keep exact category type and cursor',
    () async {
      final requests = <http.Request>[];
      final state = network.school(network.ContinuousStore(), (request) async {
        requests.add(request);
        return network.ok(
          request.url.path.endsWith('/continuous')
              ? classifiedPage(offset: 20)
              : [categoryQuestion('reading-one', 'reading')],
        );
      });
      addTearDown(state.dispose);
      final normal = await state.questions(
        'english',
        'all',
        5,
        type: 'single',
        categoryId: 'reading',
      );
      expect(normal.single['category_id'], 'reading');
      expect(requests.single.url.queryParameters['category_id'], 'reading');
      final result = await state.continuousQuestions(
        'english',
        categoryId: 'reading',
        type: 'single',
        offset: 20,
        seed: network.seed,
        version: 5,
        poolHash: network.poolHash,
      );
      expect(requests.last.url.queryParameters['category_id'], 'reading');
      expect(requests.last.url.queryParameters['offset'], '20');
      expect(result['next_offset'], 22);
      expect(result['questions'], hasLength(2));
      await expectLater(
        state.questions('', 'all', 5, categoryId: 'reading'),
        network.appFailure(422),
      );
      await expectLater(
        state.continuousQuestions('', categoryId: 'reading'),
        network.appFailure(422),
      );
      expect(requests.length, 2);
    },
  );

  test(
    'number-prefixed category metadata remains compatible with future catalogs',
    () async {
      final store = network.ContinuousStore();
      final question = categoryQuestion('numbered-topic', '2026-topic');
      final state = network.school(store, (request) async {
        if (request.url.path.endsWith('/manifest')) {
          return network.ok(categoryManifest([question]));
        }
        throw http.ClientException('offline');
      });
      addTearDown(state.dispose);
      state.subjects = [
        {
          'id': 'english',
          'categories': [
            {'id': '2026-topic', 'name': '新内容分类', 'total': 1},
          ],
        },
      ];
      expect(state.contentCategories('english').single['id'], '2026-topic');
      await state.refreshBank();
      expect(state.bankManifest!['questions'][0]['category_id'], '2026-topic');
      expect(
        state.questionCategoryId(categoryQuestion('numbered-topic', null)),
        '2026-topic',
      );
    },
  );

  test(
    'ignored online category cannot silently return other or unclassified questions',
    () async {
      for (final category in <String?>['phonetics', null]) {
        final state = network.school(
          network.ContinuousStore(),
          (_) async => network.ok([categoryQuestion('wrong-scope', category)]),
        );
        addTearDown(state.dispose);
        await expectLater(
          state.questions('english', 'all', 5, categoryId: 'reading'),
          network.appFailure(409),
        );
      }
    },
  );

  test(
    'continuous wrong-category page is rejected without touching progress',
    () async {
      final store = network.ContinuousStore();
      final state = network.school(store, (request) async {
        if (request.url.path.endsWith('/manifest')) {
          throw http.ClientException('manifest unavailable');
        }
        return network.ok({
          ...classifiedPage(),
          'questions': [
            categoryQuestion('phonetic-one', 'phonetics'),
            categoryQuestion('phonetic-two', 'phonetics'),
          ],
        });
      });
      addTearDown(state.dispose);
      final saved = categoryProgress('reading');
      await state.activatePractice(saved);
      final before = jsonEncode(store.values);
      await expectLater(
        state.continuousQuestions('english', categoryId: 'reading'),
        network.appFailure(409),
      );
      expect(state.homePractice, same(saved));
      expect(jsonEncode(store.values), before);
    },
  );

  test(
    'new manifest classifies old cached payloads without rewriting package bytes',
    () async {
      final store = network.ContinuousStore();
      final reading = categoryQuestion('read-old-cache', 'reading');
      final phonetics = categoryQuestion('phon-old-cache', 'phonetics');
      final manifest = categoryManifest([reading, phonetics]);
      final state = network.school(store, (request) async {
        if (request.url.path.endsWith('/manifest')) return network.ok(manifest);
        throw http.ClientException('offline');
      });
      addTearDown(state.dispose);
      await state.refreshBank();
      expect(state.bankManifest!['questions'][0]['category_id'], 'reading');
      state.offline = {
        'english': {
          'version': 5,
          'subject_id': 'english',
          'questions': [
            categoryQuestion('read-old-cache', null),
            categoryQuestion('phon-old-cache', null),
          ],
        },
      };
      final original = jsonEncode(state.offline);
      final results = await state.questions(
        'english',
        'all',
        5,
        categoryId: 'reading',
      );
      expect(results.map((q) => q['id']), ['read-old-cache']);
      expect(results.single['category_name'], '阅读理解');
      expect(jsonEncode(state.offline), original);
      await state.persist();
      final restarted = network.school(
        store,
        (_) async => throw http.ClientException('offline'),
      );
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      expect(
        (await restarted.questions(
          'english',
          'all',
          5,
          categoryId: 'phonetics',
        )).single['id'],
        'phon-old-cache',
      );
    },
  );

  test(
    'unknown old cache category never broadens a classified offline pool',
    () async {
      final state =
          network.school(
              network.ContinuousStore(),
              (_) async => throw http.ClientException('offline'),
            )
            ..offline = {
              'english': {
                'subject_id': 'english',
                'questions': [categoryQuestion('unclassified', null)],
              },
            };
      addTearDown(state.dispose);
      await expectLater(
        state.questions('english', 'all', 5, categoryId: 'reading'),
        network.appFailure(),
      );
      expect(state.offlineMode, isFalse);
      expect(
        (await state.questions('english', 'all', 5)).single['id'],
        'unclassified',
      );
    },
  );

  test(
    'same category in another subject cannot enter finite online practice',
    () async {
      final state = network.school(
        network.ContinuousStore(),
        (_) async => network.ok([
          {
            ...categoryQuestion('chinese-reading', 'reading'),
            'subject_id': 'chinese',
          },
        ]),
      );
      addTearDown(state.dispose);
      await expectLater(
        state.questions('english', 'all', 5, categoryId: 'reading'),
        network.appFailure(409),
      );
    },
  );

  test(
    'misplaced cache payload cannot borrow its package subject and category',
    () async {
      final state =
          network.school(
              network.ContinuousStore(),
              (_) async => throw http.ClientException('offline'),
            )
            ..offline = {
              'english': {
                'subject_id': 'english',
                'questions': [
                  {
                    ...categoryQuestion('chinese-reading', 'reading'),
                    'subject_id': 'chinese',
                  },
                ],
              },
            };
      addTearDown(state.dispose);
      expect(state.cachedQuestions('english', 'all'), isEmpty);
      await expectLater(
        state.questions('english', 'all', 5, categoryId: 'reading'),
        network.appFailure(),
      );
      expect(state.offlineMode, isFalse);
    },
  );

  test('manifest outside its declared visible subjects is rejected', () async {
    final state = network.school(
      network.ContinuousStore(),
      (_) async => network.ok({
        ...categoryManifest([categoryQuestion('foreign', 'reading')]),
        'subjects': [
          {'id': 'math'},
        ],
      }),
    );
    addTearDown(state.dispose);
    await state.refreshBank();
    expect(state.bankManifest, isNull);
  });

  test(
    'late category response and failed old session cannot enter new user cache',
    () async {
      for (final fail in [false, true]) {
        final gate = Completer<http.Response>();
        final started = Completer<void>();
        final state = network.school(network.ContinuousStore(), (_) {
          started.complete();
          return gate.future;
        });
        addTearDown(state.dispose);
        final pending = state.questions(
          'english',
          'all',
          5,
          categoryId: 'reading',
        );
        final assertion = expectLater(pending, network.appFailure(401));
        await started.future;
        state.api.invalidateSession();
        state.user = {...state.user!, 'id': 'another-student'};
        state.offline = {
          'english': {
            'subject_id': 'english',
            'questions': [categoryQuestion('new-owner-cache', 'reading')],
          },
        };
        if (fail) {
          gate.completeError(http.ClientException('offline'));
        } else {
          gate.complete(
            network.ok([categoryQuestion('old-owner-response', 'reading')]),
          );
        }
        await assertion;
        expect(state.practice, isNull);
        expect(state.offlineMode, isFalse);
      }
    },
  );
}
