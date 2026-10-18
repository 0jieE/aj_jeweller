import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../disposal_history/disposal_history_screen.dart';
import 'disposal_selection_screen.dart';
import 'scrap_inventory_screen.dart';
import '../../core/navigation/layout.dart';

enum _ScrapView { gold, silver, history }

/// Root of the Dispose tab: gold scrap and silver waiting to be disposed, each
/// in its own list, plus past disposal batches — with the "start a new batch"
/// action gated to Admin, the only role that runs disposal. A batch is one
/// metal, so the button starts a batch of whichever list is open.
class ScrapScreen extends StatefulWidget {
  const ScrapScreen({super.key});

  @override
  State<ScrapScreen> createState() => _ScrapScreenState();
}

class _ScrapScreenState extends State<ScrapScreen> {
  _ScrapView _view = _ScrapView.gold;

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AppState>().role;

    return Scaffold(
      body: ReadableWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
              child: _ViewToggle(view: _view, onChanged: (v) => setState(() => _view = v)),
            ),
            Expanded(
              child: switch (_view) {
                _ScrapView.gold => const ScrapInventoryScreen(key: ValueKey('gold')),
                _ScrapView.silver => const ScrapInventoryScreen(key: ValueKey('silver'), silver: true),
                _ScrapView.history => const DisposalHistoryScreen(),
              },
            ),
          ],
        ),
      ),
      floatingActionButton: (role.canRunDisposal && _view != _ScrapView.history)
          ? FloatingActionButton.extended(
              // Unique per tab — every tab stays mounted in the shell's
              // IndexedStack, so sharing the default hero tag across FABs
              // breaks the moment any route transitions.
              heroTag: 'scrap-new-disposal-fab',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => DisposalSelectionScreen(silver: _view == _ScrapView.silver),
                ),
              ),
              icon: const Icon(Icons.delete_sweep_rounded),
              label: Text(_view == _ScrapView.silver ? 'Dispose Silver' : 'Dispose Gold Scrap'),
            )
          : null,
    );
  }
}

class _ViewToggle extends StatelessWidget {
  final _ScrapView view;
  final ValueChanged<_ScrapView> onChanged;

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
          Expanded(child: _segment(context, 'Gold', _ScrapView.gold)),
          Expanded(child: _segment(context, 'Silver', _ScrapView.silver)),
          Expanded(child: _segment(context, 'History', _ScrapView.history)),
        ],
      ),
    );
  }

  Widget _segment(BuildContext context, String label, _ScrapView value) {
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
