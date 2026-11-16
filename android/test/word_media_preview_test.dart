// Optional QA against the user's unmodified Word-derived preview, not shipped data.
// Run with WORD_PREVIEW_JSON and CAPTURE_UI=true to inspect original image layout.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/main.dart';

import 'ui_preview_support.dart';
import 'ui_render_test.dart' as preview;

void main() {
  final source = Platform.environment['WORD_PREVIEW_JSON'];
  if (source == null || !File(source).existsSync()) {
    test(
      'original Word media layout QA requires explicit local source',
      () {},
      skip: true,
    );
    return;
  }
  final parsed = jsonDecode(File(source).readAsStringSync()) as Map;
  final questions = (parsed['questions'] as List).cast<Map>();
  setUpAll(preview.loadPreviewFonts);
  for (final width in [390.0, 320.0]) {
    for (final sourceIndex in [1315, 1427, 1046, 2823]) {
      testWidgets(
        'original Word media source$sourceIndex at${width.toInt()}px',
        (tester) async {
          final original = questions.firstWhere(
            (item) => item['source_index'] == sourceIndex,
          );
          final question = Map<String, dynamic>.from(original)
            ..['id'] = original['source_key']
            ..['version'] = 9
            ..['subject_id'] = original['subject_hint'];
          final state = UiPreviewState();
          await preview.mountPage(
            tester,
            PracticePage(state: state, questions: [question]),
            width: width,
            height: 844,
            push: true,
          );
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 120)),
          );
          await tester.pumpAndSettle();
          expect(find.textContaining('图片缺失或校验失败'), findsNothing);
          expect(find.byType(Image), findsWidgets);
          expect(tester.takeException(), isNull);
          await preview.capture(
            tester,
            'word-media-$sourceIndex-${width.toInt()}',
          );
          // Also inspect options below long, shared source diagrams.
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -500),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await preview.capture(
            tester,
            'word-media-$sourceIndex-${width.toInt()}-lower',
          );
          await preview.disposePage(tester, state);
          if (sourceIndex == 1046) {
            // The original answer is a pi fraction. Render the submitted state
            // too, so QA checks the answer retained from the source alongside
            // its diagram without creating a real learning record.
            final answerState = UiPreviewState();
            await preview.mountPage(
              tester,
              PracticePage(
                state: answerState,
                questions: [question],
                resume: {
                  'cursor': 0,
                  'answers': {
                    '0': ['π/3'],
                  },
                  'submitted': [0],
                },
              ),
              width: width,
              height: 844,
              push: true,
            );
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -650),
            );
            await tester.pumpAndSettle();
            expect(find.textContaining('正确答案：第1空：π/3'), findsOneWidget);
            expect(tester.takeException(), isNull);
            await preview.capture(
              tester,
              'word-media-$sourceIndex-${width.toInt()}-answer',
            );
            await preview.disposePage(tester, answerState);
          }
        },
      );
    }
  }
}
