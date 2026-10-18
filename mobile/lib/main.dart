import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/api/api_client.dart';
import 'core/api/token_store.dart';
import 'core/data/app_repository.dart';
import 'core/data/app_storage.dart';
import 'core/navigation/app_shell.dart';
import 'core/notifications/push_notifications.dart';
import 'core/notifications/push_service.dart';
import 'core/state/app_state.dart';
import 'core/state/cart_state.dart';
import 'core/state/purchase_basket_state.dart';
import 'core/state/session_state.dart';
import 'core/sync/sync_service.dart';
import 'core/theme/app_theme.dart';
import 'features/auth/sign_in_screen.dart';

/// Wakes the app for a message that arrives with nothing on screen. It runs
/// in its own isolate, so it does no work beyond letting Android show the
/// notification — the record itself is read when the person taps it.
@pragma('vm:entry-point')
Future<void> _onBackgroundMessage(RemoteMessage message) async {}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebase = await PushService.init();
  if (firebase) FirebaseMessaging.onBackgroundMessage(_onBackgroundMessage);
  // The device's own copy is loaded before the first frame, so the app opens
  // on the shop's data — and keeps working when the server is unreachable.
  final repository = AppRepository();
  final storage = await AppStorage.attach(repository);
  final api = ApiClient();
  final session = SessionState(api: api, store: SecureTokenStore());
  final sync = SyncService(
    api: api,
    repository: repository,
    persist: storage?.saveOutbox,
  );
  final push = PushService(api: api, available: firebase);
  final restoredOutbox = await storage?.readOutbox();
  if (restoredOutbox != null) sync.restoreOutbox(restoredOutbox);
  await session.restore();

  runApp(AjJewelerApp(
    repository: repository,
    session: session,
    sync: sync,
    api: api,
    push: push,
  ));
}

/// Root widget: session, the data repository, syncing, and the cart and
/// purchase basket that stage a counter transaction before it is written.
class AjJewelerApp extends StatelessWidget {
  /// The data store to run on; a fresh demo-data one when omitted (tests).
  final AppRepository? repository;
  final SessionState? session;
  final SyncService? sync;
  final ApiClient? api;
  final PushService? push;

  const AjJewelerApp({
    super.key,
    this.repository,
    this.session,
    this.sync,
    this.api,
    this.push,
  });

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        if (repository != null)
          ChangeNotifierProvider.value(value: repository!)
        else
          ChangeNotifierProvider(create: (_) => AppRepository()),
        if (api != null) Provider<ApiClient>.value(value: api!),
        if (session != null) ChangeNotifierProvider.value(value: session!),
        if (sync != null) ChangeNotifierProvider.value(value: sync!),
        if (push != null) ChangeNotifierProvider.value(value: push!),
        ChangeNotifierProvider(
          create: (context) => AppState(
            initialUser: session?.user,
            repository: context.read<AppRepository>(),
          ),
        ),
        ChangeNotifierProvider(create: (context) => CartState(context.read<AppRepository>())),
        ChangeNotifierProvider(create: (context) => PurchaseBasketState(context.read<AppRepository>())),
      ],
      child: MaterialApp(
        title: 'AJ Jeweler',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        // Held here so a tapped notification can open its record from
        // anywhere, including from the app being started by the tap.
        navigatorKey: appNavigatorKey,
        scaffoldMessengerKey: appMessengerKey,
        home: session == null ? const AppShell() : const _SessionGate(),
      ),
    );
  }
}

/// Sign-in stands in front of the shop: nothing is visible until someone has
/// proved who they are, because every record is about to name them.
class _SessionGate extends StatefulWidget {
  const _SessionGate();

  @override
  State<_SessionGate> createState() => _SessionGateState();
}

class _SessionGateState extends State<_SessionGate> {
  String? _loadedFor;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionState>();

    if (session.isRestoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!session.isSignedIn) {
      _loadedFor = null;
      return const SignInScreen();
    }

    // First frame after signing in: take the server's picture of the shop,
    // then send anything that was queued while signed out.
    final user = session.user!;
    if (_loadedFor != user.id) {
      _loadedFor = user.id;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final sync = context.read<SyncService>();
        final appState = context.read<AppState>();
        final push = pushServiceOf(context);
        appState.signedInAs(user);
        try {
          await sync.loadSnapshot();
        } catch (_) {
          // Offline: the device's own copy stands, and the queue waits.
        }
        appState.signedInAs(user);
        // This phone is registered for the signed-in person's notifications;
        // the sync carries on alongside it.
        final attach = attachPushNotifications(push);
        await sync.syncNow();
        await attach;
        // The sync may have brought a different version of this person — a
        // new role, a new branch. Take it, and keep it for the next launch.
        session.updateUser(appState.refreshSignedInUser());
      });
    }
    return const AppShell();
  }
}
