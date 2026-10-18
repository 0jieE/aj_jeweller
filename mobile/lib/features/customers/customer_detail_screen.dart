import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item_status.dart';
import '../../core/models/purchase_batch.dart';
import '../../core/models/sale.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../purchase/purchase_batch_detail_screen.dart';
import '../sell/sale_detail_screen.dart';
import '../../core/navigation/layout.dart';

/// One customer and everything the shop has done with them, both directions
/// interleaved by date.
///
/// Purchases and sales are shown in one stream rather than two lists because
/// that is how the relationship actually reads — someone who sold in scrap
/// last month and bought a ring this week is one running account, and the
/// question staff ask at the counter is "what have we done with you before?"
class CustomerDetailScreen extends StatelessWidget {
  final String customerId;

  const CustomerDetailScreen({super.key, required this.customerId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final customer = repo.findCustomer(customerId);

    if (customer == null) {
      return const Scaffold(body: Center(child: Text('Customer not found')));
    }

    final purchases = repo.purchasesByCustomer(customerId);
    final sales = repo.salesByCustomer(customerId);

    final boughtFrom = purchases.fold<int>(0, (sum, b) => sum + repo.batchTotalCentavos(b.id));
    final soldTo = sales.fold<int>(0, (sum, s) => sum + s.totalAmountCentavos);

    // One stream, newest first.
    final history = <_HistoryEntry>[
      for (final batch in purchases)
        _HistoryEntry.purchase(batch, repo.batchTotalCentavos(batch.id), repo.itemsInBatch(batch.id).length),
      for (final sale in sales) _HistoryEntry.sale(sale),
    ]..sort((a, b) => b.date.compareTo(a.date));

    return Scaffold(
      appBar: AppBar(title: Text(customer.name)),
      body: DetailPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Center(child: CustomerAvatar(name: customer.name, photo: customer.photo, radius: 48)),
            Center(
              child: TextButton.icon(
                onPressed: () async {
                  final photo = await pickCustomerPhoto(context);
                  if (photo == null || !context.mounted) return;
                  repo.setCustomerPhoto(
                    customer.id,
                    photo,
                    actor: context.read<AppState>().currentUser,
                  );
                },
                icon: const Icon(Icons.photo_camera_outlined, size: 16),
                label: Text(customer.hasPhoto ? 'Change photo' : 'Add photo'),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            _ContactCard(
              contactNumber: customer.contactNumber,
              address: customer.address,
              since: customer.firstSeen,
            ),
            const SizedBox(height: AppSpacing.md),
            Row(
              children: [
                Expanded(
                  child: _TotalCard(
                    label: 'Bought from them',
                    sublabel: '${purchases.length} purchase(s)',
                    amountCentavos: boughtFrom,
                    color: context.semanticColors.buyGreen,
                    icon: Icons.south_west_rounded,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: _TotalCard(
                    label: 'Sold to them',
                    sublabel: '${sales.length} sale(s)',
                    amountCentavos: soldTo,
                    color: context.semanticColors.sellCoral,
                    icon: Icons.north_east_rounded,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Text('Transaction History (${history.length})', style: AppTextStyles.titleLarge),
            const SizedBox(height: AppSpacing.sm),
            if (history.isEmpty)
              const EmptyState(
                icon: Icons.history_rounded,
                title: 'Nothing recorded yet',
                message: 'Purchases and sales against this customer will appear here.',
              )
            else
              Container(
                decoration: BoxDecoration(
                  color: AppColors.cardSurface,
                  borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < history.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _HistoryTile(entry: history[i]),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }
}

/// A purchase or a sale, flattened so the two can share one ordered list.
class _HistoryEntry {
  final bool isPurchase;
  final String recordId;
  final DateTime date;
  final int totalCentavos;
  final int itemCount;
  final String detail;
  final VerificationStatus status;

  const _HistoryEntry({
    required this.isPurchase,
    required this.recordId,
    required this.date,
    required this.totalCentavos,
    required this.itemCount,
    required this.detail,
    required this.status,
  });

  factory _HistoryEntry.purchase(PurchaseBatch batch, int total, int itemCount) {
    return _HistoryEntry(
      isPurchase: true,
      recordId: batch.id,
      date: batch.date,
      totalCentavos: total,
      itemCount: itemCount,
      detail: batch.branch.label,
      status: batch.verificationStatus,
    );
  }

  factory _HistoryEntry.sale(Sale sale) {
    return _HistoryEntry(
      isPurchase: false,
      recordId: sale.id,
      date: sale.date,
      totalCentavos: sale.totalAmountCentavos,
      itemCount: sale.lineItems.length,
      detail: '${sale.branch.label} · ${sale.payment.label}',
      status: sale.verificationStatus,
    );
  }
}

class _HistoryTile extends StatelessWidget {
  final _HistoryEntry entry;

  const _HistoryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final accent = entry.isPurchase ? sc.buyGreen : sc.sellCoral;

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => entry.isPurchase
              ? PurchaseBatchDetailScreen(batchId: entry.recordId)
              : SaleDetailScreen(saleId: entry.recordId),
        ),
      ),
      leading: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        ),
        child: Icon(
          entry.isPurchase ? Icons.south_west_rounded : Icons.north_east_rounded,
          color: accent,
          size: 18,
        ),
      ),
      title: Row(
        children: [
          Text(
            entry.isPurchase ? 'Purchase' : 'Sale',
            style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: AppSpacing.sm),
          Flexible(
            child: Text(
              entry.recordId,
              style: AppTextStyles.numericSmall.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
      subtitle: Text(
        '${entry.itemCount} item(s) · ${entry.detail} · ${AppFormat.dateShort(entry.date)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text(
            AppFormat.peso(entry.totalCentavos, whole: true),
            style: AppTextStyles.numericMedium.copyWith(color: accent),
          ),
          if (entry.status != VerificationStatus.verified)
            Text(
              entry.status.label,
              style: AppTextStyles.caption.copyWith(color: sc.warning),
            ),
        ],
      ),
    );
  }
}

class _ContactCard extends StatelessWidget {
  final String? contactNumber;
  final String? address;
  final DateTime since;

  const _ContactCard({
    required this.contactNumber,
    required this.address,
    required this.since,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(icon: Icons.phone_outlined, value: contactNumber ?? 'No contact number on file'),
          const SizedBox(height: AppSpacing.xs),
          _Line(icon: Icons.home_outlined, value: address ?? 'No address on file'),
          const SizedBox(height: AppSpacing.xs),
          _Line(
            icon: Icons.event_outlined,
            value: 'Customer since ${AppFormat.dateShort(since)}',
          ),
        ],
      ),
    );
  }
}

class _Line extends StatelessWidget {
  final IconData icon;
  final String value;

  const _Line({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: AppColors.textSecondary),
        const SizedBox(width: AppSpacing.sm),
        Expanded(child: Text(value, style: AppTextStyles.bodyMedium)),
      ],
    );
  }
}

class _TotalCard extends StatelessWidget {
  final String label;
  final String sublabel;
  final int amountCentavos;
  final Color color;
  final IconData icon;

  const _TotalCard({
    required this.label,
    required this.sublabel,
    required this.amountCentavos,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(height: AppSpacing.xs),
          Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
          Text(
            AppFormat.peso(amountCentavos, whole: true),
            style: AppTextStyles.numericMedium.copyWith(color: color),
          ),
          Text(sublabel, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        ],
      ),
    );
  }
}
