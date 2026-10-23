import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/work_vault.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a closure cannot be registered as the background handler', () async {
    await expectLater(
      WorkVault.registerBackgroundHandler(
        (WorkVaultBackgroundEvent _) async {},
      ),
      throwsArgumentError,
    );
  });

  testWidgets('the headless entry point signals ready', (
    WidgetTester tester,
  ) async {
    final List<String> methods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel(workVaultBackgroundChannel),
      (MethodCall call) async {
        methods.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel(workVaultBackgroundChannel),
        null,
      );
    });

    workVaultBackgroundMain();
    await tester.idle();

    expect(methods, contains('ready'));
  });
}
