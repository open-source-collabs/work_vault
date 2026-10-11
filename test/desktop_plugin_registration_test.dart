import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/work_vault.dart';

void main() {
  // Flutter's generated plugin registrant imports these classes from the
  // package's main library, so a build breaks if they are not exported there.
  test('the desktop plugin classes are exported from the main library', () {
    expect(WorkVaultLinux.registerWith, isA<void Function()>());
    expect(WorkVaultWindows.registerWith, isA<void Function()>());
  });
}
