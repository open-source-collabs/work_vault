import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:work_vault/src/persistence/work_vault_database_interface.dart';
import 'package:work_vault/src/persistence/work_vault_database_web.dart';

void main() {
  test('WorkVaultDatabaseWeb stores, updates, projects, and clears records in-memory', () {
    final WorkVaultDatabaseWeb db = WorkVaultDatabaseWeb();
    final Uint8List token = Uint8List.fromList(<int>[1, 2, 3]);

    db.upsert(
      WorkVaultTaskRecord(
        taskId: 'web-1',
        status: 'running',
        filePath: 'archive.bin',
        downloadedBytes: 100,
        totalBytes: 500,
        resumptionData: token,
        verificationStatus: Sha256VerificationStatus.pending,
      ),
    );

    expect(db.getTask('web-1')?.status, 'running');
    expect(db.getTask('web-1')?.downloadedBytes, 100);
    expect(db.getTask('web-1')?.resumptionData, orderedEquals(<int>[1, 2, 3]));

    // Update with clearResumption
    db.upsert(
      WorkVaultTaskRecord(
        taskId: 'web-1',
        status: 'completed',
        filePath: 'archive.bin',
        downloadedBytes: 500,
        totalBytes: 500,
        verificationStatus: Sha256VerificationStatus.verified,
      ),
      clearResumption: true,
    );

    expect(db.getTask('web-1')?.status, 'completed');
    expect(db.getTask('web-1')?.resumptionData, isNull);

    // Record verification
    db.recordVerification(
      'web-1',
      Sha256VerificationStatus.verified,
      sha256: 'deadbeef',
    );
    expect(db.getTask('web-1')?.sha256, 'deadbeef');

    // Handler handle
    db.setHandlerHandle(999);
    expect(db.handlerHandle(), 999);

    expect(db.getTasks(), hasLength(1));
    db.close();
  });
}
