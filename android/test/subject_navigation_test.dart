import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

void expectSubjectOnlyNavigation() {
  for (final removedLabel in ['知识点', '待归类', '下载题库', '离线题库']) {
    expect(find.textContaining(removedLabel), findsNothing);
  }
}

void main() {
  setUpAll(preview.loadPreviewFonts);

  testWidgets(
    'student subject navigation has no legacy knowledge or download entry and preserves local data',
    (tester) async {
      final paths = <String>[];
      final state = UiPreviewState(requestPaths: paths);
      state.offline['math'] = {
        'version': 3,
        'subject_id': 'math',
        'questions': [previewQuestion()],
      };
      state.queue.add({
        'client_uuid': 'saved-before-ui-upgrade',
        'question_id': 'old-question',
        'question_version': 1,
        'selected': ['A'],
      });
      final previousCache = jsonEncode(state.offline);
      final previousQueue = jsonEncode(state.queue);
      await preview.mountPage(
        tester,
        HomeShell(state: state),
        width: 320,
        height: 844,
      );
      expectSubjectOnlyNavigation();
      await tester.scrollUntilVisible(
        find.text('数学'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(LearningPage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.tap(find.text('数学'));
      await tester.pumpAndSettle();
      // Subject tiles now open settings directly, removing the empty intermediary.
      expect(find.byType(SubjectPage), findsNothing);
      expect(find.text('题目乱序'), findsOneWidget);
      expect(find.text('选项乱序'), findsOneWidget);
      expectSubjectOnlyNavigation();
      Navigator.of(tester.element(find.text('进入练习'))).pop();
      await tester.pumpAndSettle();
      await tester.tap(find.text('我的').last);
      await tester.pumpAndSettle();
      expect(find.text('做题记录同步'), findsOneWidget);
      expectSubjectOnlyNavigation();
      expect(paths.where((path) => path.contains('/knowledge')), isEmpty);
      expect(paths.where((path) => path.contains('/bank/package')), isEmpty);
      expect(jsonEncode(state.offline), previousCache);
      expect(jsonEncode(state.queue), previousQueue);
      expect(tester.takeException(), isNull);
      await preview.disposePage(tester, state);
    },
  );

  testWidgets(
    'subject practice still loads online with independent question and option randomization',
    (tester) async {
      final store = UiPreviewStore();
      final requests = <Uri>[];
      final state = AppState(
        store,
        Api(
          store,
          client: MockClient((request) async {
            requests.add(request.url);
            return http.Response(
              jsonEncode([previewQuestion()]),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        )..consented = true,
      )..user = {'id': 'student-1', 'role': 'student', 'activated': true};
      await preview.mountPage(
        tester,
        SubjectPage(state: state, subject: {'id': 'math', 'name': '数学'}),
      );
      await tester.tap(find.text('开始本科目练习'));
      await tester.pumpAndSettle();
      expect(find.text('持续刷题'), findsOneWidget);
      expect(find.text('5题'), findsNothing);
      await tester.tap(find.text('持续刷题'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('题目乱序'));
      await tester.tap(find.text('选项乱序'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('进入练习'));
      await tester.tap(find.text('进入练习'));
      await tester.pumpAndSettle();
      expect(find.byType(PracticePage), findsOneWidget);
      expect(requests.single.path, '/api/questions');
      expect(requests.single.queryParameters, {
        'subject_id': 'math',
        'mode': 'all',
        'limit': '10',
        'shuffle': 'true',
        'type': 'single',
      });
      final practice = tester.widget<PracticePage>(find.byType(PracticePage));
      expect(practice.questions.single['options_shuffled'], isTrue);
      expectSubjectOnlyNavigation();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      state.dispose();
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    },
  );
}
