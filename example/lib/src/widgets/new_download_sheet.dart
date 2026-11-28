import 'package:material_ui/material_ui.dart';
import 'package:work_vault/work_vault.dart';

import '../download_defaults.dart';
import '../downloads_controller.dart';
import '../platform/file_info.dart';

/// Opens the new-download form and returns the enqueued task, if any.
Future<TaskSnapshot?> showNewDownloadSheet(
  BuildContext context,
  DownloadsController controller,
) {
  return showModalBottomSheet<TaskSnapshot>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    useSafeArea: true,
    builder: (BuildContext context) => NewDownloadSheet(controller: controller),
  );
}

/// Form that builds a [WorkTaskConfig] and enqueues it.
///
/// Validation is delegated to [WorkTaskConfig.validate], so the messages shown
/// here are exactly the rules the vault enforces.
class NewDownloadSheet extends StatefulWidget {
  /// Creates the form for [controller].
  const NewDownloadSheet({super.key, required this.controller});

  /// Receives the new task.
  final DownloadsController controller;

  @override
  State<NewDownloadSheet> createState() => _NewDownloadSheetState();
}

class _NewDownloadSheetState extends State<NewDownloadSheet> {
  static const RetryPolicy _defaultRetry = RetryPolicy();

  final TextEditingController _url = TextEditingController(
    text: sampleDownloadUrl,
  );
  final TextEditingController _fileName = TextEditingController(
    text: sampleFileName,
  );
  final TextEditingController _maxAttempts = TextEditingController(
    text: '${_defaultRetry.maxAttempts}',
  );
  final TextEditingController _initialBackoff = TextEditingController(
    text: '${_defaultRetry.initialBackoff.inSeconds}',
  );
  final TextEditingController _maxBackoff = TextEditingController(
    text: '${_defaultRetry.maxBackoff.inSeconds}',
  );

  NetworkConstraint _network = NetworkConstraint.any;
  bool _requiresCharging = false;
  bool _requiresBatteryNotLow = false;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    _fileName.dispose();
    _maxAttempts.dispose();
    _initialBackoff.dispose();
    _maxBackoff.dispose();
    super.dispose();
  }

  /// Builds the config, or throws [InvalidWorkConfig] with a field message.
  WorkTaskConfig _buildConfig() {
    int whole(TextEditingController field, String name) {
      final int? value = int.tryParse(field.text.trim());
      if (value == null) {
        throw InvalidWorkConfig('$name must be a whole number.');
      }
      return value;
    }

    final String fileName = _fileName.text.trim();
    if (fileName.isEmpty) {
      throw const InvalidWorkConfig('Enter a file name.');
    }
    if (fileName.contains('/') || fileName.contains(r'\')) {
      throw const InvalidWorkConfig(
        'The file name cannot contain a folder separator.',
      );
    }
    if (fileName == '.' || fileName == '..') {
      throw const InvalidWorkConfig('Enter a file name, not a folder.');
    }

    final WorkTaskConfig config = WorkTaskConfig(
      taskId: taskIdFor(fileName, DateTime.now()),
      url: _url.text.trim(),
      destinationPath: joinDownloadPath(
        widget.controller.downloadDirectory,
        fileName,
      ),
      network: _network,
      battery: BatteryConstraint(
        requiresCharging: _requiresCharging,
        requiresBatteryNotLow: _requiresBatteryNotLow,
      ),
      retry: RetryPolicy(
        maxAttempts: whole(_maxAttempts, 'Max attempts'),
        initialBackoff: Duration(
          seconds: whole(_initialBackoff, 'Initial backoff'),
        ),
        maxBackoff: Duration(seconds: whole(_maxBackoff, 'Max backoff')),
      ),
      notification: notificationFor(fileName),
    );
    config.validate();
    // Two transfers writing one file would corrupt it. The vault cannot know
    // this, because only the app knows which destinations it handed out.
    if (widget.controller.isDestinationInUse(config.destinationPath)) {
      throw const InvalidWorkConfig(
        'Another download is still saving to this file. Pick another name.',
      );
    }
    return config;
  }

  Future<void> _submit() async {
    final WorkTaskConfig config;
    try {
      config = _buildConfig();
    } on InvalidWorkConfig catch (error) {
      setState(() => _error = error.message);
      return;
    }

    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final TaskSnapshot snapshot = await widget.controller.enqueue(config);
      if (mounted) {
        Navigator.of(context).pop(snapshot);
      }
    } on WorkVaultFailure catch (error) {
      if (mounted) {
        setState(() {
          _submitting = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final String? error = _error;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('New download', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey<String>('url'),
              controller: _url,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'HTTPS URL',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('fileName'),
              controller: _fileName,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'File name',
                helperText: supportsFileInfo
                    ? 'Saved in ${widget.controller.downloadDirectory}'
                    : 'Saved by the browser',
                helperMaxLines: 2,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            Text('Network', style: theme.textTheme.labelLarge),
            const SizedBox(height: 8),
            SegmentedButton<NetworkConstraint>(
              segments: const <ButtonSegment<NetworkConstraint>>[
                ButtonSegment<NetworkConstraint>(
                  value: NetworkConstraint.any,
                  label: Text('Any'),
                  icon: Icon(Icons.network_cell),
                ),
                ButtonSegment<NetworkConstraint>(
                  value: NetworkConstraint.unmetered,
                  label: Text('Unmetered'),
                  icon: Icon(Icons.wifi),
                ),
                ButtonSegment<NetworkConstraint>(
                  value: NetworkConstraint.notRoaming,
                  label: Text('Not roaming'),
                  icon: Icon(Icons.signal_cellular_alt),
                ),
              ],
              selected: <NetworkConstraint>{_network},
              onSelectionChanged: (Set<NetworkConstraint> value) {
                setState(() => _network = value.single);
              },
            ),
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Only while charging'),
              value: _requiresCharging,
              onChanged: (bool value) {
                setState(() => _requiresCharging = value);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Not when the battery is low'),
              subtitle: const Text('Advisory on iOS'),
              value: _requiresBatteryNotLow,
              onChanged: (bool value) {
                setState(() => _requiresBatteryNotLow = value);
              },
            ),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Retry'),
              subtitle: const Text('Used when a failure can be retried'),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              children: <Widget>[
                _NumberField(
                  fieldKey: 'maxAttempts',
                  controller: _maxAttempts,
                  label: 'Max attempts (including the first)',
                ),
                const SizedBox(height: 12),
                _NumberField(
                  fieldKey: 'initialBackoff',
                  controller: _initialBackoff,
                  label: 'Initial backoff (seconds)',
                ),
                const SizedBox(height: 12),
                _NumberField(
                  fieldKey: 'maxBackoff',
                  controller: _maxBackoff,
                  label: 'Max backoff (seconds)',
                ),
              ],
            ),
            if (error != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                error,
                key: const ValueKey<String>('formError'),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _submitting ? null : _submit,
              icon: _submitting
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.download),
              label: const Text('Start download'),
            ),
          ],
        ),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.fieldKey,
    required this.controller,
    required this.label,
  });

  final String fieldKey;
  final TextEditingController controller;
  final String label;

  @override
  Widget build(BuildContext context) {
    return TextField(
      key: ValueKey<String>(fieldKey),
      controller: controller,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }
}
