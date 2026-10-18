import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../features/sync/sync_status_screen.dart';
import '../data/app_repository.dart';
import '../models/app_user.dart';
import '../models/branch.dart';
import '../state/app_state.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// User and branch pickers, sat in the app bar.
///
/// Picking a person is the prototype's stand-in for signing in as them — and
/// it is a person, not a bare role, because every record now names who made
/// it. Both pickers get switched constantly while the app is being
/// demonstrated, so they sit one tap away; both disappear once real sign-in
/// arrives, which is why nothing else is built around where they sit.
class SessionSwitchers extends StatelessWidget {
  const SessionSwitchers({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    // Rebuild when staff are added, edited, or deactivated.
    context.watch<AppRepository>();

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SyncStatusChip(),
        _SignedInChip(user: appState.currentUser),
        const SizedBox(width: AppSpacing.xs),
        if (appState.role.canViewAllBranches)
          _SessionChip<BranchId>(
            icon: Icons.storefront_outlined,
            label: appState.selectedBranch?.label ?? 'Both',
            selected: appState.selectedBranch,
            options: [
              for (final branch in BranchId.values) _ChipOption(branch, branch.label),
              const _ChipOption<BranchId>(null, 'Both branches'),
            ],
            onSelected: (branch) => context.read<AppState>().setBranch(branch),
          )
        else
          _BranchLabel(branch: appState.selectedBranch),
        const SizedBox(width: AppSpacing.sm),
      ],
    );
  }
}

/// One selectable value, boxed alongside its label.
///
/// The box matters: a [PopupMenuButton] can't tell a popped `null` from a
/// dismissed menu, so a bare-null "Both branches" entry would silently do
/// nothing when chosen.
class _ChipOption<T> {
  final T? value;
  final String label;

  const _ChipOption(this.value, this.label);
}

class _SessionChip<T> extends StatelessWidget {
  final IconData icon;
  final String label;
  final T? selected;
  final List<_ChipOption<T>> options;
  final ValueChanged<T?> onSelected;

  const _SessionChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.options,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;

    return PopupMenuButton<_ChipOption<T>>(
      tooltip: '',
      position: PopupMenuPosition.under,
      onSelected: (option) => onSelected(option.value),
      itemBuilder: (_) => [
        for (final option in options)
          PopupMenuItem<_ChipOption<T>>(
            value: option,
            child: Row(
              children: [
                Icon(
                  option.value == selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_off_rounded,
                  size: 18,
                  color: option.value == selected
                      ? Theme.of(context).colorScheme.primary
                      : Theme.of(context).disabledColor,
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(option.label),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: 6),
        decoration: BoxDecoration(
          color: onPrimary.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: onPrimary),
            const SizedBox(width: 4),
            Text(
              label,
              style: AppTextStyles.labelSmall.copyWith(
                color: onPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: onPrimary),
          ],
        ),
      ),
    );
  }
}


/// Who is signed in. Not a picker any more: the person is whoever typed
/// their PIN, and only signing out changes it.
class _SignedInChip extends StatelessWidget {
  final AppUser user;

  const _SignedInChip({required this.user});

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 3, AppSpacing.sm, 3),
      decoration: BoxDecoration(
        color: onPrimary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 11,
            backgroundColor: onPrimary,
            child: Text(
              user.initials,
              style: AppTextStyles.labelSmall.copyWith(
                fontSize: 9,
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                user.firstName,
                style: AppTextStyles.labelSmall.copyWith(color: onPrimary, fontWeight: FontWeight.w700),
              ),
              Text(
                user.role.shortLabel,
                style: AppTextStyles.labelSmall.copyWith(color: onPrimary.withValues(alpha: 0.7), fontSize: 9),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A branch member's own branch, stated rather than offered.
class _BranchLabel extends StatelessWidget {
  final BranchId? branch;

  const _BranchLabel({required this.branch});

  @override
  Widget build(BuildContext context) {
    final onPrimary = Theme.of(context).colorScheme.onPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.storefront_outlined, size: 14, color: onPrimary.withValues(alpha: 0.8)),
          const SizedBox(width: 4),
          Text(
            branch?.label ?? 'Both',
            style: AppTextStyles.labelSmall.copyWith(color: onPrimary),
          ),
        ],
      ),
    );
  }
}

