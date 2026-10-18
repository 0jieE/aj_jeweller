import 'package:flutter/material.dart';

import '../../core/widgets/coming_soon.dart';

/// Placeholder — real settings (branch config, printer setup, etc.) arrive
/// once this moves past prototype.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: const ComingSoon(
        icon: Icons.settings_outlined,
        title: 'Settings',
        message: 'App configuration will live here once this moves past prototype.',
      ),
    );
  }
}
