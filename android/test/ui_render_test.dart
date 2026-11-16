// Actual Flutter rendering with test-only content. Captures are not device screenshots.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/ios_theme.dart';
import 'package:zhikaotong/main.dart';

import 'ui_preview_support.dart';

const captureUi = bool.fromEnvironment('CAPTURE_UI');
const captureRatio = String.fromEnvironment(
  'UI_PREVIEW_RATIO',
  defaultValue: '2',
);
const captureSuffix = String.fromEnvironment('UI_PREVIEW_SUFFIX');
const captureBoundary = ValueKey('native-ui-preview');

Future<void> loadPreviewFonts() async {
  // Flutter widget tests do not automatically load the app's font manifest.
  // Load the actual bundled editorial and icon assets for faithful screenshots.
  await (FontLoader(
    'NotoSerifSC',
  )..addFont(rootBundle.load('assets/fonts/NotoSerifSC.ttf'))).load();
  await (FontLoader('packages/cupertino_icons/CupertinoIcons')..addFont(
        rootBundle.load('packages/cupertino_icons/assets/CupertinoIcons.ttf'),
      ))
      .load();
  final normal = File(
    Platform.environment['UI_PREVIEW_FONT'] ?? r'C:\Windows\Fonts\msyh.ttc',
  );
  if (await normal.exists()) {
    final bytes = ByteData.sublistView(await normal.readAsBytes());
    final bold = File(r'C:\Windows\Fonts\msyhbd.ttc');
    for (final family in [
      'UiPreviewSans',
      '.SF Pro Text',
      '.SF Pro Display',
      'CupertinoSystemText',
      'CupertinoSystemDisplay',
      '.AppleSystemUIFont',
      'Roboto',
      'Segoe UI',
    ]) {
      final loader = FontLoader(family)..addFont(Future.value(bytes));
      if (await bold.exists())
        loader.addFont(
          Future.value(ByteData.sublistView(await bold.readAsBytes())),
        );
      await loader.load();
    }
  }
  final icons = File(
    '${Platform.environment['FLUTTER_ROOT'] ?? ''}/bin/cache/artifacts/material_fonts/materialicons-regular.otf',
  );
  if (await icons.exists()) {
    await (FontLoader('MaterialIcons')..addFont(
          Future.value(ByteData.sublistView(await icons.readAsBytes())),
        ))
        .load();
  }
}

ThemeData previewTheme() {
  final theme = iosTheme();
  const family = 'UiPreviewSans';
  TextStyle font(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: family);
  ButtonStyle button(ButtonStyle? style) =>
      (style ?? const ButtonStyle()).copyWith(
        textStyle: WidgetStateProperty.resolveWith(
          (states) => font(
            style?.textStyle?.resolve(states) ?? theme.textTheme.labelLarge,
          ),
        ),
      );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: family),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: family),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: font(theme.appBarTheme.titleTextStyle),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: font(theme.listTileTheme.titleTextStyle),
      subtitleTextStyle: font(theme.listTileTheme.subtitleTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: button(theme.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: button(theme.textButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: button(theme.outlinedButtonTheme.style),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: font(theme.chipTheme.labelStyle),
    ),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: font(theme.dialogTheme.titleTextStyle),
      contentTextStyle: font(theme.dialogTheme.contentTextStyle),
    ),
  );
}

Future<void> capture(WidgetTester tester, String name) async {
  if (!captureUi) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(captureBoundary),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(
      pixelRatio: double.parse(captureRatio),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory(
      '${Directory.current.parent.path}/runtime/ui-previews',
    );
    await directory.create(recursive: true);
    await File(
      '${directory.path}/native-$name$captureSuffix.png',
    ).writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> mountPage(
  WidgetTester tester,
  Widget page, {
  double width = 390,
  double height = 844,
  double scale = 1,
  bool push = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, height);
  final navigatorKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      theme: previewTheme(),
      builder: (context, child) => RepaintBoundary(
        key: captureBoundary,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            padding: const EdgeInsets.only(top: 24, bottom: 20),
          ),
          child: child!,
        ),
      ),
      home: push ? const Scaffold() : page,
    ),
  );
  if (push) {
    navigatorKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle(const Duration(milliseconds: 80));
}

Future<void> disposePage(WidgetTester tester, UiPreviewState state) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  state.dispose();
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadPreviewFonts);
  for (final compact in [false, true]) {
    final width = compact ? 320.0 : 390.0;
    final height = compact ? 700.0 : 844.0;
    final scale = compact ? 1.3 : 1.0;
    final suffix = compact ? '-compact-large-text' : '';
    for (final screen in [
      'login',
      'home',
      'practice',
      'fill',
      'review',
      'classes',
      'profile',
      'subject',
    ]) {
      testWidgets(
        '$screen layout${compact ? ' at320px with130%text' : ' at390px'}',
        (tester) async {
          final state = UiPreviewState();
          late Widget page;
          switch (screen) {
            case 'login':
              page = LoginPage(state: state);
              break;
            case 'practice':
              page = PracticePage(
                state: state,
                questions: [
                  previewQuestion(),
                  previewQuestion(type: 'fill'),
                ],
              );
              break;
            case 'fill':
              page = PracticePage(
                state: state,
                questions: [previewQuestion(type: 'fill')],
              );
              break;
            case 'subject':
              page = SubjectPage(state: state, subject: state.subjects[1]);
              break;
            default:
              page = HomeShell(state: state);
          }
          await mountPage(
            tester,
            page,
            width: width,
            height: height,
            scale: scale,
            push:
                screen == 'practice' || screen == 'fill' || screen == 'subject',
          );
          final tab = {
            'review': '复习',
            'classes': '班级',
            'profile': '我的',
          }[screen];
          if (tab != null) {
            await tester.tap(find.text(tab).last);
            await tester.pumpAndSettle();
          }
          expect(
            tester.takeException(),
            isNull,
            reason:
                '$screen should stay readable without overflow at${width.toInt()}px/${(scale * 100).round()}%',
          );
          await capture(tester, '$screen$suffix');
          await disposePage(tester, state);
        },
      );
    }
  }
}
