import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/cash_entry.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/filter_menu_chip.dart';
import '../../core/widgets/formatters.dart';
import 'cash_entry_actions.dart';
import 'new_cash_entry_screen.dart';
import '../../core/navigation/layout.dart';

/// The branch cash screen, in two tabs: **History**, every entry that has
/// ever moved a branch's money, and **Cash Entry**, the form for recording
/// one by hand.
///
/// Money is tracked in three sources per branch — purchase cash, sales cash,
/// and cash in bank — and every balance shown is nothing more than an opening
/// figure plus the rows listed here.
class CashLedgerScreen extends StatefulWidget {
  const CashLedgerScreen({super.key});

  @override
  State<CashLedgerScreen> createState() => _CashLedgerScreenState();
}

class _CashLedgerScreenState extends State<CashLedgerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // A phone shows one at a time and swaps between them. A desktop window
    // has room for both, which is how the ledger is actually worked: the
    // history on the left to check against, the entry being written on the
    // right, without losing sight of either.
    if (WindowSize.of(context).hasRoomForTwoColumns) {
      return Scaffold(
        appBar: AppBar(title: const Text('Cash')),
        body: const _SideBySide(),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cash'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'History'),
            Tab(text: 'Cash Entry'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: [
          const _HistoryTab(),
          CashEntryForm(onRecorded: () => _tabs.animateTo(0)),
        ],
      ),
    );
  }
}

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab>
    with AutomaticKeepAliveClientMixin {
  CashAccount? _accountFilter;
  CashEntryType? _typeFilter;
  DateTimeRange? _dateRange;

  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();
    final branchId = appState.selectedBranch;

    var entries = repo.cashEntriesForBranch(branchId, account: _accountFilter);
    if (_typeFilter != null) {
      entries = entries.where((e) => e.type == _typeFilter).toList();
    }
    if (_dateRange != null) {
      entries = entries.where((e) {
        final d = DateTime(e.date.year, e.date.month, e.date.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }

    // Running balance only makes sense against one branch's own source — a
    // combined running total across separate drawers would describe none.
    final runningBalances = branchId != null
        ? _runningBalancesFor(repo, branchId)
        : const <String, int>{};

    return ListView(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.sm,
        AppSpacing.md,
        AppSpacing.xl,
      ),
      children: [
        _CashSummarySection(
          branchId: branchId,
          dateRange: _dateRange,
          account: _accountFilter,
        ),
        const SizedBox(height: AppSpacing.sm),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: [
              FilterMenuChip<CashAccount>(
                label: _accountFilter?.label ?? 'All sources',
                active: _accountFilter != null,
                allLabel: 'All sources',
                values: CashAccount.values,
                labelOf: (a) => a.label,
                onChanged: (v) => setState(() => _accountFilter = v),
              ),
              const SizedBox(width: AppSpacing.sm),
              FilterMenuChip<CashEntryType>(
                label: _typeFilter?.label ?? 'Entry type',
                active: _typeFilter != null,
                allLabel: 'All types',
                values: CashEntryType.values,
                labelOf: (t) => t.label,
                onChanged: (v) => setState(() => _typeFilter = v),
              ),
              const SizedBox(width: AppSpacing.sm),
              DateRangeChip(
                range: _dateRange,
                onChanged: (v) => setState(() => _dateRange = v),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        if (entries.isEmpty)
          const EmptyState(
            icon: Icons.receipt_long_outlined,
            title: 'No cash entries match these filters',
          )
        else
          for (final entry in entries) ...[
            _CashEntryTile(
              entry: entry,
              showBranch: branchId == null,
              runningBalanceCentavos: runningBalances[entry.id],
            ),
            const SizedBox(height: AppSpacing.sm),
          ],
        if (branchId != null)
          _OpeningBalanceFooter(branchId: branchId, account: _accountFilter),
      ],
    );
  }

  /// What each entry's own source held right after it, folded from that
  /// source's opening balance over its FULL unfiltered history, so the figure
  /// is right whatever the filters narrow the list to.
  Map<String, int> _runningBalancesFor(AppRepository repo, BranchId branchId) {
    final map = <String, int>{};
    for (final account in CashAccount.values) {
      var running = repo.startingBalance(branchId, account);
      for (final e
          in repo.cashEntriesForBranch(branchId, account: account).reversed) {
        running += e.signedAmountCentavos;
        map[e.id] = running;
      }
    }
    return map;
  }
}

// ---------------------------------------------------------------------------
// Summary section.
// ---------------------------------------------------------------------------
class _CashSummarySection extends StatelessWidget {
  final BranchId? branchId;
  final DateTimeRange? dateRange;
  final CashAccount? account;

  const _CashSummarySection({
    required this.branchId,
    required this.dateRange,
    required this.account,
  });

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();

    if (branchId != null) {
      return _SummaryCard(
        title: branchId!.label,
        balances: {
          for (final a in CashAccount.values)
            a: repo.accountBalance(branchId!, a),
        },
        totals: _periodTotals(repo, branchId!, dateRange, account),
      );
    }

    // Admin viewing both branches: each branch's card, plus a consolidated one.
    final combined = {
      for (final a in CashAccount.values)
        a: repo.branches.fold<int>(
          0,
          (sum, b) => sum + repo.accountBalance(b.id, a),
        ),
    };
    var combinedIn = 0;
    var combinedOut = 0;
    for (final b in repo.branches) {
      final t = _periodTotals(repo, b.id, dateRange, account);
      combinedIn += t.totalIn;
      combinedOut += t.totalOut;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final b in repo.branches) ...[
          _SummaryCard(
            title: b.id.label,
            balances: {
              for (final a in CashAccount.values)
                a: repo.accountBalance(b.id, a),
            },
            totals: _periodTotals(repo, b.id, dateRange, account),
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
        _SummaryCard(
          title: 'Consolidated (both branches)',
          balances: combined,
          totals: _PeriodTotals(combinedIn, combinedOut),
          highlighted: true,
        ),
      ],
    );
  }
}

class _PeriodTotals {
  final int totalIn;
  final int totalOut;
  const _PeriodTotals(this.totalIn, this.totalOut);
}

/// Total in / out for one branch within [dateRange] (all-time if null),
/// narrowed to one source when [account] is set.
_PeriodTotals _periodTotals(
  AppRepository repo,
  BranchId branchId,
  DateTimeRange? dateRange,
  CashAccount? account,
) {
  var entries = repo.cashEntriesForBranch(branchId, account: account);
  if (dateRange != null) {
    entries = entries.where((e) {
      final d = DateTime(e.date.year, e.date.month, e.date.day);
      return !d.isBefore(dateRange.start) && !d.isAfter(dateRange.end);
    }).toList();
  }
  final totalIn = entries
      .where((e) => e.type.isCredit)
      .fold<int>(0, (s, e) => s + e.amountCentavos);
  final totalOut = entries
      .where((e) => !e.type.isCredit)
      .fold<int>(0, (s, e) => s + e.amountCentavos);
  return _PeriodTotals(totalIn, totalOut);
}

class _SummaryCard extends StatelessWidget {
  final String title;
  final Map<CashAccount, int> balances;
  final _PeriodTotals totals;
  final bool highlighted;

  const _SummaryCard({
    required this.title,
    required this.balances,
    required this.totals,
    this.highlighted = false,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final net = totals.totalIn - totals.totalOut;
    return Card(
      margin: EdgeInsets.zero,
      color: highlighted ? AppColors.primaryBlue.withValues(alpha: 0.06) : null,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        side: highlighted
            ? BorderSide(color: AppColors.primaryBlue.withValues(alpha: 0.25))
            : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppTextStyles.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                for (final a in CashAccount.values) ...[
                  if (a != CashAccount.values.first)
                    const SizedBox(width: AppSpacing.xs),
                  Expanded(
                    child: _AccountBalance(
                      account: a,
                      balance: balances[a] ?? 0,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _MiniFigure(
                    label: 'Total in',
                    value: AppFormat.peso(totals.totalIn, whole: true),
                    color: sc.success,
                  ),
                ),
                Expanded(
                  child: _MiniFigure(
                    label: 'Total out',
                    value: AppFormat.peso(totals.totalOut, whole: true),
                    color: sc.danger,
                  ),
                ),
                Expanded(
                  child: _MiniFigure(
                    label: 'Net',
                    value: AppFormat.pesoSigned(net),
                    color: net >= 0 ? sc.success : sc.danger,
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

class _AccountBalance extends StatelessWidget {
  final CashAccount account;
  final int balance;

  const _AccountBalance({required this.account, required this.balance});

  @override
  Widget build(BuildContext context) {
    final color = accountColor(context, account);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            account.label,
            style: AppTextStyles.caption.copyWith(color: color, fontSize: 10.5),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              AppFormat.peso(balance, whole: true),
              style: AppTextStyles.numericBody.copyWith(
                color: color,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One colour per cash source, used for its balance and its tag.
Color accountColor(BuildContext context, CashAccount account) {
  switch (account) {
    case CashAccount.purchase:
      return AppColors.primaryBlue;
    case CashAccount.sales:
      return context.semanticColors.sellCoral;
    case CashAccount.bank:
      return AppColors.silverDark;
  }
}

class _MiniFigure extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _MiniFigure({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: AppTextStyles.numericSmall.copyWith(color: color)),
        Text(
          label,
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Ledger rows.
// ---------------------------------------------------------------------------
class _CashEntryTile extends StatelessWidget {
  final CashEntry entry;
  final bool showBranch;
  final int? runningBalanceCentavos;

  const _CashEntryTile({
    required this.entry,
    required this.showBranch,
    required this.runningBalanceCentavos,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final color = entry.type.isCredit ? sc.success : sc.danger;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showCashEntryActions(context, entry),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: AppSpacing.xs,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        _CashEntryTypeBadge(type: entry.type),
                        _SourceTag(
                          label: entry.account.label,
                          color: accountColor(context, entry.account),
                        ),
                        if (showBranch) _BranchTag(branch: entry.branch),
                        if (entry.isManual)
                          _SourceTag(
                            label: 'Manual entry',
                            color: AppColors.textSecondary,
                          )
                        else
                          _SourceTag(
                            label: 'Linked — ${_sourceLabel(entry.sourceType)}',
                            color: AppColors.info,
                          ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        AppFormat.pesoSigned(entry.signedAmountCentavos),
                        style: AppTextStyles.numericMedium.copyWith(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (runningBalanceCentavos != null)
                        Text(
                          'Bal ${AppFormat.peso(runningBalanceCentavos!, whole: true)}',
                          style: AppTextStyles.caption.copyWith(
                            color: AppColors.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                entry.category != null
                    ? '${entry.category} — ${entry.note}'
                    : entry.note,
                style: AppTextStyles.bodyMedium,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${AppFormat.dateTimeShort(entry.date)} · ${entry.recordedByRole.label}',
                      style: AppTextStyles.caption.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Icon(
                    entry.isManual
                        ? Icons.edit_outlined
                        : Icons.lock_outline_rounded,
                    size: 14,
                    color: AppColors.textDisabled,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _sourceLabel(CashEntrySourceType type) {
    switch (type) {
      case CashEntrySourceType.purchase:
        return 'Purchase';
      case CashEntrySourceType.sale:
        return 'Sale';
      case CashEntrySourceType.commitment:
        return 'Commitment';
      case CashEntrySourceType.manual:
        return 'Manual';
    }
  }
}

class _CashEntryTypeBadge extends StatelessWidget {
  final CashEntryType type;

  const _CashEntryTypeBadge({required this.type});

  IconData get _icon {
    switch (type) {
      case CashEntryType.cashIn:
        return Icons.south_west_rounded;
      case CashEntryType.expense:
        return Icons.north_east_rounded;
      case CashEntryType.withdrawal:
        return Icons.north_east_rounded;
      case CashEntryType.transferOut:
        return Icons.call_made_rounded;
      case CashEntryType.transferIn:
        return Icons.call_received_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final color = type.isCredit ? sc.success : sc.danger;
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            type.label,
            style: AppTextStyles.labelSmall.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _BranchTag extends StatelessWidget {
  final BranchId branch;

  const _BranchTag({required this.branch});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
      ),
      child: Text(
        branch.label,
        style: AppTextStyles.labelSmall.copyWith(
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _SourceTag extends StatelessWidget {
  final String label;
  final Color color;

  const _SourceTag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        border: Border.all(color: color.withValues(alpha: 0.5)),
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius + 6),
      ),
      child: Text(
        label,
        style: AppTextStyles.labelSmall.copyWith(color: color),
      ),
    );
  }
}

class _OpeningBalanceFooter extends StatelessWidget {
  final BranchId branchId;
  final CashAccount? account;

  const _OpeningBalanceFooter({required this.branchId, required this.account});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final accounts = account == null ? CashAccount.values : [account!];
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Column(
        children: [
          for (final a in accounts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  const Icon(
                    Icons.flag_circle_outlined,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      '${branchId.label} ${a.label} opening balance',
                      style: AppTextStyles.bodyMedium.copyWith(
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                  Text(
                    AppFormat.peso(repo.startingBalance(branchId, a)),
                    style: AppTextStyles.numericSmall.copyWith(
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// The desktop's cash screen: the ledger and the form, side by side.
class _SideBySide extends StatelessWidget {
  const _SideBySide();

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Expanded(flex: 3, child: _HistoryTab()),
        const VerticalDivider(width: 1, thickness: 1),
        Expanded(
          flex: 2,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 0),
                child: Text('New Entry', style: AppTextStyles.titleLarge),
              ),
              // Nothing to switch back to: the history beside it already
              // shows the entry the moment it is recorded.
              const Expanded(child: CashEntryForm()),
            ],
          ),
        ),
      ],
    );
  }
}
