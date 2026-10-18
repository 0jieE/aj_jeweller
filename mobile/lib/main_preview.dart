// A preview of the app with nobody signed in and no server: the demo shop,
// straight into the shell. For looking at layout — on a monitor, on a phone,
// at any window size — without needing the shop's server or someone's PIN.
//
//     flutter run -t lib/main_preview.dart -d chrome
//     flutter build web -t lib/main_preview.dart --output build/web-preview
//
// It is never what ships: `flutter build apk` and `flutter build web` both
// use main.dart, which signs in properly and talks to the server.

import 'package:flutter/material.dart';

import 'main.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AjJewelerApp());
}
