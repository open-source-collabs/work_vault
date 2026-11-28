import 'dart:async';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../format.dart';
import '../platform/file_info.dart';

/// Where a completed download was saved, its size, and an on-demand SHA-256.
///
/// The hash is computed here rather than read from the vault's database: that
/// file belongs to the host and its workers, and the UI should not write to it.
class CompletedFilePanel extends StatefulWidget {
  /// Creates a panel for the file at [path].
  const CompletedFilePanel({super.key, required this.path});

  /// Destination path, or a file name on web.
  final String path;

  @override
  State<CompletedFilePanel> createState() => _CompletedFilePanelState();
}

class _CompletedFilePanelState extends State<CompletedFilePanel> {
  Future<int?>? _size;
  bool _hashing = false;
  String? _digest;
  String? _hashError;

  @override
  void initState() {
    super.initState();
    if (supportsFileInfo) {
      _size = fileSize(widget.path);
    }
  }

  @override
  void didUpdateWidget(CompletedFilePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path && supportsFileInfo) {
      _size = fileSize(widget.path);
      _digest = null;
      _hashError = null;
    }
  }

  Future<void> _hash() async {
    setState(() {
      _hashing = true;
      _hashError = null;
    });
    String? digest;
    String? error;
    try {
      digest = await sha256OfFile(widget.path);
      if (digest == null) {
        error = 'File missing';
      }
    } on Object catch (caught) {
      error = 'Could not read the file: $caught';
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _hashing = false;
      _digest = digest;
      _hashError = error;
    });
  }

  Future<void> _copyDigest(String digest) async {
    await Clipboard.setData(ClipboardData(text: digest));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('SHA-256 copied')));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? caption = theme.textTheme.bodySmall;
    final TextStyle? mono = caption?.copyWith(fontFamily: 'monospace');

    if (!supportsFileInfo) {
      return Text('Saved by the browser as ${widget.path}', style: caption);
    }

    final String? digest = _digest;
    final String? hashError = _hashError;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SelectableText(widget.path, style: mono),
        const SizedBox(height: 4),
        FutureBuilder<int?>(
          future: _size,
          builder: (BuildContext context, AsyncSnapshot<int?> snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return Text('Reading size…', style: caption);
            }
            final int? size = snapshot.data;
            return Text(
              size == null ? 'File missing' : formatBytes(size),
              style: caption?.copyWith(
                color: size == null ? theme.colorScheme.error : null,
              ),
            );
          },
        ),
        const SizedBox(height: 4),
        if (digest != null)
          Row(
            children: <Widget>[
              Expanded(child: SelectableText('SHA-256 $digest', style: mono)),
              IconButton(
                tooltip: 'Copy SHA-256',
                icon: const Icon(Icons.copy, size: 18),
                onPressed: () => unawaited(_copyDigest(digest)),
              ),
            ],
          )
        else
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _hashing ? null : _hash,
              icon: _hashing
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.fingerprint),
              label: Text(_hashing ? 'Hashing…' : 'Compute SHA-256'),
            ),
          ),
        if (hashError != null)
          Text(
            hashError,
            style: caption?.copyWith(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}
