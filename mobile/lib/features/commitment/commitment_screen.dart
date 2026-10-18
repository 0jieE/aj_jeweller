import 'package:flutter/material.dart';

import 'commitment_list_screen.dart';

/// Root of the Commitment tab. Primarily an Admin screen, but browsing is
/// open to everyone — only creating a commitment and recording cash
/// received are role-gated (inside the list/detail screens).
class CommitmentScreen extends StatelessWidget {
  const CommitmentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const CommitmentListScreen();
  }
}
