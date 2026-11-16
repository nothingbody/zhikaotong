// Test-only data and storage for rendered UI verification; never used by the app.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';

class UiPreviewStore extends LocalStore {
  final values = <String, dynamic>{};
  @override
  Future<dynamic> read(String key) async => values[key];
  @override
  Future<void> write(String key, dynamic value) async {
    values[key] = jsonDecode(jsonEncode(value));
  }

  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<String?> secureRead(String key) async => values[key] as String?;
  @override
  Future<void> secureWrite(String key, String? value) async {
    values[key] = value;
  }
}

Json previewQuestion({String type = 'single'}) => {
  'id': 'ui-preview-question',
  'version': 3,
  'subject_id': 'math',
  'knowledge_id': 'math-set',
  'type': type,
  'stem': type == 'fill'
      ? '请按顺序填写：集合中共同的元素组成____，所有元素组成____。'
      : '已知集合 A = {1, 2, 3}，B = {2, 3, 4}，则 A ∩ B 等于（ ）。',
  'options': type == 'fill'
      ? <dynamic>[]
      : [
          {'key': 'A', 'text': '{1, 4}'},
          {'key': 'B', 'text': '{2, 3}'},
          {'key': 'C', 'text': '{1, 2, 3, 4}'},
          {'key': 'D', 'text': '{3}'},
        ],
  'answer': type == 'fill'
      ? [
          ['交集'],
          ['并集'],
        ]
      : ['B'],
  'explanation': '交集由同时属于两个集合的元素组成，因此 A ∩ B = {2, 3}。',
  'difficulty': 2,
  'source': '界面验收演示题',
};

class UiPreviewState extends AppState {
  UiPreviewState({List<String>? requestPaths})
    : this._(UiPreviewStore(), requestPaths);
  UiPreviewState._(UiPreviewStore storage, List<String>? requestPaths)
    : super(
        storage,
        Api(
          storage,
          client: MockClient((request) async {
            final path = request.url.path;
            requestPaths?.add(path);
            dynamic body = <dynamic>[];
            if (path.endsWith('/bank/version')) {
              body = {
                'version': 3,
                'subjects': [
                  {'id': 'math', 'name': '数学', 'count': 36},
                  {'id': 'mechanics', 'name': '机械专业综合理论', 'count': 84},
                ],
              };
            } else if (path.endsWith('/student/deletion')) {
              body = {'status': 'none', 'execute_at': null};
            } else if (path.endsWith('/knowledge')) {
              body = [
                {
                  'id': 'math-set',
                  'name': '集合的概念',
                  'parent_id': null,
                  'subject_id': 'math',
                },
                {
                  'id': 'math-operations',
                  'name': '集合的运算',
                  'parent_id': 'math-set',
                  'subject_id': 'math',
                },
              ];
            } else if (path.endsWith('/questions') ||
                path.endsWith('/student/wrong')) {
              body = [previewQuestion()];
            }
            return http.Response(
              jsonEncode(body),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
      ) {
    ready = true;
    api.consented = true;
    user = {
      'id': 'ui-preview-student',
      'username': 'preview_student',
      'name': '演示同学',
      'role': 'student',
      'activated': true,
      'must_change_password': false,
      'consent_version': 'draft-1',
      'subject_group_id': 'mechanics-group',
      'exam_year': 2027,
    };
    config = {
      'agreement_version': 'draft-1',
      'exam_start': '2027-04-17',
      'exam_end': '2027-04-18',
      'teacher_visibility': '教师可查看班内姓名、任务成绩与必要学习汇总。',
      'contact': '演示学校教务处',
    };
    dashboard = {
      'stats': {
        'answered': 268,
        'correct': 231,
        'accuracy': 86.2,
        'study_seconds': 16200,
        'streak': 7,
        'today_answered': 18,
        'today_goal': 30,
      },
      'exam_start': '2027-04-17',
      'announcements': [
        {'title': '本周学习安排', 'content': '按科目稳步练习，及时回看错题。此内容仅为界面测试样例。'},
      ],
    };
    subjects = [
      {
        'id': 'chinese',
        'name': '语文',
        'answered': 52,
        'accuracy': 88.5,
        'total': 120,
      },
      {
        'id': 'math',
        'name': '数学',
        'answered': 68,
        'accuracy': 85.3,
        'total': 36,
      },
      {
        'id': 'english',
        'name': '英语',
        'answered': 71,
        'accuracy': 87.3,
        'total': 313,
      },
      {
        'id': 'mechanics',
        'name': '机械专业综合理论',
        'answered': 77,
        'accuracy': 83.1,
        'total': 716,
      },
    ];
    classes = [
      {
        'id': 'preview-class',
        'name': '2027 机械专业升学一班',
        'teacher_name': '演示教师',
        'status': 'active',
        'visibility': config['teacher_visibility'],
      },
    ];
    favorites = {'favorite-1', 'favorite-2', 'favorite-3'};
    doubts = {'doubt-1'};
  }
  @override
  Future<void> reload() async {}
  @override
  Future<void> sync() async {}
  @override
  void scheduleSync() {}
}
