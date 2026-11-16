import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zhikaotong/core.dart';
import 'package:zhikaotong/main.dart';

class PrivacyStore extends LocalStore {
  final values = <String, dynamic>{};
  @override
  Future<dynamic> read(String key) async => values[key];
  @override
  Future<void> write(String key, dynamic value) async {
    values[key] = value;
  }
}

void main() {
  testWidgets(
    'first launch shows agreements without collecting account fields',
    (tester) async {
      final state = AppState(PrivacyStore())..ready = true;
      await tester.pumpWidget(StudyApp(state: state));
      expect(find.text('同意协议，开始使用'), findsOneWidget);
      expect(find.byType(TextField), findsNothing);
      expect(state.api.consented, isFalse);
      await tester.ensureVisible(find.text('阅读《隐私政策》'));
      await tester.tap(find.text('阅读《隐私政策》'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Android Keystore'), findsOneWidget);
      expect(state.api.consented, isFalse);
      state.dispose();
    },
  );
  testWidgets('accepting privacy leads to closed-registration student login', (
    tester,
  ) async {
    final state = AppState(PrivacyStore())..ready = true;
    await tester.pumpWidget(StudyApp(state: state));
    await tester.ensureVisible(find.text('同意协议，开始使用'));
    await tester.tap(find.text('同意协议，开始使用'));
    await tester.pumpAndSettle();
    expect(state.api.consented, isTrue);
    expect(find.text('学校分配的账号'), findsOneWidget);
    expect(find.text('登录'), findsOneWidget);
    expect(find.textContaining('不提供公开注册'), findsOneWidget);
    state.dispose();
  });
}
