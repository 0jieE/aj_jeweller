import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/cash_entry.dart';
import '../../core/models/gold_rate.dart';
import '../../core/models/item_status.dart';
import '../../core/models/purchase_batch.dart';
import '../../core/models/sale.dart';
import '../../core/models/user_role.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/inventory_item_tile.dart';
import '../../core/widgets/status_badges.dart';
import '../cash/cash_ledger_screen.dart';
import '../commitment/commitment_screen.dart';
import '../gold_rate/gold_rate_reference_screen.dart';
import '../purchase/lot_detail_screen.dart';
import '../purchase/new_purchase_screen.dart';
import '../purchase/purchase_batch_detail_screen.dart';
import '../purchase/verification_queue_screen.dart';
import '../scrap/disposal_selection_screen.dart';
import '../scrap/scrap_inventory_screen.dart';
import '../sell/sale_verification_detail_screen.dart';
import '../sell/sale_verification_queue_screen.dart';

/// When any rate was last set.
DateTime _latestRateUpdate(List<GoldRate> rates) => rates.isEmpty
    ? DateTime.now()
    : rates.map((r) => r.updatedAt).reduce((a, b) => a.isAfter(b) ? a : b);

/// The role-aware landing screen: whatever needs the current user's action
/// leads, then branch cash position, quick entry, every gold and silver rate
/// at a glance, and today's activity at the bottom.
class DashboardScreen extends StatelessWidget {
  final ValueChanged<int>? onNavigateToTab;

  const DashboardScreen({super.key, this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final branchId = appState.selectedBranch;

    return RefreshIndicator(
      onRefresh: () async {},
      child: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.md,
          AppSpacing.xl,
        ),
        children: [
          _NeedsActionSection(role: appState.role, branchId: branchId),
          const SizedBox(height: AppSpacing.lg),
          Text('Branch Position', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          if (branchId == null)
            Column(
              children: [
                for (final b in repo.branches) ...[
                  _BranchPositionCard(branch: repo.branch(b.id)),
                  const SizedBox(height: AppSpacing.sm),
                ],
              ],
            )
          else
            _BranchPositionCard(branch: repo.branch(branchId)),
          const SizedBox(height: AppSpacing.lg),
          Text('Quick Entry', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          _QuickEntryGrid(role: appState.role, onNavigateToTab: onNavigateToTab),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Gold & Silver Rates', style: AppTextStyles.titleLarge),
              Text(
                AppFormat.dateTimeShort(_latestRateUpdate([...repo.goldRates, ...repo.silverRates])),
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          _RateSummary(gold: repo.goldRates, silver: repo.silverRates),
          const SizedBox(height: AppSpacing.lg),
          Text("Today's Activity", style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          _TodaysActivityCard(branchId: branchId),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Needs-action section — the whole point of the dashboard.
// ---------------------------------------------------------------------------
class _NeedsActionSection extends StatelessWidget {
  final AppUserRole role;
  final BranchId? branchId;

  const _NeedsActionSection({required this.role, required this.branchId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();

    // The counter's work first — anyone at the branch may do it, so an
    // absence never leaves a customer waiting — then whatever of your own is
    // still waiting on someone else.
    if (role != AppUserRole.admin) {
      return Column(
        children: [
          _counterCard(context, repo),
          if (_hasSubmissions(repo)) ...[
            const SizedBox(height: AppSpacing.md),
            _submissionsCard(context, repo),
          ],
        ],
      );
    }

    {
      // Admin: the branch at a glance rather than a queue to work through.
      final repoAll = repo;
      final pending = repoAll.itemsForBranch(branchId).where((i) => i.itemStatus == ItemStatus.pending).length;
      final awaitingVerification = repoAll
          .itemsForBranch(branchId)
          .where((i) => i.verificationStatus == VerificationStatus.awaitingVerification)
          .length;
      final forDisposal = repoAll.itemsForDisposal(branchId: branchId).length;
      final salesAwaiting = repoAll.salesAwaitingPayment(branchId: branchId).length;
      return _ActionCard(
        title: 'Overview',
        icon: Icons.dashboard_customize_outlined,
        child: Row(
          children: [
            Expanded(
              child: _StatChip(
                label: 'Pending items',
                value: '$pending',
                onTap: () => _pushStandalone(context, 'Verify & Release', const VerificationQueueScreen()),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatChip(
                label: 'Unverified',
                value: '$awaitingVerification',
                onTap: () => _pushStandalone(context, 'Verify & Release', const VerificationQueueScreen()),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatChip(
                label: 'For disposal',
                value: '$forDisposal',
                onTap: () => _pushStandalone(context, 'Scrap Inventory', const ScrapInventoryScreen()),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: _StatChip(
                label: 'Sales pending',
                value: '$salesAwaiting',
                onTap: () => _pushStandalone(context, 'Verify & Receive', const SaleVerificationQueueScreen()),
              ),
            ),
          ],
        ),
      );
    }
  }

  bool _hasSubmissions(AppRepository repo) =>
      repo.itemsAwaitingVerificationFor(role, branchId: branchId).isNotEmpty ||
      repo.salesAwaitingVerificationFor(role, branchId: branchId).isNotEmpty;

  /// What the counter owes a customer right now: cash to hand over, payment
  /// to take. Shown to every branch role, because any of them may do it.
  Widget _counterCard(BuildContext context, AppRepository repo) {
    final purchases = repo.purchaseBatchesAwaitingRelease(branchId: branchId);
    final sales = repo.salesAwaitingPayment(branchId: branchId);
    return _ActionCard(
      title: 'Needs Your Action',
      icon: Icons.point_of_sale_rounded,
      child: (purchases.isEmpty && sales.isEmpty)
          ? const EmptyState(
              title: "You're all caught up",
              message: 'No purchases or sales waiting on cash.',
            )
          : Column(
              children: [
                if (purchases.isNotEmpty)
                  _SubList(
                    label: 'Purchases awaiting cash release (${purchases.length})',
                    children: [
                      for (final batch in purchases.take(4))
                        _BatchTile(
                          batch: batch,
                          itemCount: repo.itemsInBatch(batch.id).length,
                          totalCentavos: repo.batchTotalCentavos(batch.id),
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (_) => PurchaseBatchDetailScreen(batchId: batch.id),
                            ),
                          ),
                        ),
                    ],
                  ),
                if (sales.isNotEmpty)
                  _SubList(
                    label: 'Sales awaiting payment (${sales.length})',
                    children: [
                      for (final sale in sales.take(4))
                        _SaleTile(
                          sale: sale,
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => SaleVerificationDetailScreen(saleId: sale.id)),
                          ),
                        ),
                    ],
                  ),
              ],
            ),
    );
  }

  /// Your own work, still waiting on somebody else.
  Widget _submissionsCard(BuildContext context, AppRepository repo) {
    final items = repo.itemsAwaitingVerificationFor(role, branchId: branchId);
    final sales = repo.salesAwaitingVerificationFor(role, branchId: branchId);
    return _ActionCard(
      title: 'Your Submissions',
      icon: Icons.fact_check_outlined,
      child: Column(
        children: [
          if (items.isNotEmpty)
            _SubList(
              label: 'Awaiting verification (${items.length})',
              children: [
                for (final item in items.take(4))
                  InventoryItemTile(
                    item: item,
                    showVerification: true,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: item.id)),
                    ),
                  ),
              ],
            ),
          if (sales.isNotEmpty)
            _SubList(
              label: 'Sales awaiting verification (${sales.length})',
              children: [
                for (final sale in sales.take(4))
                  _SaleTile(
                    sale: sale,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => SaleVerificationDetailScreen(saleId: sale.id)),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  const _ActionCard({required this.title, required this.icon, required this.child});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: AppColors.primaryBlue, size: 20),
                const SizedBox(width: AppSpacing.sm),
                Text(title, style: AppTextStyles.titleLarge),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            child,
          ],
        ),
      ),
    );
  }
}

class _SubList extends StatelessWidget {
  final String label;
  final List<Widget> children;

  const _SubList({required this.label, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: 2),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surfaceDim,
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
            ),
            child: Column(children: children),
          ),
        ],
      ),
    );
  }
}

class _SaleTile extends StatelessWidget {
  final Sale sale;
  final VoidCallback? onTap;

  const _SaleTile({required this.sale, this.onTap});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: TransactionCustomerAvatar(customer: sale.customer, radius: 18),
      title: Text(sale.customerName, style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600)),
      subtitle: Text(
        '${sale.lineItems.length} item(s) · ${sale.payment.label}',
        style: AppTextStyles.bodyMedium,
      ),
      trailing: Text(
        AppFormat.peso(sale.totalAmountCentavos, whole: true),
        style: AppTextStyles.numericMedium,
      ),
    );
  }
}

class _BatchTile extends StatelessWidget {
  final PurchaseBatch batch;
  final int itemCount;
  final int totalCentavos;
  final VoidCallback? onTap;

  const _BatchTile({
    required this.batch,
    required this.itemCount,
    required this.totalCentavos,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      onTap: onTap,
      leading: TransactionCustomerAvatar(customer: batch.customer, radius: 18),
      title: Text(
        batch.customer.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text('$itemCount item(s) · ${batch.id}', style: AppTextStyles.bodyMedium),
      trailing: Text(
        AppFormat.peso(totalCentavos, whole: true),
        style: AppTextStyles.numericMedium,
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback? onTap;

  const _StatChip({required this.label, required this.value, this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm, horizontal: AppSpacing.xs),
        decoration: BoxDecoration(
          color: AppColors.surfaceDim,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          border: onTap != null ? Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.15)) : null,
        ),
        child: Column(
          children: [
            Text(value, style: AppTextStyles.numericLarge.copyWith(fontSize: 20, color: AppColors.primaryBlue)),
            const SizedBox(height: 2),
            Text(
              label,
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// Pushes a tab's embedded content (which normally relies on the shell's
/// own AppBar) as its own standalone screen — used when the Dashboard
/// links straight into a specific queue rather than just switching tabs.
void _pushStandalone(BuildContext context, String title, Widget body) {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: body,
      ),
    ),
  );
}

// ---------------------------------------------------------------------------
// Branch cash position.
// ---------------------------------------------------------------------------
class _BranchPositionCard extends StatelessWidget {
  final Branch branch;

  const _BranchPositionCard({required this.branch});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final repo = context.watch<AppRepository>();
    // Derived from live inventory, not stored figures — the same queries the
    // Dispose tab's headers use, so the two can never drift apart.
    final pendingScrapCentavos = repo
        .itemsForDisposal(branchId: branch.id)
        .fold<int>(0, (sum, i) => sum + i.effectiveRemainingAmountCentavos);
    final silverOnHandCentavos = repo
        .itemsForDisposal(branchId: branch.id, silver: true)
        .fold<int>(0, (sum, i) => sum + i.effectiveRemainingAmountCentavos);

    // Every balance is the cash ledger's — see AppRepository.accountBalance.
    final balances = {for (final a in CashAccount.values) a: repo.accountBalance(branch.id, a)};
    final flows = {for (final a in CashAccount.values) a: repo.cashFlowOn(branch.id, a)};
    final total = balances.values.fold<int>(0, (s, v) => s + v);
    final todayNet = flows.values.fold<int>(0, (s, f) => s + f.inCentavos - f.outCentavos);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.storefront_outlined, size: 18, color: AppColors.textSecondary),
                const SizedBox(width: 6),
                Expanded(child: Text(branch.name, style: AppTextStyles.titleMedium)),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            // The branch's money across all three sources, and how today moved it.
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Total cash', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerLeft,
                        child: Text(
                          AppFormat.peso(total),
                          style: AppTextStyles.numericLarge.copyWith(color: AppColors.primaryBlue),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Today', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                    Text(
                      todayNet == 0 ? '₱0' : AppFormat.pesoSigned(todayNet),
                      style: AppTextStyles.numericMedium.copyWith(
                        color: todayNet > 0 ? sc.success : (todayNet < 0 ? sc.danger : AppColors.textSecondary),
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final a in CashAccount.values) ...[
                  if (a != CashAccount.values.first) const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: _CashSourceTile(
                      account: a,
                      balance: balances[a]!,
                      todayIn: flows[a]!.inCentavos,
                      todayOut: flows[a]!.outCentavos,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            const Divider(height: 1),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _MiniStat(
                    label: 'Pending scrap',
                    value: AppFormat.peso(pendingScrapCentavos, whole: true),
                    color: sc.gold,
                  ),
                ),
                Expanded(
                  child: _MiniStat(
                    label: 'Silver on hand',
                    value: AppFormat.peso(silverOnHandCentavos, whole: true),
                    color: AppColors.silverDark,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One cash source: its balance, and today's money in and out of it.
class _CashSourceTile extends StatelessWidget {
  final CashAccount account;
  final int balance;
  final int todayIn;
  final int todayOut;

  const _CashSourceTile({
    required this.account,
    required this.balance,
    required this.todayIn,
    required this.todayOut,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final color = accountColor(context, account);
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: color.withValues(alpha: 0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              account.label,
              style: AppTextStyles.labelSmall.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 2),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              AppFormat.peso(balance, whole: true),
              style: AppTextStyles.numericMedium.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 4),
          Divider(height: 1, color: color.withValues(alpha: 0.2)),
          const SizedBox(height: 4),
          Text('Today', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary, fontSize: 10.5)),
          _FlowLine(
            icon: Icons.south_west_rounded,
            amount: todayIn,
            color: todayIn > 0 ? sc.success : AppColors.textDisabled,
          ),
          _FlowLine(
            icon: Icons.north_east_rounded,
            amount: todayOut,
            color: todayOut > 0 ? sc.danger : AppColors.textDisabled,
          ),
        ],
      ),
    );
  }
}

class _FlowLine extends StatelessWidget {
  final IconData icon;
  final int amount;
  final Color color;

  const _FlowLine({required this.icon, required this.amount, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 3),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              AppFormat.peso(amount, whole: true),
              style: AppTextStyles.numericSmall.copyWith(color: color, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ],
    );
  }
}

class _MiniStat extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniStat({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppTextStyles.numericMedium.copyWith(color: color)),
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Today's activity.
// ---------------------------------------------------------------------------
class _TodaysActivityCard extends StatelessWidget {
  final BranchId? branchId;

  const _TodaysActivityCard({required this.branchId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final purchases = repo.purchasesToday(branchId: branchId);
    final sales = repo.salesToday(branchId: branchId);
    final purchasesTotal = purchases.fold<int>(0, (s, i) => s + i.capitalAmountCentavos);
    final salesTotal = sales.fold<int>(0, (s, sale) => s + sale.totalAmountCentavos);
    final net = repo.todaysNetCentavos(branchId: branchId);
    final sc = context.semanticColors;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Row(
          children: [
            Expanded(
              child: _ActivityStat(
                label: 'Purchases',
                count: purchases.length,
                amount: AppFormat.peso(purchasesTotal, whole: true),
                color: sc.buyGreen,
              ),
            ),
            Container(width: 1, height: 40, color: AppColors.outline),
            Expanded(
              child: _ActivityStat(
                label: 'Sales',
                count: sales.length,
                amount: AppFormat.peso(salesTotal, whole: true),
                color: sc.sellCoral,
              ),
            ),
            Container(width: 1, height: 40, color: AppColors.outline),
            Expanded(
              child: _ActivityStat(
                label: 'Net',
                count: null,
                amount: AppFormat.pesoSigned(net),
                color: net >= 0 ? sc.success : sc.danger,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ActivityStat extends StatelessWidget {
  final String label;
  final int? count;
  final String amount;
  final Color color;

  const _ActivityStat({
    required this.label,
    required this.count,
    required this.amount,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          count != null ? '$label ($count)' : label,
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          amount,
          style: AppTextStyles.numericMedium.copyWith(color: color),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Rate summary — every gold karat and silver fineness in one box, laid out to
// fit the width so the whole table reads without scrolling. Tapping opens the
// full rates page.
// ---------------------------------------------------------------------------
class _RateSummary extends StatelessWidget {
  final List<GoldRate> gold;
  final List<GoldRate> silver;

  const _RateSummary({required this.gold, required this.silver});

  static const _perRow = 4;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.cardSurface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        side: const BorderSide(color: AppColors.outline),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const GoldRateReferenceScreen()),
        ),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.sm + 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (gold.isNotEmpty) ..._grid(gold),
              if (gold.isNotEmpty && silver.isNotEmpty) ...[
                const SizedBox(height: AppSpacing.xs),
                const Divider(height: 1),
                const SizedBox(height: AppSpacing.xs),
              ],
              if (silver.isNotEmpty) ..._grid(silver),
              const SizedBox(height: 2),
              Text(
                'Per gram · tap for all rates and history',
                textAlign: TextAlign.right,
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }

  List<Widget> _grid(List<GoldRate> rates) {
    return [
      for (var start = 0; start < rates.length; start += _perRow)
        Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.xs),
          child: Row(
            children: [
              for (var i = start; i < start + _perRow; i++) ...[
                if (i > start) const SizedBox(width: AppSpacing.xs),
                Expanded(child: i < rates.length ? _RateCell(rate: rates[i]) : const SizedBox.shrink()),
              ],
            ],
          ),
        ),
    ];
  }
}

class _RateCell extends StatelessWidget {
  final GoldRate rate;

  const _RateCell({required this.rate});

  @override
  Widget build(BuildContext context) {
    final palette = PurityPalette.of(context, rate.karat);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppFormat.karat(rate.karat),
            style: AppTextStyles.labelSmall.copyWith(color: palette.text),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              AppFormat.peso(rate.pricePerGramCentavos),
              style: AppTextStyles.numericBody.copyWith(color: palette.text, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Quick entry — jumps to the relevant primary tab.
// ---------------------------------------------------------------------------
class _QuickEntryGrid extends StatelessWidget {
  final AppUserRole role;
  final ValueChanged<int>? onNavigateToTab;

  const _QuickEntryGrid({required this.role, required this.onNavigateToTab});

  @override
  Widget build(BuildContext context) {
    // "New Purchase" and "Run Disposal" have a single standalone form to
    // jump straight into, so they push it directly. "New Sale" (browse
    // first, no single form) and "Commitments" (a list to review, not one
    // record to create) land on their tab instead.
    final actions = <_QuickAction>[
      if (role.canEncodePurchases)
        _QuickAction(
          'New Purchase',
          Icons.add_shopping_cart_rounded,
          AppColors.primaryBlue,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const NewPurchaseScreen()),
          ),
        ),
      if (role.canMakeSales)
        _QuickAction(
          'New Sale',
          Icons.storefront_rounded,
          context.semanticColors.sellCoral,
          onTap: () => onNavigateToTab?.call(2),
        ),
      if (role.canManageCommitmentsAndRates || role.canViewAllBranches)
        _QuickAction(
          'Commitments',
          Icons.handshake_rounded,
          AppColors.info,
          // Pushed rather than switched to: commitments moved off the bottom
          // bar onto the More page, so there is no tab index to jump to.
          onTap: () => _pushStandalone(context, 'Commitment', const CommitmentScreen()),
        ),
      if (role.canRunDisposal)
        _QuickAction(
          'Run Disposal',
          Icons.delete_sweep_rounded,
          context.semanticColors.warning,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const DisposalSelectionScreen()),
          ),
        ),
    ];

    if (actions.isEmpty) return const SizedBox.shrink();

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: AppSpacing.sm,
      crossAxisSpacing: AppSpacing.sm,
      childAspectRatio: 2.6,
      children: [for (final action in actions) _QuickActionButton(action: action)],
    );
  }
}

class _QuickAction {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _QuickAction(this.label, this.icon, this.color, {required this.onTap});
}

class _QuickActionButton extends StatelessWidget {
  final _QuickAction action;

  const _QuickActionButton({required this.action});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: action.onTap,
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: action.color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        ),
        child: Row(
          children: [
            Icon(action.icon, color: action.color, size: 20),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Text(
                action.label,
                style: AppTextStyles.bodyLarge.copyWith(
                  color: action.color,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
