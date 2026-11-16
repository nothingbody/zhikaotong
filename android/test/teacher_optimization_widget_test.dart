import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/ios_theme.dart';
import 'package:zhikaotong/teaching.dart';

import 'teaching_test.dart' as fixture;
import 'ui_render_test.dart' as preview;

http.Response response(dynamic value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

AppState stateFor(
  fixture.TeachingMemoryStore store,
  Future<http.Response> Function(http.Request) handler, {
  bool teacher = true,
}) => AppState(store, Api(store, client: MockClient(handler))..consented = true)
  ..ready = true
  ..user = {
    'id': teacher ? 'teacher-test' : 'student-test',
    'role': teacher ? 'teacher' : 'student',
    'name': '测试账号',
    'activated': true,
  };

Future<void> clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  state.dispose();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> tap(WidgetTester tester, String text) async {
  final target = find.text(text).last;
  await tester.ensureVisible(target);
  await tester.tap(target);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(preview.loadPreviewFonts);

  testWidgets(
    'preview returns to unchanged rules and generates a separate paper',
    (tester) async {
      final store = fixture.TeachingMemoryStore();
      final posted = <Json>[];
      final papers = <Json>[];
      final state = stateFor(store, (request) async {
        if (request.url.path.endsWith('/catalog'))
          return response(fixture.teachingCatalog());
        if (request.url.path.endsWith('/assignments')) return response([]);
        if (request.method == 'POST') {
          final payload = Map<String, dynamic>.from(jsonDecode(request.body));
          posted.add(payload);
          final paper = {
            ...payload,
            'id': 'paper-${posted.length}',
            'question_count': 2,
            'full_score': 6,
            'questions': [
              fixture.sampleChoice(),
              {...fixture.sampleChoice(), 'id': 'choice-2'},
            ],
          };
          papers.add(paper);
          return response(paper);
        }
        return response(papers);
      });
      await preview.mountPage(
        tester,
        TeacherShell(state: state, onPassword: (_) {}, onLegal: (_) {}),
      );
      await tap(tester, '创建班级练习卷');
      await tester.enterText(
        find.widgetWithText(TextField, '练习卷名称'),
        '计算机班共享数学练习',
      );
      await tester.enterText(find.widgetWithText(TextField, '每题分值'), '3');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tap(tester, '生成并预览练习卷');
      expect(find.byType(TeacherPaperPage), findsOneWidget);
      await tap(tester, '修改规则');
      expect(find.byType(PaperBuilderPage), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '练习卷名称'))
            .controller!
            .text,
        '计算机班共享数学练习',
      );
      expect(
        tester
            .widget<TextField>(find.widgetWithText(TextField, '每题分值'))
            .controller!
            .text,
        '3',
      );
      await preview.capture(tester, 'teacher-builder-return-0.8.0');
      await tap(tester, '生成并预览练习卷');
      expect(posted, hasLength(2));
      expect(posted[1], posted[0]);
      expect(papers.map((p) => p['id']).toSet(), hasLength(2));
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets('teacher history requests server pages and scoped class filter', (
    tester,
  ) async {
    final requests = <Uri>[];
    final state = stateFor(fixture.TeachingMemoryStore(), (request) async {
      requests.add(request.url);
      final offset = int.parse(request.url.queryParameters['offset'] ?? '0');
      return response(
        List.generate(
          offset == 0 && !request.url.queryParameters.containsKey('class_id')
              ? 20
              : 1,
          (i) => {
            'id': 'task-${offset + i}',
            'paper_title': '基础巩固${offset + i}',
            'class_name': '一班',
            'submitted_count': 0,
            'recipient_count': 2,
          },
        ),
      );
    });
    await preview.mountPage(
      tester,
      TeachingHistoryPage(
        state: state,
        catalog: fixture.teachingCatalog(),
        tasks: true,
      ),
    );
    expect(requests.single.queryParameters['limit'], '20');
    await tester.scrollUntilVisible(
      find.text('加载更多'),
      280,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tap(tester, '加载更多');
    expect(requests.last.queryParameters['offset'], '20');
    await tester.scrollUntilVisible(
      find.text('班级筛选'),
      -500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tap(tester, '机械升学一班');
    expect(requests.last.queryParameters['class_id'], 'class-1');
    expect(requests.last.queryParameters['offset'], '0');
    expect(tester.takeException(), isNull);
    await preview.capture(tester, 'teacher-history-0.8.0');
    await clean(tester, state);
  });

  testWidgets(
    'explicit supplementation confirms and reports only new recipients',
    (tester) async {
      var supplements = 0;
      final state = stateFor(fixture.TeachingMemoryStore(), (request) async {
        if (request.method == 'POST') {
          supplements++;
          return response({'added': 1, 'unchanged': 1, 'eligible': 2});
        }
        return response({
          'assignment': {
            'id': 'task-1',
            'paper_id': 'paper-1',
            'recipient_count': 1 + supplements,
            'submitted_count': 1,
          },
          'results': [
            {
              'name': '原成员',
              'username': 'old',
              'submitted': true,
              'score': 1,
              'full_score': 1,
              'correct': 1,
              'total': 1,
              'submitted_at': '2026-11-03T00:00:00Z',
            },
          ],
        });
      });
      await preview.mountPage(
        tester,
        TeachingResultsPage(
          state: state,
          assignment: const {
            'id': 'task-1',
            'paper_title': '数学巩固',
            'class_name': '一班',
          },
        ),
      );
      await tap(tester, '补发给新成员');
      expect(supplements, 0);
      await tap(tester, '确认补发');
      expect(supplements, 1);
      expect(find.text('已补发给1名新成员。'), findsOneWidget);
      expect(find.text('原成员 · old'), findsOneWidget);
      expect(find.text('2 / 2 人'), findsNothing);
      expect(find.text('1 / 2 人'), findsOneWidget);
      await preview.capture(tester, 'teacher-supplement-0.8.0');
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets(
    'task-only wrong review does not post or change original grade or practice',
    (tester) async {
      final requests = <String>[];
      final store = fixture.TeachingMemoryStore();
      final wrong = {
        ...fixture.sampleChoice(),
        'correct': false,
        'selected': ['B'],
        'awarded_score': 0,
      };
      final correct = {
        ...fixture.sampleChoice(),
        'id': 'correct-2',
        'stem': '已掌握的另一题',
        'correct': true,
        'selected': ['A'],
        'awarded_score': 1,
      };
      final grade = {
        'score': 1,
        'full_score': 2,
        'correct': 1,
        'total': 2,
        'questions': [wrong, correct],
        'submitted_at': '2026-11-03T00:00:00Z',
      };
      final state = stateFor(store, (request) async {
        requests.add('${request.method} ${request.url.path}');
        return response({
          'id': 'task-1',
          'paper_title': '本班练习',
          'class_name': '一班',
          'result': grade,
          'questions': [],
        });
      }, teacher: false)..practice = {'questions': [], 'cursor': 9};
      state.queue.add({'client_uuid': 'already-saved'});
      final original = jsonEncode(grade),
          practice = jsonEncode(state.practice),
          queue = jsonEncode(state.queue);
      await preview.mountPage(
        tester,
        AssignmentAttemptPage(state: state, assignmentId: 'task-1'),
      );
      await tap(tester, '只看错题（1题）');
      expect(find.textContaining('已掌握的另一题'), findsNothing);
      await tap(tester, '复习本卷错题');
      expect(find.byType(AssignmentWrongReviewPage), findsOneWidget);
      await tap(tester, '2');
      await tap(tester, '检查答案');
      expect(find.text('本次复习答对了'), findsOneWidget);
      expect(requests, ['GET /api/student/assignments/task-1']);
      expect(jsonEncode(grade), original);
      expect(jsonEncode(state.practice), practice);
      expect(jsonEncode(state.queue), queue);
      await preview.capture(tester, 'assignment-wrong-review-0.8.0');
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets(
    'unavailable tasks are historical and current local draft progress is visible',
    (tester) async {
      final store = fixture.TeachingMemoryStore();
      final state = stateFor(
        store,
        (request) async => response([
          {
            'id': 'active-task',
            'paper_title': '当前任务',
            'class_name': '一班',
            'question_count': 3,
            'submitted': false,
            'available': true,
          },
          {
            'id': 'old-task',
            'paper_title': '不可继续旧任务',
            'class_name': '一班',
            'question_count': 3,
            'submitted': false,
            'available': false,
          },
        ]),
        teacher: false,
      );
      store.values['assignment_${state.cacheKey}_active-task'] = {
        'answers': {
          'q1': ['A'],
        },
        'pending': null,
      };
      await preview.mountPage(tester, StudentAssignmentsPage(state: state));
      final label = find.ancestor(
        of: find.text('待完成'),
        matching: find.byType(IOSSectionLabel),
      );
      expect(
        find.descendant(of: label, matching: find.text('1项')),
        findsOneWidget,
      );
      expect(find.text('已填写1题 · 继续练习'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('不可继续的历史任务'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('不可继续的历史任务'), findsOneWidget);
      final old = find.ancestor(
        of: find.text('不可继续旧任务'),
        matching: find.byType(ListTile),
      );
      expect(tester.widget<ListTile>(old).onTap, isNull);
      await preview.capture(tester, 'assignment-history-0.8.0');
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );

  testWidgets(
    'task question aggregates can open teacher owned original question',
    (tester) async {
      final paths = <String>[];
      final state = stateFor(fixture.TeachingMemoryStore(), (request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/question-analysis'))
          return response({
            'submitted_count': 2,
            'questions': [
              {
                'id': 'choice-1',
                'index': 1,
                'type': 'single',
                'stem': '偶数判断',
                'answered': 2,
                'wrong': 1,
                'error_rate': 50.0,
              },
            ],
          });
        return response({
          'questions': [fixture.sampleChoice()],
        });
      });
      await preview.mountPage(
        tester,
        TaskQuestionAnalysisPage(
          state: state,
          assignment: const {
            'id': 'task-1',
            'paper_id': 'paper-1',
            'paper_title': '课堂巩固',
          },
        ),
      );
      expect(find.text('错误率 50.0%'), findsOneWidget);
      expect(find.text('答错 1 / 2 人'), findsOneWidget);
      await preview.capture(tester, 'teacher-task-question-analysis-0.8.0');
      await tap(tester, '查看原题与解析');
      expect(paths.last, '/api/teaching/papers/paper-1');
      expect(find.textContaining('参考答案：A'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );
}
