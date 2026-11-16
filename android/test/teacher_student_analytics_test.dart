import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/ios_theme.dart';
import 'package:zhikaotong/teaching.dart';
import 'package:zhikaotong/teacher_student_analytics.dart';
import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

const schoolClass = {'id': 'c1', 'name': '机械专业升学一班'};
http.Response response(dynamic body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);
AppState stateFor(
  Future<http.Response> Function(http.Request) handler, {
  String role = 'teacher',
}) {
  final store = UiPreviewStore();
  return AppState(
      store,
      Api(store, client: MockClient(handler))..consented = true,
    )
    ..ready = true
    ..user = {'id': 't1', 'role': role, 'name': '王老师'};
}

Json aggregate({
  String student = 's1',
  String classId = 'c1',
  int days = 30,
  String subject = '',
  bool empty = false,
}) {
  final answered = empty
      ? 0
      : subject == 'math'
      ? 6
      : days == 7
      ? 3
      : days == 90
      ? 90
      : 10;
  final correct = empty
      ? 0
      : subject == 'math'
      ? 4
      : days == 7
      ? 2
      : days == 90
      ? 60
      : 6;
  final metrics = {
    'answered': answered,
    'correct': correct,
    'wrong': answered - correct,
    'unique_questions': answered,
    'accuracy': answered == 0 ? null : correct * 100 / answered,
    'study_seconds': answered * 60,
    'active_days': empty ? 0 : 2,
  };
  return {
    'class': {'id': classId, 'name': '机械专业升学一班'},
    'student': {
      'id': student,
      'name': student == 's1' ? '甲同学' : '乙同学',
      'username': student == 's1' ? 'alpha' : 'beta',
      'status': 'active',
    },
    'scope': {
      'class_id': classId,
      'subject_ids': ['math', 'mechanics'],
      'practice': 'current_class_subjects',
    },
    'period': {
      'days': days,
      'start': '2026-10-05',
      'end': '2026-11-03',
      'timezone': 'Asia/Shanghai',
    },
    'filters': {'subject_id': subject.isEmpty ? null : subject},
    'available_subjects': [
      {'id': 'math', 'name': '数学'},
      {'id': 'mechanics', 'name': '机械专业综合理论'},
    ],
    'lifetime': {
      ...metrics,
      'answered': empty ? 0 : 50,
      'correct': empty ? 0 : 38,
      'wrong': empty ? 0 : 12,
      'accuracy': empty ? null : 76,
      'study_seconds': empty ? 0 : 3600,
    },
    'summary': metrics,
    'subjects': empty
        ? []
        : [
            {
              'subject_id': subject.isEmpty ? 'math' : subject,
              'name': '数学',
              ...metrics,
            },
          ],
    'types': empty
        ? []
        : [
            {'type': 'single', ...metrics},
          ],
    'daily': List.generate(
      days,
      (index) => {
        'date': DateTime.utc(2026, 11, 3)
            .subtract(Duration(days: days - index - 1))
            .toIso8601String()
            .substring(0, 10),
        'answered': index == days - 1 ? answered : 0,
        'correct': index == days - 1 ? correct : 0,
        'wrong': index == days - 1 ? answered - correct : 0,
        'accuracy': index == days - 1 ? metrics['accuracy'] : null,
        'study_seconds': 0,
      },
    ),
    'classwork': {
      'scope': 'lifetime_current_class_all_subjects',
      'assigned': empty ? 0 : 4,
      'submitted': empty ? 0 : 2,
      'pending': empty ? 0 : 2,
      'results': empty
          ? []
          : [
              {
                'assignment_id': 'a1',
                'title': '机械基础班级练习',
                'score': 8,
                'full_score': 10,
                'correct': 4,
                'total': 5,
                'submitted_at': '2026-11-02T07:00:00Z',
              },
            ],
    },
  };
}

Future<void> mount(
  WidgetTester tester,
  Widget page, {
  double width = 390,
  double scale = 1,
}) async {
  await preview.mountPage(
    tester,
    page,
    width: width,
    height: 844,
    scale: scale,
    push: true,
  );
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> clean(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
  state.dispose();
}

String metric(WidgetTester tester, String name) =>
    tester.widget<Text>(find.byKey(ValueKey(name))).data!;
void main() {
  setUpAll(preview.loadPreviewFonts);
  test(
    'aggregate formatting keeps absent accuracy separate from real zero and counts repeated errors',
    () {
      expect(teacherAccuracy({'answered': 0, 'accuracy': 0}), '—');
      expect(teacherAccuracy({'answered': 1, 'accuracy': 0}), '0.0%');
      expect(teacherErrorRate({'answered': 0, 'wrong': 0}), '—');
      expect(teacherErrorRate({'answered': 4, 'wrong': 3}), '75.0%');
      expect(teacherStudyTime(3600), '1小时');
    },
  );
  testWidgets(
    'formal roster excludes left rejected and pending; returning rechecks membership',
    (tester) async {
      var active = true;
      final paths = <String>[];
      final state = stateFor((request) async {
        paths.add(request.url.path);
        if (request.url.path.endsWith('/analytics'))
          return response(aggregate());
        return response({
          'class': schoolClass,
          'students': [
            if (active)
              {
                'id': 's1',
                'name': '甲同学',
                'username': 'alpha',
                'status': 'active',
              },
            {
              'id': 'left',
              'name': '已离班学生',
              'username': 'left',
              'status': 'left',
            },
            {
              'id': 'rejected',
              'name': '被拒绝学生',
              'username': 'rejected',
              'status': 'rejected',
            },
            {
              'id': 'pending',
              'name': '待确认学生',
              'username': 'pending',
              'status': 'pending_confirmation',
            },
          ],
        });
      });
      await mount(
        tester,
        TeacherClassStudentsPage(state: state, schoolClass: schoolClass),
      );
      expect(find.text('甲同学'), findsOneWidget);
      for (final name in ['已离班学生', '被拒绝学生', '待确认学生']) {
        expect(find.text(name), findsNothing);
      }
      await tester.tap(find.text('甲同学'));
      await tester.pumpAndSettle();
      expect(metric(tester, 'teacher-period-answered'), '10');
      active = false;
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('甲同学'), findsNothing);
      expect(find.textContaining('暂无正式在班学生'), findsOneWidget);
      expect(paths.where((path) => path.endsWith('/students')).length, 2);
      expect(
        paths.every((path) => path.startsWith('/api/teaching/classes/')),
        true,
      );
      await clean(tester, state);
    },
  );
  testWidgets(
    'period and allowed-subject filters scope aggregate errors and classwork stays independent',
    (tester) async {
      final urls = <Uri>[];
      final state = stateFor((request) async {
        urls.add(request.url);
        return response(
          aggregate(
            days: int.parse(request.url.queryParameters['days']!),
            subject: request.url.queryParameters['subject_id'] ?? '',
          ),
        );
      });
      await mount(
        tester,
        TeacherStudentAnalyticsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(metric(tester, 'teacher-period-answered'), '10');
      expect(metric(tester, 'teacher-period-accuracy'), '60.0%');
      await tester.tap(find.text('近7天'));
      await tester.pumpAndSettle();
      expect(metric(tester, 'teacher-period-answered'), '3');
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('数学').last);
      await tester.pumpAndSettle();
      expect(metric(tester, 'teacher-period-answered'), '6');
      expect(urls.last.queryParameters, {'days': '7', 'subject_id': 'math'});
      await tester.scrollUntilVisible(find.text('错误分布'), 350);
      await tester.pumpAndSettle();
      expect(find.text('错误作答 2次 / 答题 6次'), findsWidgets);
      expect(find.text('错误率 33.3%'), findsWidgets);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('teacher-classwork-pending')),
        400,
      );
      await tester.pumpAndSettle();
      expect(find.text('未提交 2'), findsOneWidget);
      expect(find.textContaining('本班累计、全部科目'), findsOneWidget);
      expect(
        urls.every(
          (url) =>
              !url.path.contains('/management/') &&
              !url.path.contains('/questions'),
        ),
        true,
      );
      expect(tester.takeException(), isNull);
      await clean(tester, state);
    },
  );
  testWidgets(
    'late periods and different class student responses cannot overwrite newer views',
    (tester) async {
      final pending = Completer<http.Response>();
      final state = stateFor((request) async {
        final days = int.parse(request.url.queryParameters['days']!);
        if (days == 90) return pending.future;
        return response(aggregate(days: days));
      });
      await mount(
        tester,
        TeacherStudentAnalyticsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      await tester.tap(find.text('近90天'));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('teacher-period-answered')),
        findsNothing,
      );
      await tester.tap(find.text('近7天'));
      await tester.pumpAndSettle();
      expect(metric(tester, 'teacher-period-answered'), '3');
      pending.complete(response(aggregate(days: 90)));
      await tester.pumpAndSettle();
      expect(metric(tester, 'teacher-period-answered'), '3');
      await clean(tester, state);
      final first = Completer<http.Response>(), selection = ValueNotifier('s1');
      final nextState = stateFor(
        (request) async => request.url.path.contains('/s1/')
            ? first.future
            : response(aggregate(student: 's2', classId: 'c2')),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: preview.previewTheme(),
          home: ValueListenableBuilder<String>(
            valueListenable: selection,
            builder: (_, id, child) => TeacherStudentAnalyticsPage(
              state: nextState,
              schoolClass: id == 's1'
                  ? schoolClass
                  : const {'id': 'c2', 'name': '第二班'},
              studentId: id,
            ),
          ),
        ),
      );
      await tester.pump();
      selection.value = 's2';
      await tester.pumpAndSettle();
      expect(find.text('乙同学'), findsOneWidget);
      first.complete(response(aggregate()));
      await tester.pumpAndSettle();
      expect(find.text('甲同学'), findsNothing);
      expect(find.text('乙同学'), findsOneWidget);
      selection.dispose();
      await clean(tester, nextState);
    },
  );
  testWidgets(
    'revoked access refresh clears identity metrics and subject metadata; retry can recover',
    (tester) async {
      var deny = false;
      final urls = <Uri>[];
      final state = stateFor((request) async {
        urls.add(request.url);
        return deny
            ? response({'detail': '学生已离班'}, 404)
            : response(
                aggregate(
                  subject: request.url.queryParameters['subject_id'] ?? '',
                ),
              );
      });
      await mount(
        tester,
        TeacherStudentAnalyticsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(find.text('甲同学'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('数学').last);
      await tester.pumpAndSettle();
      expect(urls.last.queryParameters['subject_id'], 'math');
      deny = true;
      await tester.tap(find.byTooltip('刷新学生学习分析'));
      await tester.pump();
      expect(find.text('甲同学'), findsNothing);
      expect(
        find.byKey(const ValueKey('teacher-period-answered')),
        findsNothing,
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('当前无权查看此班学生或科目'), findsOneWidget);
      expect(find.text('机械专业综合理论'), findsNothing);
      deny = false;
      await tester.tap(find.text('重新验证并加载'));
      await tester.pumpAndSettle();
      expect(find.text('甲同学'), findsOneWidget);
      expect(urls.last.queryParameters.containsKey('subject_id'), false);
      await clean(tester, state);
    },
  );
  testWidgets(
    'background hides aggregate and foreground revalidates current membership',
    (tester) async {
      var deny = false, calls = 0;
      final state = stateFor((_) async {
        calls++;
        return deny
            ? response({'detail': '班级已归档'}, 403)
            : response(aggregate());
      });
      await mount(
        tester,
        TeacherStudentAnalyticsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.text('甲同学'), findsNothing);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      expect(find.text('甲同学'), findsNothing);
      deny = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('当前无权查看此班学生或科目'), findsOneWidget);
      await clean(tester, state);
    },
  );
  testWidgets(
    'empty activity shows dash accuracy; nonteacher never requests the endpoint',
    (tester) async {
      final state = stateFor((_) async => response(aggregate(empty: true)));
      await mount(
        tester,
        TeacherStudentAnalyticsPage(
          state: state,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(metric(tester, 'teacher-period-accuracy'), '—');
      expect(metric(tester, 'teacher-period-answered'), '0');
      await tester.scrollUntilVisible(find.textContaining('本期间暂无已同步自主练习'), 400);
      await tester.pumpAndSettle();
      expect(find.textContaining('正确率 0.0%'), findsNothing);
      await clean(tester, state);
      var calls = 0;
      final unauthorized = stateFor((_) async {
        calls++;
        return response({});
      }, role: 'student');
      await mount(
        tester,
        TeacherStudentAnalyticsPage(
          state: unauthorized,
          schoolClass: schoolClass,
          studentId: 's1',
        ),
      );
      expect(find.text('仅教师可查看在班学生学习情况。'), findsOneWidget);
      expect(calls, 0);
      await clean(tester, unauthorized);
    },
  );
  testWidgets(
    'member approval removal and result refresh never retain left students',
    (tester) async {
      var pending = true, active = true, denyResults = false;
      final methods = <String>[];
      final state = stateFor((request) async {
        methods.add('${request.method} ${request.url.path}');
        if (request.url.path.contains('/results'))
          return denyResults
              ? response({'detail': '班级不可访问'}, 403)
              : response({
                  'assignment': {'submitted_count': 1, 'recipient_count': 1},
                  'results': [
                    {
                      'name': '甲同学',
                      'username': 'alpha',
                      'status': 'active',
                      'submitted': true,
                      'correct': 1,
                      'total': 2,
                      'score': 1,
                      'full_score': 2,
                      'submitted_at': '2026-11-03',
                    },
                    {
                      'name': '离班成绩',
                      'username': 'left',
                      'status': 'left',
                      'submitted': false,
                    },
                  ],
                });
        if (request.method == 'PATCH') {
          final body = jsonDecode(request.body);
          if (body['status'] == 'active') {
            pending = false;
          } else if (body['status'] == 'left') {
            active = false;
          }
          return response({'ok': true});
        }
        return response([
          if (active)
            {
              'id': 's1',
              'membership_id': 'm1',
              'name': '甲同学',
              'username': 'alpha',
              'status': 'active',
            },
          {
            'id': 's2',
            'membership_id': 'm2',
            'name': '乙同学',
            'username': 'beta',
            'status': pending ? 'pending_approval' : 'active',
          },
          {'id': 'left', 'name': '已离班学生', 'username': 'left', 'status': 'left'},
          {
            'id': 'rejected',
            'name': '被拒绝学生',
            'username': 'rejected',
            'status': 'rejected',
          },
        ]);
      });
      await mount(
        tester,
        TeacherMembersPage(state: state, schoolClass: schoolClass),
      );
      expect(find.textContaining('已离班学生'), findsNothing);
      expect(find.textContaining('被拒绝学生'), findsNothing);
      await tester.tap(find.text('同意入班'));
      await tester.pumpAndSettle();
      expect(find.text('正常成员'), findsNWidgets(2));
      final card = find.ancestor(
        of: find.text('甲同学 · alpha'),
        matching: find.byType(IOSGroupedSurface),
      );
      await tester.tap(find.descendant(of: card, matching: find.text('移出班级')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认移出'));
      await tester.pumpAndSettle();
      expect(find.text('甲同学 · alpha'), findsNothing);
      expect(methods.where((method) => method.startsWith('PATCH')).length, 2);
      expect(methods.where((method) => method.endsWith('/members')).length, 3);
      await tester.pumpWidget(
        MaterialApp(
          theme: preview.previewTheme(),
          home: TeachingResultsPage(
            state: state,
            assignment: const {
              'id': 'a1',
              'paper_title': '数学周练',
              'class_name': '机械一班',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('离班成绩 · left'), findsNothing);
      expect(find.text('甲同学 · alpha'), findsOneWidget);
      denyResults = true;
      await tester.tap(find.byTooltip('刷新成绩'));
      await tester.pumpAndSettle();
      expect(find.text('甲同学 · alpha'), findsNothing);
      expect(find.text('班级不可访问'), findsOneWidget);
      await clean(tester, state);
    },
  );
  for (final width in [390.0, 320.0]) {
    testWidgets(
      'teacher learning analysis ${width.toInt()}px with130percent text',
      (tester) async {
        final state = stateFor((_) async => response(aggregate()));
        await mount(
          tester,
          TeacherStudentAnalyticsPage(
            state: state,
            schoolClass: schoolClass,
            studentId: 's1',
          ),
          width: width,
          scale: 1.3,
        );
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-student-analysis-${width.toInt()}-top',
        );
        await tester.scrollUntilVisible(find.text('错误分布'), 350);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-student-analysis-${width.toInt()}-errors',
        );
        await tester.scrollUntilVisible(find.text('本班任务成绩'), 400);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await preview.capture(
          tester,
          'teacher-student-analysis-${width.toInt()}-classwork',
        );
        await clean(tester, state);
      },
    );
  }
}
