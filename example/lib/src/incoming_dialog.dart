import 'package:flutter/material.dart';

/// User's decision on an incoming transfer request.
enum IncomingDecision { accept, always, block, reject }

String _formatBytes(int? bytes) {
  if (bytes == null || bytes <= 0) return '';
  const units = ['B', 'KB', 'MB', 'GB'];
  double size = bytes.toDouble();
  int u = 0;
  while (size >= 1024 && u < units.length - 1) {
    size /= 1024;
    u++;
  }
  return '${size.toStringAsFixed(size >= 10 || u == 0 ? 0 : 1)} ${units[u]}';
}

/// Shows the "incoming request" dialog and returns the user's decision (null if
/// dismissed).
Future<IncomingDecision?> showIncomingRequestDialog(
  BuildContext context, {
  required String senderName,
  int? fileCount,
  int? totalBytes,
  String? meta,
}) {
  final size = _formatBytes(totalBytes);
  final parts = <String>[
    if (fileCount != null) '$fileCount file${fileCount == 1 ? '' : 's'}',
    if (size.isNotEmpty) size,
  ];
  return showDialog<IncomingDecision>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Incoming files'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(TextSpan(children: [
            TextSpan(
                text: senderName,
                style: const TextStyle(fontWeight: FontWeight.bold)),
            const TextSpan(text: ' wants to send you files.'),
          ])),
          if (parts.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(parts.join(' • '),
                style: const TextStyle(color: Colors.black54)),
          ],
          if (meta != null && meta.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Note: $meta', style: const TextStyle(color: Colors.black54)),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, IncomingDecision.block),
          child: const Text('Block', style: TextStyle(color: Colors.red)),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, IncomingDecision.reject),
          child: const Text('Decline'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, IncomingDecision.always),
          child: const Text('Always'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, IncomingDecision.accept),
          child: const Text('Accept'),
        ),
      ],
    ),
  );
}
