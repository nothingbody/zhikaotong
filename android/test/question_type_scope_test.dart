import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/core.dart';

class TypeScopeStore extends LocalStore {
  final values = <String, dynamic>{};
  Completer<void>? nextWrite;
  bool failNext = false;
  int failuresRemaining = 0;

  @override
  Future<dynamic> read(String key) async =>
      values[key] == null ? null : jsonDecode(jsonEncode(values[key]));

  @override
  Future<void> write(String key, dynamic value) async {
    final gate = nextWrite;
    nextWrite = null;
    if (gate != null) await gate.future;
    if (failNext || failuresRemaining > 0) {
      failNext = false;
      if (failuresRemaining > 0) failuresRemaining--;
      throw StateError('disk full');
    }
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<void> secureWrite(String key, String? value) async {}
}

AppState school(TypeScopeStore store) => AppState(store)
  ..user = {
    'id': 'typed-progress-student',
    'role': 'student',
    'activated': false,
  };

Json progress(String? type, {String mode = 'all', String tag = 'saved'}) => {
  'mode': mode,
  'subject_id': 'math',
  'question_type': type,
  'session_id': '$mode-$type-$tag',
  'questions': [
    {
      'id': '$type-$tag',
      'subject_id': 'math',
      'version': 5,
      'type': type ?? 'single',
      'options': [
        {'key': 'A', 'text': '甲'},
        {'key': 'B', 'text': '乙'},
        {'key': 'C', 'text': '丙'},
      ],
      'answer': type == 'multiple' ? ['A', 'C'] : ['A'],
    },
  ],
  'cursor': 0,
  'answers': {
    '0': type == 'multiple' ? ['A', 'C'] : ['B'],
  },
  'submitted': <int>[],
  'durations': {'0': 8},
};

void main() {
  test(
    'two failed typed starts cannot resurrect the first temporary session',
    () async {
      final store = TypeScopeStore();
      final state = school(store);
      addTearDown(state.dispose);
      final oldMultiple = progress('multiple', tag: 'old-durable');
      await state.activatePractice(oldMultiple);
      final gate = Completer<void>();
      store.nextWrite = gate;
      store.failuresRemaining = 2;
      final first = state.activatePractice(
        progress('multiple', tag: 'failed-one'),
      );
      final firstFailure = expectLater(first, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final second = state.activatePractice(
        progress('single', tag: 'failed-two'),
      );
      final secondFailure = expectLater(second, throwsStateError);
      gate.complete();
      await firstFailure;
      await secondFailure;
      final restarted = school(store);
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      expect(restarted.homePractice!['session_id'], oldMultiple['session_id']);
      expect(
        restarted.savedPractice('math', type: 'multiple')!['session_id'],
        oldMultiple['session_id'],
      );
      expect(restarted.savedPractice('math', type: 'single'), isNull);
    },
  );
  test(
    'failed typed restart preserves the older slot behind a newer type write',
    () async {
      final store = TypeScopeStore();
      final state = school(store);
      addTearDown(state.dispose);
      final oldMultiple = progress('multiple', tag: 'old-round');
      await state.activatePractice(oldMultiple);
      final gate = Completer<void>();
      store.nextWrite = gate;
      store.failNext = true;
      final restart = state.activatePractice(
        progress('multiple', tag: 'failed-round'),
      );
      final assertion = expectLater(restart, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final single = progress('single', tag: 'newer-round');
      final switched = state.activatePractice(single);
      gate.complete();
      await assertion;
      await switched;
      final reopened = school(store);
      addTearDown(reopened.dispose);
      await reopened.loadLocal();
      expect(
        reopened.savedPractice('math', type: 'multiple')!['session_id'],
        oldMultiple['session_id'],
      );
      expect(
        reopened.savedPractice('math', type: 'multiple')!['answers'],
        oldMultiple['answers'],
      );
      expect(
        reopened.savedPractice('math', type: 'single')!['session_id'],
        single['session_id'],
      );
      expect(reopened.homePractice!['session_id'], single['session_id']);
    },
  );
  test(
    'single, multiple and mixed progress survive restart independently',
    () async {
      final store = TypeScopeStore();
      final state = school(store);
      addTearDown(state.dispose);
      final single = progress('single');
      final multiple = progress('multiple');
      final mixed = progress(null);
      state.queue = [
        {'client_uuid': 'old-history', 'question_id': 'previous'},
      ];
      await state.activatePractice(mixed);
      await state.activatePractice(single);
      await state.activatePractice(multiple);
      await state.activatePractice(progress('single', mode: 'wrong'));
      expect(state.homePractice, multiple);
      expect(state.savedPractice('math', type: 'single'), single);
      expect(state.savedPractice('math', type: 'multiple'), multiple);
      expect(state.savedPractice('math'), mixed);
      final restarted = school(store);
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      expect(restarted.savedPractice('math', type: 'single')!['answers'], {
        '0': ['B'],
      });
      expect(restarted.savedPractice('math', type: 'multiple')!['answers'], {
        '0': ['A', 'C'],
      });
      expect(
        restarted.savedPractice('math')!['session_id'],
        mixed['session_id'],
      );
      expect(restarted.homePractice!['session_id'], multiple['session_id']);
      expect(restarted.queue.single['client_uuid'], 'old-history');
      restarted.practice = null;
      expect(
        restarted.savedPractice('math', mode: 'wrong', type: 'single'),
        isNull,
      );
      expect(restarted.savedPractice('math', type: 'single'), isNotNull);
      expect(restarted.savedPractice('math', type: 'multiple'), isNotNull);
    },
  );

  test(
    'legacy filtered stream migrates without classifying a mixed sample',
    () async {
      final store = TypeScopeStore();
      final state = school(store);
      addTearDown(state.dispose);
      final legacyStream = progress('multiple')..remove('question_type');
      legacyStream['stream'] = {'type': 'multiple', 'subject_id': 'math'};
      final oldMixed = progress(null, tag: 'legacy-mixed')
        ..remove('question_type')
        ..['subject_id'] = 'english';
      (oldMixed['questions'] as List).first['subject_id'] = 'english';
      final review = progress(null, mode: 'favorite');
      store.values['data_${state.cacheKey}'] = {
        'practices': {'all:math': legacyStream, 'all:english': oldMixed},
        'last_ordinary_practice_scope': 'all:math',
        'practice': review,
        'queue': [
          {'client_uuid': 'old-history'},
        ],
      };
      await state.loadLocal();
      expect(state.savedPractice('math'), isNull);
      expect(state.savedPractice('math', type: 'multiple')!['answers'], {
        '0': ['A', 'C'],
      });
      expect(state.savedPractice('english'), isNotNull);
      expect(state.savedPractice('english', type: 'single'), isNull);
      expect(state.homePractice!['session_id'], legacyStream['session_id']);
      await state.persist();
      final restarted = school(store);
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      expect(restarted.homePractice!['session_id'], legacyStream['session_id']);
      expect(restarted.queue.single['client_uuid'], 'old-history');
      expect(
        AppState.practiceType({...legacyStream, 'question_type': null}),
        isNull,
      );
    },
  );

  test(
    'restarting one type keeps the other type and failed saves restore it',
    () async {
      final store = TypeScopeStore();
      final state = school(store);
      addTearDown(state.dispose);
      final multiple = progress('multiple');
      final single = progress('single');
      await state.activatePractice(multiple);
      await state.activatePractice(single);
      await state.activatePractice(progress('single', tag: 'new-round'));
      expect(state.savedPractice('math', type: 'multiple'), same(multiple));
      final before = jsonEncode(store.values);
      store.failNext = true;
      await expectLater(
        state.activatePractice(progress('multiple', tag: 'failed')),
        throwsStateError,
      );
      expect(state.savedPractice('math', type: 'multiple'), same(multiple));
      expect(state.homePractice!['session_id'], 'all-single-new-round');
      expect(store.values, jsonDecode(before));
    },
  );

  test(
    'pending multiple answer failure cannot overwrite a newer single slot',
    () async {
      final store = TypeScopeStore();
      final state = school(store);
      addTearDown(state.dispose);
      final multiple = progress('multiple');
      final single = progress('single');
      await state.activatePractice(multiple);
      state.queue = [
        {'client_uuid': 'old-history', 'question_id': 'old'},
      ];
      final gate = Completer<void>();
      store.nextWrite = gate;
      store.failNext = true;
      final temporary = progress('multiple')..['submitted'] = [0];
      final answer = state.record(
        Map<String, dynamic>.from((multiple['questions'] as List).single),
        ['A', 'C'],
        8,
        practiceState: temporary,
      );
      final assertion = expectLater(answer, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final switchType = state.activatePractice(single);
      gate.complete();
      await assertion;
      await switchType;
      final restarted = school(store);
      addTearDown(restarted.dispose);
      await restarted.loadLocal();
      expect(
        restarted.savedPractice('math', type: 'multiple')!['submitted'],
        isEmpty,
      );
      expect(restarted.savedPractice('math', type: 'multiple')!['answers'], {
        '0': ['A', 'C'],
      });
      expect(restarted.homePractice!['session_id'], single['session_id']);
      expect(restarted.queue.single['client_uuid'], 'old-history');
    },
  );
}
