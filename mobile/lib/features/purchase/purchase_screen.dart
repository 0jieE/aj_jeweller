import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import 'new_purchase_screen.dart';
import 'purchase_list_screen.dart';
import 'verification_queue_screen.dart';
import '../../core/navigation/layout.dart';

enum _PurchaseView { list, queue }

/// Root of the Purchase tab. Everyone can browse the list; the "Verify"
/// segment (a Cashier's cash-release queue) only shows up for roles that
/// can move cash, and the "New Purchase" FAB only for roles that can encode
/// purchases — strict separation of duties, driven entirely by [AppState].
class PurchaseScreen extends StatefulWidget {
  const PurchaseScreen({super.key});

  @override
  State<PurchaseScreen> createState() => _PurchaseScreenState();
}

class _PurchaseScreenState extends State<PurchaseScreen> {
  _PurchaseView? _view;

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AppState>().role;
    final canQueue = role.canMoveCash;
    final canCreate = role.canEncodePurchases;

    // Cashiers land on their queue by default; everyone else lands on the
    // browsable list.
    final view = _view ?? (canQueue && !canCreate ? _PurchaseView.queue : _PurchaseView.list);

    return Scaffold(
      body: ReadableWidth(
        child: Column(
          children: [
            if (canQueue)
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
                child: _ViewToggle(
                  view: view,
                  onChanged: (v) => setState(() => _view = v),
                ),
              ),
            Expanded(
              child: view == _PurchaseView.list
                  ? const PurchaseListScreen()
                  : const VerificationQueueScreen(),
            ),
          ],
        ),
      ),
      floatingActionButton: (canCreate && view == _PurchaseView.list)
          ? FloatingActionButton.extended(
              // Unique per tab — every tab stays mounted in the shell's
              // IndexedStack, so sharing the default hero tag across FABs
              // breaks the moment any route transitions.
              heroTag: 'purchase-new-fab',
              onPressed: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NewPurchaseScreen()),
                );
              },
              icon: const Icon(Icons.add_rounded),
              label: const Text('New Purchase'),
            )
          : null,
    );
  }
}

class _ViewToggle extends StatelessWidget {
  final _PurchaseView view;
  final ValueChanged<_PurchaseView> onChanged;

  const _ViewToggle({required this.view, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Row(
        children: [
          Expanded(child: _segment(context, 'Purchase List', _PurchaseView.list)),
          Expanded(child: _segment(context, 'Verify & Release', _PurchaseView.queue)),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, _PurchaseView value) {
    final selected = view == value;
    return GestureDetector(
      onTap: () => onChanged(value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
        decoration: BoxDecoration(
          color: selected ? AppColors.cardSurface : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius - 2),
          boxShadow: selected
              ? [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 4, offset: const Offset(0, 1))]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: AppTextStyles.bodyMedium.copyWith(
            color: selected ? AppColors.primaryBlue : AppColors.textSecondary,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
