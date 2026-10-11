/// Background download control plane for Flutter.
///
/// The public API schedules work and observes it. Platform workers are reached
/// through the Pigeon contract in `pigeons/messages.dart`.
library;

// Flutter's generated plugin registrant imports `WorkVaultLinux` and
// `WorkVaultWindows` from this library, so they must be exported here.
export 'src/desktop/desktop_plugins_io.dart'
    if (dart.library.js_interop) 'src/desktop/desktop_plugins_stub.dart';
export 'src/isolate/background_entry_point.dart'
    show
        registerWorkVaultBackgroundHandler,
        workVaultBackgroundChannel,
        workVaultBackgroundEntrypoint,
        workVaultBackgroundLibrary,
        workVaultBackgroundMain;
export 'src/isolate/background_event_processor.dart'
    show WorkVaultBackgroundEvent, WorkVaultBackgroundHandler;
export 'src/models/battery_constraint.dart';
export 'src/models/http_method.dart';
export 'src/models/network_constraint.dart';
export 'src/models/notification_metadata.dart';
export 'src/models/retry_policy.dart';
export 'src/models/task_failure.dart';
export 'src/models/task_progress.dart';
export 'src/models/task_snapshot.dart';
export 'src/models/task_status.dart' show TaskStatus, taskStatusIsTerminal;
export 'src/models/work_task_config.dart';
export 'src/models/work_vault_failure.dart';
export 'src/persistence/work_vault_database.dart';
export 'src/task_transition.dart' show TaskCommand, nextTaskStatus;
export 'src/work_vault.dart';
