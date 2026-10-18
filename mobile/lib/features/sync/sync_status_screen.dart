import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/api/api_config.dart';
import '../../core/state/session_state.dart';
import '../../core/sync/outbox.dart';
import '../../core/sync/sync_service.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';

/// What the phone still owes the server, what the server refused, and when
/// the two last agreed.
class SyncStatusScreen extends StatelessWidget {
  const SyncStatusScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncService>();
    final refusals = sync.refusals;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Sync'),
        actions: [
          IconButton(
            tooltip: 'Sync now',
            onPressed: () => sync.syncNow(),
            icon: const Icon(Icons.sync_rounded),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          _StatusCard(sync: sync),
          const SizedBox(height: AppSpacing.md),
          if (sync.pendingCount > 0) ...[
            Text('Waiting to send (${sync.pendingCount})', style: AppTextStyles.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Container(
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < sync.outbox.pending.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.schedule_rounded, size: 18, color: AppColors.textSecondary),
                      title: Text(sync.outbox.pending[i].summary, style: AppTextStyles.bodyMedium),
                      subtitle: Text(
                        AppFormat.dateTimeShort(sync.outbox.pending[i].recordedAt),
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: AppSpacing.md),
          ],
          Row(
            children: [
              Expanded(child: Text('Refused changes (${refusals.length})', style: AppTextStyles.titleMedium)),
              if (refusals.isNotEmpty)
                TextButton(onPressed: sync.clearRefusals, child: const Text('Clear all')),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          if (refusals.isEmpty)
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                border: Border.all(color: AppColors.outline),
              ),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, color: context.semanticColors.success, size: 18),
                  const SizedBox(width: AppSpacing.sm),
                  const Expanded(child: Text('Nothing has been refused.')),
                ],
              ),
            )
          else
            for (final refusal in refusals) ...[
              _RefusalCard(refusal: refusal),
              const SizedBox(height: AppSpacing.sm),
            ],
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Server: ${ApiConfig.baseUrl}',
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.textDisabled),
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  final SyncService sync;

  const _StatusCard({required this.sync});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final (icon, color, label) = switch (sync.phase) {
      SyncPhase.idle when sync.pendingCount == 0 => (Icons.cloud_done_rounded, sc.success, 'Everything is sent'),
      SyncPhase.idle => (Icons.cloud_upload_outlined, sc.warning, '${sync.pendingCount} waiting to send'),
      SyncPhase.loading => (Icons.cloud_download_outlined, AppColors.primaryBlue, 'Loading from the server'),
      SyncPhase.pushing => (Icons.cloud_upload_rounded, AppColors.primaryBlue, 'Sending your changes'),
      SyncPhase.pulling => (Icons.cloud_download_rounded, AppColors.primaryBlue, 'Taking the latest'),
      SyncPhase.offline => (Icons.cloud_off_rounded, sc.warning, 'Offline — your work is saved here'),
      SyncPhase.failed => (Icons.error_outline_rounded, sc.danger, 'Sync could not finish'),
    };

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  sync.lastSyncedAt == null
                      ? 'Not synced yet'
                      : 'Last synced ${AppFormat.dateTimeShort(sync.lastSyncedAt!)}',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
                if (sync.error != null)
                  Text(
                    sync.error!,
                    style: AppTextStyles.caption.copyWith(color: sc.danger),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RefusalCard extends StatelessWidget {
  final SyncRefusal refusal;

  const _RefusalCard({required this.refusal});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final sync = context.read<SyncService>();
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(
          color: refusal.acknowledged ? AppColors.outline : sc.danger.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.report_problem_outlined, size: 18, color: sc.danger),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  refusal.operation.summary,
                  style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (!refusal.acknowledged)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(
                    color: sc.danger.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                  ),
                  child: Text('NEW', style: AppTextStyles.labelSmall.copyWith(color: sc.danger, fontSize: 10)),
                ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(refusal.message, style: AppTextStyles.bodyMedium),
          const SizedBox(height: 4),
          Text(
            'Made ${AppFormat.dateTimeShort(refusal.operation.recordedAt)} · '
            'refused ${AppFormat.dateTimeShort(refusal.refusedAt)}',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'The server did not take this change. Your phone still shows it until the '
            'next sync brings the server\'s version.',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          if (!refusal.acknowledged)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => sync.acknowledgeRefusal(refusal.operation.key),
                child: const Text('Got it'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The small pill in the app bar: pending count, or a refusal warning.
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({super.key});

  /// Null where there is no server wired up — tests and the plain local
  /// build still run the shell without a session.
  static T? _maybe<T>(BuildContext context) {
    try {
      return context.watch<T>();
    } on ProviderNotFoundException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = _maybe<SyncService>(context);
    final session = _maybe<SessionState>(context);
    if (sync == null || session == null || !session.isSignedIn) return const SizedBox.shrink();

    final sc = context.semanticColors;
    final refused = sync.unseenRefusalCount;
    final (icon, color) = refused > 0
        ? (Icons.report_problem_rounded, sc.danger)
        : switch (sync.phase) {
            SyncPhase.offline => (Icons.cloud_off_rounded, Colors.white),
            SyncPhase.failed => (Icons.sync_problem_rounded, sc.danger),
            SyncPhase.pushing || SyncPhase.pulling || SyncPhase.loading => (Icons.sync_rounded, Colors.white),
            _ => (sync.pendingCount > 0 ? Icons.cloud_upload_outlined : Icons.cloud_done_outlined, Colors.white),
          };
    final count = refused > 0 ? refused : sync.pendingCount;

    return IconButton(
      tooltip: 'Sync',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const SyncStatusScreen()),
      ),
      icon: Badge(
        isLabelVisible: count > 0,
        backgroundColor: refused > 0 ? sc.danger : AppColors.accentBlue,
        label: Text('$count'),
        child: Icon(icon, color: color, size: 20),
      ),
    );
  }
}
