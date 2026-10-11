# work_vault

Type-safe background downloads for Flutter. Dart schedules, pauses, resumes, cancels, and observes work. The host process owns the transfer.

iOS downloads run in a background `URLSession` and survive process termination. Android downloads run in WorkManager. When the UI engine is gone, the host starts a headless `FlutterEngine` at `workVaultBackgroundMain` and delivers events on a platform channel. Task rows, resume tokens, and SHA-256 status live in a SQLite file both isolates open. There is no `IsolateNameServer`.

## Platforms & Requirements

- **Dart**: 3.13 or newer
- **Flutter**: 3.47 or newer
- **Android**: 8.0 (API 26)+ via WorkManager
- **iOS**: 15+ via Background `URLSession`
- **Windows**: Desktop background isolate engine with SQLite persistence (`package:sqlite3`)
- **Linux**: Desktop background isolate engine with SQLite persistence (`package:sqlite3`)
- **Web**: In-browser Fetch & Streams API with web database persistence and browser save triggers

## Usage

```dart
await WorkVault.instance.initialize();

final TaskSnapshot snapshot = await WorkVault.instance.enqueue(
  WorkTaskConfig(
    taskId: 'archive-1',
    url: 'https://cdn.example.com/archive.bin',
    destinationPath: '/data/user/0/archive.bin',
    notification: NotificationMetadata(
      title: 'Archive',
      body: 'Saving archive.bin',
      channelId: 'work.vault.downloads',
      channelName: 'Downloads',
    ),
  ),
);

WorkVault.instance.watchProgress(snapshot.taskId).listen((TaskProgress progress) {
  debugPrint('${progress.percentage ?? 0}%');
});
```

`taskId` is the identity. Enqueueing it again throws `DuplicateTask`. Version 1 accepts `GET` only. `pause` is legal from `running`, `resume` from `paused`, and `cancel` from `enqueued`, `running`, or `paused`.

## Version 1 contract

One behavior ships: a resumable HTTPS `GET`, the same on Android and iOS. The stored verb is the only routing gate, so a `GET` is never handed to the TUS upload handler and a verb the download engine cannot resume is never started.

The host store owns `status`, the byte count, the entity tag, and the resume position those two describe. SQLite is the projection the headless callback reads, not a second source of truth: every host event carries the same snapshot the UI isolate would have received, and a field the host does not know clears the stored one. `initialize` reads the host, so a row left behind by an earlier run never seeds the vault.

Checksums follow the same split. The native verifier hashes a finished file and decides `completed` or `failed`. Hashing in Dart only records `verified`, `mismatch`, or `missing` against the digest already on record; it never moves a task to another status.

Call `initialize` before enqueueing. It loads tasks that finished while the app was gone. Host progress and status events are delivered only while an engine is attached.

## iOS

The host app forwards two system events. Register the maintenance task before `didFinishLaunching` returns, and pass background session events through before the Flutter engine exists:

```swift
import work_vault

WorkVaultBackgroundEvents.registerMaintenanceTask()

WorkVaultBackgroundEvents.handleEvents(
  forBackgroundURLSession: identifier,
  completionHandler: completionHandler
)
```

`Info.plist` needs the maintenance identifier. `processing` is required by `BGProcessingTask` and is not used to keep the UI alive. The download itself is a background `URLSessionDownloadTask`.

```xml
<key>BGTaskSchedulerPermittedIdentifiers</key>
<array>
  <string>com.workvault.work_vault.maintenance</string>
</array>
<key>UIBackgroundModes</key>
<array>
  <string>processing</string>
</array>
```

`any` allows every network. `unmetered` waits for a non-cellular, non-expensive path. `notRoaming` allows cellular and refuses expensive paths, which is how iOS represents roaming. A task that requires external power or a non-low battery stays enqueued until the maintenance task, or the next `initialize`, sees that condition.

## Background callbacks

Register a top-level function before the UI engine can be destroyed. The same function runs inside the headless engine, looked up by callback handle rather than a named port:

```dart
@pragma('vm:entry-point')
Future<void> onWorkVaultBackground(WorkVaultBackgroundEvent event) async {
  final WorkVaultDatabase database = WorkVaultDatabase.openFile(event.databasePath);
  final WorkVaultTaskRecord? row = database.getTask(event.taskId);
  database.close();
}

await WorkVault.registerBackgroundHandler(onWorkVaultBackground);
```

The host entrypoint is `workVaultBackgroundMain` in `package:work_vault/src/isolate/background_entry_point.dart`. A completed file is hashed there. `verificationStatus` is `verified` for the first digest, `mismatch` when a later hash differs, and `missing` when the file is gone. Progress rows keep an existing digest.

## Contract

`pigeons/messages.dart` is the schema. Regenerate the Dart, Kotlin, and Swift bindings with:

```sh
dart run pigeon --input pigeons/messages.dart
```

Commit the generated files. Both sides of the channel must be produced by the same Pigeon version.

## License

BSD 3-Clause. See [LICENSE](LICENSE).
