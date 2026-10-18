import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/commitment/commitment_detail_screen.dart';
import '../../features/purchase/lot_detail_screen.dart';
import '../../features/purchase/purchase_batch_detail_screen.dart';
import '../../features/sell/sale_detail_screen.dart';
import '../../features/sell/sale_verification_detail_screen.dart';
import '../data/app_repository.dart';
import '../models/item_status.dart';
import '../sync/sync_service.dart';
import 'notification_channel.dart';
import 'push_service.dart';
import '../navigation/app_shell.dart';

/// So a notification tapped from the tray can open its record, whatever the
/// app happened to be showing — or was not showing, having been closed.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();
final GlobalKey<ScaffoldMessengerState> appMessengerKey = GlobalKey<ScaffoldMessengerState>();

/// Registers this phone for notifications and says what to do with them.
///
/// Called once someone is signed in, because the server tells a *person*
/// about their work: a Cashier hears about cash to release, a Sales Rep
/// about an order that came back.
Future<void> attachPushNotifications(PushService? push) async {
  // Null on a build with no Firebase — the tests, and the web preview.
  if (push == null) return;
  push.onForeground = _showInTray;
  push.onOpened = _openRecord;
  // The channel is what makes a notification urgent enough to be seen in a
  // busy shop, and it has to exist before one arrives.
  await NotificationChannel.start(onTap: _openRecord);
  await push.start();
}

/// The notification service, where there is one.
PushService? pushServiceOf(BuildContext context) {
  try {
    return context.read<PushService>();
  } on ProviderNotFoundException {
    return null;
  }
}

/// The app is open and in front, so Firebase hands the message over instead
/// of putting it in the tray. The app puts it there itself: a person at the
/// counter should see the same thing whether or not they happen to be
/// looking at the app.
void _showInTray(PushAlert alert) {
  NotificationChannel.show(alert);
}

/// Opens what the notification is about.
///
/// The record may have been made on another phone, so the latest is taken
/// first; if it still is not here, the person is told rather than shown an
/// empty screen.
Future<void> _openRecord(PushAlert alert) async {
  final navigator = appNavigatorKey.currentState;
  if (navigator == null || !alert.hasRecord) return;
  final context = navigator.context;
  final repository = context.read<AppRepository>();
  final id = alert.recordId!;

  Widget? screenFor() {
    switch (alert.kind) {
      case 'purchase':
        return repository.findBatch(id) == null ? null : PurchaseBatchDetailScreen(batchId: id);
      case 'sale':
        final sale = repository.findSale(id);
        if (sale == null) return null;
        // An order still waiting on payment opens on the Cashier's screen;
        // one already paid opens on its record.
        return sale.verificationStatus == VerificationStatus.verified
            ? SaleDetailScreen(saleId: id)
            : SaleVerificationDetailScreen(saleId: id);
      case 'commitment':
        return repository.findCommitment(id) == null ? null : CommitmentDetailScreen(commitmentId: id);
      case 'item':
        return repository.findItem(id) == null ? null : LotDetailScreen(itemId: id);
      default:
        return null;
    }
  }

  var screen = screenFor();
  if (screen == null) {
    // Not on this phone yet — it was made somewhere else a moment ago.
    try {
      await context.read<SyncService>().syncNow();
    } on ProviderNotFoundException {
      // Nothing to sync with.
    }
    screen = screenFor();
  }

  if (screen == null) {
    appMessengerKey.currentState?.showSnackBar(
      SnackBar(content: Text('$id is not on this phone yet. Pull down to sync.')),
    );
    return;
  }
  // Into the pane the person is looking at, so a tapped notification does
  // not throw away the frame around it on a desktop. Read from the live
  // navigator rather than the context captured before the sync, which may
  // by now be gone.
  final current = appNavigatorKey.currentContext;
  // ignore: use_build_context_synchronously
  if (current != null) AppShell.openDetail(current, screen);
}
