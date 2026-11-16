import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';
import 'package:zhikaotong/question_content.dart';
import 'package:zhikaotong/teaching.dart';

import 'core_test.dart' show MemoryStore;

const pixel =
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/K1sAAAAASUVORK5CYII=';
final imageHash = sha256.convert(base64Decode(pixel)).toString();
Json richQuestion() => {
  'id': 'source-image-question',
  'subject_id': 'math',
  'version': 9,
  'type': 'single',
  'stem': '题干之前 {{img:$imageHash}} 题干之后',
  'options': [
    {'key': 'A', 'text': '选项之前 {{img:$imageHash}} 选项之后'},
    {'key': 'B', 'text': '另一个选项'},
  ],
  'answer': ['A'],
  'explanation': '解析之前 {{img:$imageHash}} 解析之后',
  'score': 2,
  'awarded_score': 2,
  'selected': ['A'],
  'correct': true,
  'media': {
    imageHash: {'mime': 'image/png', 'data': pixel, 'width': 1, 'height': 1},
  },
};

Widget host(Widget child, {double width = 390}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: width,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

void main() {
  testWidgets(
    'rich content preserves exact text-image-text source order and opens a local zoom viewer',
    (tester) async {
      final question = richQuestion();
      await tester.pumpWidget(
        host(QuestionContent(question: question, text: question['stem'])),
      );
      await tester.pumpAndSettle();
      final content = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      final spans = content.textSpan!.children!;
      expect(spans.length, 3);
      expect((spans[0] as TextSpan).text, '题干之前 ');
      expect(spans[1], isA<WidgetSpan>());
      expect((spans[2] as TextSpan).text, ' 题干之后');
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byType(Image));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
      expect(find.text('原图'), findsOneWidget);
      await tester.tap(find.byTooltip('关闭图片'));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsNothing);
    },
  );

  testWidgets(
    'missing, modified, wrong-mime and dishonest dimensions fail visibly instead of dropping the picture',
    (tester) async {
      final altered = [
        {...richQuestion(), 'media': <String, dynamic>{}},
        {
          ...richQuestion(),
          'media': {
            imageHash: {
              'mime': 'image/png',
              'data': base64Encode([1, 2, 3]),
              'width': 1,
              'height': 1,
            },
          },
        },
        {
          ...richQuestion(),
          'media': {
            imageHash: {
              'mime': 'image/svg+xml',
              'data': pixel,
              'width': 1,
              'height': 1,
            },
          },
        },
        {
          ...richQuestion(),
          'media': {
            imageHash: {
              'mime': 'image/png',
              'data': pixel,
              'width': 20000,
              'height': 1,
            },
          },
        },
        {
          ...richQuestion(),
          'media': {
            imageHash: {
              'mime': 'image/png',
              'data': pixel,
              'width': 2,
              'height': 1,
            },
          },
        },
      ];
      for (final question in altered) {
        await tester.pumpWidget(
          host(QuestionContent(question: question, text: question['stem'])),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('图片缺失或校验失败'), findsOneWidget);
        expect(find.byType(Image), findsNothing);
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'old text-only questions remain selectable and require no media',
    (tester) async {
      await tester.pumpWidget(
        host(const QuestionContent(question: {}, text: '旧版纯文本题干')),
      );
      expect(find.text('旧版纯文本题干'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'teacher previews and submitted student results display original stem options and explanation images',
    (tester) async {
      for (final teacher in [true, false]) {
        await tester.pumpWidget(
          host(questionReview(richQuestion(), 1, teacher: teacher)),
        );
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsNWidgets(3));
        expect(tester.takeException(), isNull);
      }
    },
  );

  test(
    'images and shared original-option diagrams never shuffle, while plain independent options still may',
    () {
      final question = richQuestion();
      expect(canShuffleOptions(question), isFalse);
      expect(
        preparePracticeQuestions(
          [question],
          shuffleOptions: true,
          random: Random(1),
        ).single['options'],
        question['options'],
      );
      expect(
        canShuffleOptions({
          'type': 'single',
          'stem': '见原图选择A-D',
          'options': [
            {'key': 'A', 'text': '见原图A'},
            {'key': 'B', 'text': '见原图B'},
          ],
        }),
        isFalse,
      );
      expect(
        canShuffleOptions({
          'type': 'single',
          'stem': '独立选项',
          'options': [
            {'key': 'A', 'text': '甲'},
            {'key': 'B', 'text': '乙'},
          ],
        }),
        isTrue,
      );
    },
  );

  testWidgets(
    'downloaded self-contained media survives restart, checksum validation and offline practice',
    (tester) async {
      final store = MemoryStore();
      final question = richQuestion();
      final questions = [question];
      final package = {
        'version': 9,
        'subject_id': 'math',
        'questions': questions,
        'checksum': sha256
            .convert(utf8.encode(jsonEncode(canonical(questions))))
            .toString(),
      };
      expect(verifyPackage(package), isTrue);
      final api = Api(
        store,
        client: MockClient((_) async => throw http.ClientException('offline')),
      )..consented = true;
      final state = AppState(store, api)
        ..user = {
          'id': 'source-user',
          'role': 'student',
          'activated': true,
          'must_change_password': false,
          'consent_version': 'v1',
        }
        ..config = {'agreement_version': 'v1'}
        ..offline = {'math': package};
      await state.persist();
      final restarted =
          AppState(
              store,
              Api(
                store,
                client: MockClient(
                  (_) async => throw http.ClientException('offline'),
                ),
              )..consented = true,
            )
            ..user = state.user
            ..config = state.config;
      await restarted.loadLocal();
      final cached = await restarted.questions('math', 'all', 20);
      expect(cached.single['media'], question['media']);
      await tester.pumpWidget(
        host(
          QuestionContent(question: cached.single, text: cached.single['stem']),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
      state.dispose();
      restarted.dispose();
    },
  );

  test(
    'all consented API calls advertise rich question support without changing the fixed endpoint',
    () async {
      final api = Api(
        MemoryStore(),
        client: MockClient((request) async {
          expect(request.headers['X-Question-Content'], 'media-v1');
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'api.example.invalid');
          return http.Response('{}', 200);
        }),
      )..consented = true;
      await api.call('GET', '/bank/manifest');
      api.client.close();
    },
  );

  testWidgets(
    'autonomous practice uses the same rich stem and selectable-option renderer at320px',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore();
      final state =
          AppState(
              store,
              Api(
                store,
                client: MockClient((_) async => http.Response('{}', 200)),
              )..consented = true,
            )
            ..user = {
              'id': 'source-user',
              'role': 'student',
              'activated': true,
              'must_change_password': false,
              'consent_version': 'v1',
            }
            ..config = {'agreement_version': 'v1'};
      await tester.pumpWidget(
        MaterialApp(
          home: PracticePage(state: state, questions: [richQuestion()]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(QuestionContent), findsAtLeastNWidgets(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );

  testWidgets(
    'class assignment before submission renders only visible rich fields without disclosing answers',
    (tester) async {
      tester.view.physicalSize = const Size(320, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = MemoryStore();
      final visible = richQuestion()
        ..remove('answer')
        ..remove('explanation');
      final api = Api(
        store,
        client: MockClient(
          (request) async => http.Response(
            jsonEncode({
              'id': 'rich-task',
              'paper_title': '原题图片班级练习',
              'class_name': '测试班',
              'questions': [visible],
              'result': null,
            }),
            200,
            headers: {'content-type': 'application/json'},
          ),
        ),
      )..consented = true;
      final state = AppState(store, api)
        ..user = {'id': 'source-user', 'role': 'student', 'activated': true};
      await tester.pumpWidget(
        MaterialApp(
          home: AssignmentAttemptPage(state: state, assignmentId: 'rich-task'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.textContaining('参考答案'), findsNothing);
      expect(find.textContaining('解析之前'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      state.dispose();
    },
  );
}
