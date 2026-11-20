import 'package:material_ui/material_ui.dart';

/// Cloud sync states shown in the [CloudStatusCard].
enum CloudSyncState { idle, syncing, uploading, offline }

/// Compact status card shown below the detection stats bar: pairing
/// state, the Connection Details (camera, farmer account, connection
/// status, last heartbeat) and pending/failed upload counts. Follows the
/// app's light-green M3 card look.
class CloudStatusCard extends StatelessWidget {
  const CloudStatusCard({
    super.key,
    required this.paired,
    this.cameraName,
    required this.state,
    required this.pendingCount,
    required this.failedCount,
    required this.lastSyncAt,
    this.onPair,
    this.onRetry,
    this.now,
    this.cameraId,
    this.farmerName,
    this.farmerEmailMasked,
    this.backendOnline = false,
    this.lastHeartbeatAt,
    this.noticeText,
    this.onUnpair,
  });

  /// Whether a camera registration is stored.
  final bool paired;

  /// Camera name shown when [paired].
  final String? cameraName;

  final CloudSyncState state;

  /// Events waiting for a confirmed upload.
  final int pendingCount;

  /// Events that exhausted their attempts (kept on the device).
  final int failedCount;

  /// UTC instant of the last server-confirmed sync (null = never).
  final DateTime? lastSyncAt;

  /// Opens the pairing dialog (null hides the button).
  final VoidCallback? onPair;

  /// Manually retries failed uploads (null hides the button).
  final VoidCallback? onRetry;

  /// Injectable clock for the relative-time rendering (tests pass a
  /// fixed one); defaults to `DateTime.now`.
  final DateTime Function()? now;

  /// Server id of this camera (only the first 8 characters are shown).
  final String? cameraId;

  /// Display name of the paired farmer account.
  final String? farmerName;

  /// Server-masked email of the paired farmer account.
  final String? farmerEmailMasked;

  /// Whether the last heartbeat/session call reached the backend.
  final bool backendOnline;

  /// UTC instant of the last confirmed heartbeat / session refresh.
  final DateTime? lastHeartbeatAt;

  /// One-line notice (e.g. the camera was removed from the farmer account).
  final String? noticeText;

  /// Disconnects this camera (null hides the Disconnect action).
  final VoidCallback? onUnpair;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelLarge;
    final nowFn = now ?? DateTime.now;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _pairingRow(theme, labelStyle),
            if (paired) ...[
              const SizedBox(height: 6),
              _accountRow(theme),
              _cameraIdRow(theme),
            ],
            const SizedBox(height: 6),
            _syncRow(theme, labelStyle),
            const SizedBox(height: 6),
            Text(
              'Last sync: '
              '${_relativeTime(_latestSyncInstant(), nowFn())}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (noticeText != null) ...[
              const SizedBox(height: 6),
              Text(
                noticeText!,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The most recent of the last upload sync and the last heartbeat.
  DateTime? _latestSyncInstant() {
    final sync = lastSyncAt;
    final heartbeat = lastHeartbeatAt;
    if (sync == null) {
      return heartbeat;
    }
    if (heartbeat == null) {
      return sync;
    }
    return heartbeat.isAfter(sync) ? heartbeat : sync;
  }

  Widget _pairingRow(ThemeData theme, TextStyle? labelStyle) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          paired ? Icons.videocam : Icons.videocam_off_outlined,
          size: 18,
          color: paired
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: 6),
        if (paired) ...[
          Text('Paired · ', style: labelStyle),
          Flexible(
            child: Text(
              cameraName ?? 'Camera',
              style: labelStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onUnpair != null) ...[
            const SizedBox(width: 4),
            TextButton(
              onPressed: onUnpair,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Disconnect'),
            ),
          ],
        ] else ...[
          Flexible(
            child: Text(
              'Not paired',
              style: labelStyle,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onPair != null) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: onPair,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Pair this camera'),
            ),
          ],
        ],
      ],
    );
  }

  /// `Account: <name> (<masked email>)` — shown when the server provided
  /// farmer details for this camera.
  Widget _accountRow(ThemeData theme) {
    final name = farmerName;
    final email = farmerEmailMasked;
    if (name == null && email == null) {
      return const SizedBox.shrink();
    }
    final String account;
    if (name != null && email != null) {
      account = '$name ($email)';
    } else {
      account = name ?? email!;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Text(
        'Account: $account',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  /// `Camera ID: <first 8 chars>` — short enough to read out to support.
  Widget _cameraIdRow(ThemeData theme) {
    final id = cameraId;
    if (id == null || id.isEmpty) {
      return const SizedBox.shrink();
    }
    final shortId = id.length <= 8 ? id : id.substring(0, 8);
    return Padding(
      padding: const EdgeInsets.only(left: 24),
      child: Text(
        'Camera ID: $shortId',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _syncRow(ThemeData theme, TextStyle? labelStyle) {
    final online = backendOnline ||
        (state == CloudSyncState.idle && lastSyncAt != null);
    final (icon, color, label) = online
        ? (Icons.cloud_done, theme.colorScheme.primary, 'Online')
        : switch (state) {
            CloudSyncState.idle => (
                Icons.cloud,
                theme.colorScheme.onSurfaceVariant,
                'Idle',
              ),
            CloudSyncState.syncing => (
                Icons.cloud_sync,
                theme.colorScheme.primary,
                'Syncing',
              ),
            CloudSyncState.uploading => (
                Icons.cloud_upload,
                theme.colorScheme.primary,
                'Uploading',
              ),
            CloudSyncState.offline => (
                Icons.cloud_off,
                theme.colorScheme.onSurfaceVariant,
                'Offline',
              ),
          };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(label, style: labelStyle),
        if (pendingCount > 0) ...[
          const SizedBox(width: 16),
          Icon(
            Icons.schedule,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Text('$pendingCount pending', style: labelStyle),
        ],
        if (failedCount > 0) ...[
          const SizedBox(width: 16),
          Icon(
            Icons.error_outline,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: 6),
          Text(
            '$failedCount failed — kept on this device',
            style: labelStyle?.copyWith(color: theme.colorScheme.error),
          ),
          if (onRetry != null)
            TextButton(
              onPressed: onRetry,
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: const Text('Retry now'),
            ),
        ],
      ],
    );
  }

  /// Human-friendly relative time: 'Just now', '2 min ago', '3 h ago',
  /// '5 d ago' — or 'Never' before the first successful sync.
  String _relativeTime(DateTime? instant, DateTime now) {
    if (instant == null) {
      return 'Never';
    }
    final delta = now.difference(instant);
    if (delta < const Duration(minutes: 1)) {
      return 'Just now';
    }
    if (delta < const Duration(hours: 1)) {
      return '${delta.inMinutes} min ago';
    }
    if (delta < const Duration(days: 1)) {
      return '${delta.inHours} h ago';
    }
    return '${delta.inDays} d ago';
  }
}
