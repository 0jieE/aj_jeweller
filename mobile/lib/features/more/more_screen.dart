import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/services/export_service.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../cash/cash_ledger_screen.dart';
import '../commitment/commitment_screen.dart';
import '../customers/customers_screen.dart';
import '../disposal_history/disposal_history_screen.dart';
import '../export/export_screen.dart';
import '../gold_rate/gold_rate_reference_screen.dart';
import '../logs/transaction_logs_screen.dart';
import '../receipts/receipts_screen.dart';
import '../auth/session_actions.dart';
import '../settings/settings_screen.dart';
import '../sync/sync_status_screen.dart';
import '../users/users_screen.dart';
import '../../core/navigation/layout.dart';

/// Everything that isn't one of the five counter workflows: cash management,
/// reference tables, history, settings, and the demo-data resets.
///
/// A grid of labelled icons rather than the drawer this replaced — staff
/// recognise a destination by its tile position and shape instead of reading
/// a list, and a page can't be half-swiped open by accident mid-transaction.
class MoreScreen extends StatelessWidget {
  const MoreScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AppState>().role;

    return ReadableWidth(
      child: ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      children: [
        if (role.canManageCash) ...[
          Text('Cash Management', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          _TileGrid(
            tiles: [
              _Tile(
                label: 'Cash',
                icon: Icons.account_balance_wallet_rounded,
                color: AppColors.primaryBlue,
                onTap: () => _push(context, const CashLedgerScreen()),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
        Text('Records', style: AppTextStyles.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(
          tiles: [
            _Tile(
              label: 'Commitments',
              icon: Icons.handshake_rounded,
              color: AppColors.info,
              onTap: () => _pushTitled(context, 'Commitment', const CommitmentScreen()),
            ),
            _Tile(
              label: 'Customers',
              icon: Icons.people_alt_rounded,
              color: AppColors.primaryBlue,
              onTap: () => _push(context, const CustomersScreen()),
            ),
            _Tile(
              label: 'Transaction Logs',
              icon: Icons.history_edu_rounded,
              color: AppColors.neutral,
              onTap: () => _push(context, const TransactionLogsScreen()),
            ),
            _Tile(
              label: 'Users',
              icon: Icons.badge_rounded,
              color: AppColors.primaryBlueLight,
              onTap: () => _push(context, const UsersScreen()),
            ),
            _Tile(
              label: 'Receipts',
              icon: Icons.receipt_long_rounded,
              color: context.semanticColors.buyGreen,
              onTap: () => _push(context, const ReceiptsScreen()),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Export', style: AppTextStyles.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(
          tiles: [
            for (final kind in ExportKind.values)
              _Tile(
                label: kind.label,
                icon: kind.icon,
                color: AppColors.accentBlue,
                onTap: () => _push(context, ExportScreen(kind: kind)),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Reference', style: AppTextStyles.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(
          tiles: [
            _Tile(
              label: 'Gold & Silver Rates',
              icon: Icons.show_chart_rounded,
              color: context.semanticColors.goldDark,
              onTap: () => _push(context, const GoldRateReferenceScreen()),
            ),
            _Tile(
              label: 'Disposal History',
              icon: Icons.history_rounded,
              color: AppColors.info,
              onTap: () => _push(context, const DisposalHistoryScreen()),
            ),
            _Tile(
              label: 'Settings',
              icon: Icons.settings_rounded,
              color: AppColors.neutral,
              onTap: () => _push(context, const SettingsScreen()),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Text('Session', style: AppTextStyles.titleLarge),
        const SizedBox(height: AppSpacing.sm),
        _TileGrid(
          tiles: [
            _Tile(
              label: 'Sync',
              icon: Icons.sync_rounded,
              color: AppColors.accentBlue,
              onTap: () => _push(context, const SyncStatusScreen()),
            ),
            _Tile(
              label: 'Notifications',
              icon: Icons.notifications_active_rounded,
              color: AppColors.info,
              onTap: () => showNotificationsDialog(context),
            ),
            _Tile(
              label: 'Change PIN',
              icon: Icons.password_rounded,
              color: AppColors.primaryBlue,
              onTap: () => showChangePinDialog(context),
            ),
            _Tile(
              label: 'Sign Out',
              icon: Icons.logout_rounded,
              color: AppColors.danger,
              onTap: () => confirmSignOut(context),
            ),
            if (role.canManageUsers)
              _Tile(
                label: 'Send Data to Server',
                icon: Icons.cloud_upload_rounded,
                color: AppColors.neutral,
                onTap: () => showImportDialog(context),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'The shop\'s records live on the server. This phone keeps its own copy so '
          'the counter keeps working when the connection does not.',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
      ),
    );
  }

  void _push(BuildContext context, Widget screen) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  /// Tab content expects the shell's app bar, so opening one as its own route
  /// has to supply the title and back button it would otherwise inherit.
  void _pushTitled(BuildContext context, String title, Widget body) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(appBar: AppBar(title: Text(title)), body: body),
      ),
    );
  }


}

class _Tile {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _Tile({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });
}

/// Three across — wide enough for a thumb, narrow enough that a destination
/// keeps a stable position in the grid as the role changes what's available.
class _TileGrid extends StatelessWidget {
  final List<_Tile> tiles;

  const _TileGrid({required this.tiles});

  @override
  Widget build(BuildContext context) {
    // Three across a phone, more across a desktop — but each tile the same
    // size either way, rather than three tiles stretched over a monitor.
    return GridView.extent(
      maxCrossAxisExtent: 148,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpacing.xs,
      crossAxisSpacing: AppSpacing.xs,
      childAspectRatio: 1.2,
      children: [for (final tile in tiles) _GridTile(tile: tile)],
    );
  }
}

class _GridTile extends StatelessWidget {
  final _Tile tile;

  const _GridTile({required this.tile});

  @override
  Widget build(BuildContext context) {
    // Icon and label only, like a phone's home screen — no card around it.
    return InkWell(
      onTap: tile.onTap,
      borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs, vertical: AppSpacing.xs),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                color: tile.color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(tile.icon, color: tile.color, size: 24),
            ),
            const SizedBox(height: 6),
            Text(
              tile.label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.labelSmall.copyWith(color: AppColors.textPrimary),
            ),
          ],
        ),
      ),
    );
  }
}
