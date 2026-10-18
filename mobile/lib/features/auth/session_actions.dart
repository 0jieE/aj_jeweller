import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_client.dart';
import '../../core/data/app_repository.dart';
import '../../core/models/app_user.dart';
import '../../core/notifications/push_notifications.dart';
import '../../core/state/session_state.dart';
import '../../core/sync/sync_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';

/// Changing your own PIN. The server hands back new tokens, which ends every
/// other session you had — so a PIN someone watched you type stops working.
Future<void> showChangePinDialog(BuildContext context) async {
  final current = TextEditingController();
  final next = TextEditingController();
  final confirm = TextEditingController();
  final messenger = ScaffoldMessenger.of(context);
  final session = context.read<SessionState>();

  final saved = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        String? error;
        Future<void> submit() async {
          if (next.text != confirm.text) {
            setState(() => error = 'The new PINs do not match.');
            return;
          }
          if (next.text.length < 4 || next.text.length > 6) {
            setState(() => error = 'A PIN is 4 to 6 digits.');
            return;
          }
          try {
            await session.changePin(currentPin: current.text, newPin: next.text);
            if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
          } on ApiRefusal catch (e) {
            setState(() => error = e.message);
          } on ApiUnauthorized {
            setState(() => error = 'That current PIN is not right.');
          } on ApiUnavailable catch (e) {
            setState(() => error = e.message);
          }
        }

        return AlertDialog(
          title: const Text('Change PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final field in [
                (current, 'Current PIN'),
                (next, 'New PIN'),
                (confirm, 'Repeat new PIN'),
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: TextField(
                    controller: field.$1,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                    decoration: InputDecoration(labelText: field.$2),
                  ),
                ),
              if (error != null)
                Text(error!, style: AppTextStyles.caption.copyWith(color: AppColors.danger)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Change PIN')),
          ],
        );
      },
    ),
  );

  current.dispose();
  next.dispose();
  confirm.dispose();
  if (saved == true) {
    messenger.showSnackBar(const SnackBar(content: Text('PIN changed.')));
  }
}

/// Signing out. Anything still queued is kept — it belongs to the shop, not
/// to the session — but it only goes up once someone signs in again.
Future<void> confirmSignOut(BuildContext context) async {
  final sync = context.read<SyncService>();
  final session = context.read<SessionState>();
  final push = pushServiceOf(context);
  final pending = sync.pendingCount;

  final out = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Sign out?'),
      content: Text(
        pending == 0
            ? 'Everything has been sent to the server.'
            : '$pending change(s) have not reached the server yet. They stay on this '
                'phone and go up the next time someone signs in here.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Sign out')),
      ],
    ),
  );
  if (out != true) return;
  // Stop telling this handset about work that was that person's.
  await push?.stop();
  await session.signOut();
}

/// Sends this phone's own saved file to the server, once, to move a shop that
/// has been running offline onto the server without re-entering anything.
Future<void> showImportDialog(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final sync = context.read<SyncService>();
  final repository = context.read<AppRepository>();

  final go = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Send this phone\'s data to the server?'),
      content: const Text(
        'This uploads everything stored on this phone — purchases, sales, cash, '
        'photos — so the server starts from the shop\'s real records.\n\n'
        'It is checked first and reported back before anything is written.',
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Check it')),
      ],
    ),
  );
  if (go != true || !context.mounted) return;

  final snapshot = repository.toSnapshot();
  Map<String, dynamic> report;
  try {
    report = await sync.importSnapshot(snapshot, dryRun: true);
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('Could not check: $error')));
    return;
  }
  if (!context.mounted) return;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Ready to send'),
      content: SingleChildScrollView(child: Text(_reportText(report))),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.of(dialogContext).pop(true), child: const Text('Send for real')),
      ],
    ),
  );
  if (confirmed != true) return;

  try {
    final done = await sync.importSnapshot(snapshot, dryRun: false);
    await sync.loadSnapshot();
    messenger.showSnackBar(SnackBar(content: Text('Sent. ${_summaryLine(done)}')));
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('Could not send: $error')));
  }
}

String _summaryLine(Map<String, dynamic> report) {
  final created = report['created'];
  if (created is Map) {
    final total = created.values.whereType<num>().fold<num>(0, (sum, v) => sum + v);
    return '$total record(s) created.';
  }
  return 'The server accepted it.';
}

String _reportText(Map<String, dynamic> report) {
  final buffer = StringBuffer();
  for (final key in ['created', 'skipped', 'updated']) {
    final section = report[key];
    if (section is Map && section.isNotEmpty) {
      buffer.writeln('${key[0].toUpperCase()}${key.substring(1)}:');
      section.forEach((k, v) => buffer.writeln('  $k: $v'));
    }
  }
  final warnings = report['warnings'];
  if (warnings is List && warnings.isNotEmpty) {
    buffer.writeln('Warnings:');
    for (final warning in warnings.take(20)) {
      buffer.writeln('  • $warning');
    }
  }
  if (buffer.isEmpty) buffer.write(const JsonEncoder.withIndent('  ').convert(report));
  return buffer.toString();
}

/// Admin action: gives someone a PIN, or replaces one they have forgotten.
///
/// The actor is never sent — the server takes it from the token, so only a
/// signed-in Admin can do this and the log names them, not whoever was
/// picked on screen.
Future<void> showSetPinDialog(BuildContext context, AppUser user) async {
  final api = maybeRead<ApiClient>(context);
  if (api == null) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PINs are set on the server. Sign in first.')),
    );
    return;
  }

  final pin = TextEditingController();
  final confirm = TextEditingController();
  final messenger = ScaffoldMessenger.of(context);

  final set = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        String? error;
        var busy = false;
        Future<void> submit() async {
          if (pin.text != confirm.text) {
            setState(() => error = 'The two PINs do not match.');
            return;
          }
          if (pin.text.length < 4 || pin.text.length > 6) {
            setState(() => error = 'A PIN is 4 to 6 digits.');
            return;
          }
          setState(() => busy = true);
          try {
            await api.post('users/${user.id}/pin', body: {'pin': pin.text});
            if (dialogContext.mounted) Navigator.of(dialogContext).pop(true);
          } on ApiRefusal catch (e) {
            setState(() {
              busy = false;
              error = e.message;
            });
          } on ApiUnauthorized {
            setState(() {
              busy = false;
              error = 'Only an Admin can set someone\'s PIN.';
            });
          } on ApiUnavailable catch (e) {
            setState(() {
              busy = false;
              error = e.message;
            });
          }
        }

        return AlertDialog(
          title: Text('Set ${user.firstName}\'s PIN'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'They sign in with this and can change it themselves afterwards. '
                'Setting it ends any session they have open.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.sm),
              for (final field in [(pin, 'New PIN'), (confirm, 'Repeat new PIN')])
                Padding(
                  padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                  child: TextField(
                    controller: field.$1,
                    obscureText: true,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                    decoration: InputDecoration(labelText: field.$2),
                  ),
                ),
              if (error != null)
                Text(error!, style: AppTextStyles.caption.copyWith(color: AppColors.danger)),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(false), child: const Text('Cancel')),
            FilledButton(onPressed: busy ? null : submit, child: const Text('Set PIN')),
          ],
        );
      },
    ),
  );

  pin.dispose();
  confirm.dispose();
  if (set == true) {
    messenger.showSnackBar(SnackBar(content: Text('${user.firstName} can sign in with the new PIN.')));
  }
}

/// Null where the provider is not registered — the plain local build and the
/// widget tests run the same screens without a server behind them.
T? maybeRead<T>(BuildContext context) {
  try {
    return context.read<T>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// Whether this phone is set up to be told when something needs a person,
/// and a way to ask again if it is not.
Future<void> showNotificationsDialog(BuildContext context) async {
  final push = pushServiceOf(context);
  final messenger = ScaffoldMessenger.of(context);

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setState) {
        final registered = push?.isRegistered ?? false;
        final reason = push == null
            ? 'This build has no notification service in it.'
            : (push.error ??
                (registered
                    ? 'This phone will be told when a purchase is waiting on you, '
                        'an order needs payment, or a loan is coming due.'
                    : 'Not registered yet.'));

        return AlertDialog(
          title: const Text('Notifications'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    registered ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
                    color: registered ? AppColors.success : AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    registered ? 'On for this phone' : 'Off',
                    style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(reason, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
              if (!registered && push != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'If the phone never asks, turn notifications on for AJ Jeweler '
                  'in the phone\'s own Settings.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ],
          ),
          actions: [
            // For setting a new phone up: the token is what a test message
            // from the Firebase console is addressed to.
            if (registered)
              TextButton(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: push!.token ?? ''));
                  messenger.showSnackBar(
                    const SnackBar(content: Text('Token copied.')),
                  );
                },
                child: const Text('Copy token'),
              ),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Close')),
            if (push != null && !registered)
              FilledButton(
                onPressed: () async {
                  await push.start();
                  setState(() {});
                },
                child: const Text('Turn on'),
              ),
          ],
        );
      },
    ),
  );
}
