import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault_example/main.dart';

void main() {
  testWidgets('shows the sample download', (WidgetTester tester) async {
    await tester.pumpWidget(const WorkVaultExampleApp());

    expect(find.text('work_vault'), findsOneWidget);
    expect(find.text('sample-archive'), findsOneWidget);
    expect(find.text('Enqueue'), findsOneWidget);
  });
}
