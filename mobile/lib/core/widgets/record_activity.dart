import 'package:flutter/material.dart';

import '../data/staff_directory.dart';
import '../models/app_user.dart';
import '../models/transaction_log.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'formatters.dart';

/// "Encoded by Liza Mendoza · Assistant Appraiser" — one named person against
/// one step of a record.
class AttributionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? userId;
  final DateTime? at;

  /// Shown when nobody has done this step yet, e.g. "Not yet released".
  final String pendingText;

  const AttributionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.userId,
    this.at,
    this.pendingText = '—',
  });

  @override
  Widget build(BuildContext context) {
    final AppUser? user = StaffDirectory.byId(userId);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppColors.textSecondary),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ),
          if (user == null)
            Expanded(
              child: Text(
                pendingText,
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textDisabled),
              ),
            )
          else ...[
            StaffAvatar(user: user, radius: 10),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: user.name,
                      style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: ' · ${user.role.label}'
                          '${at == null ? '' : ' · ${AppFormat.dateTimeShort(at!)}'}',
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Who handled a record, one named person per step.
class AccountabilityCard extends StatelessWidget {
  final List<Widget> children;

  const AccountabilityCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(children: children),
    );
  }
}

/// A staff member's initials in a small circle.
class StaffAvatar extends StatelessWidget {
  final AppUser user;
  final double radius;

  const StaffAvatar({super.key, required this.user, this.radius = 14});

  @override
  Widget build(BuildContext context) {
    return CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primaryBlue.withValues(alpha: 0.12),
      child: Text(
        user.initials,
        style: AppTextStyles.labelSmall.copyWith(
          color: AppColors.primaryBlue,
          fontSize: radius * 0.8,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

/// The colour an action's category is drawn in, everywhere logs appear.
Color logCategoryColor(BuildContext context, LogCategory category) {
  final sc = context.semanticColors;
  switch (category) {
    case LogCategory.purchase:
      return sc.buyGreen;
    case LogCategory.sale:
      return sc.sellCoral;
    case LogCategory.scrap:
      return sc.danger;
    case LogCategory.cash:
      return AppColors.primaryBlue;
    case LogCategory.admin:
      return AppColors.neutral;
  }
}

/// A record's own history, oldest first: every recorded step, who took it,
/// and what an edit changed.
///
/// The same entries the Transaction Logs page shows, narrowed to one record —
/// so "who touched this, and when?" is answerable from the record itself.
class RecordActivityList extends StatelessWidget {
  final List<TransactionLog> entries;

  const RecordActivityList({super.key, required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Text(
        'Nothing recorded against this yet.',
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _ActivityEntry(entry: entries[i]),
          ],
        ],
      ),
    );
  }
}

class _ActivityEntry extends StatelessWidget {
  final TransactionLog entry;

  const _ActivityEntry({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = logCategoryColor(context, entry.action.category);

    return Padding(
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
            ),
            child: Icon(entry.action.icon, size: 16, color: color),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.action.label,
                  style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.w700),
                ),
                Text(entry.summary, style: AppTextStyles.bodyMedium),
                const SizedBox(height: 2),
                Text(
                  '${entry.userName} · ${entry.role.label} · ${AppFormat.dateTimeShort(entry.at)}',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
                if (entry.changes.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.xs),
                  FieldChangeTable(changes: entry.changes),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Before → after, one line per field.
class FieldChangeTable extends StatelessWidget {
  final List<FieldChange> changes;

  const FieldChangeTable({super.key, required this.changes});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final change in changes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    change.field,
                    style: AppTextStyles.caption.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    children: [
                      Text(
                        change.before,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: AppColors.textSecondary,
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                      const Icon(Icons.arrow_forward_rounded, size: 13, color: AppColors.textSecondary),
                      Text(
                        change.after,
                        style: AppTextStyles.bodyMedium.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
