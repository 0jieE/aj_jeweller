import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item_status.dart';
import '../../core/models/sale.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/search_field.dart';
import 'sale_detail_screen.dart';

/// Completed sales for the current branch view — what actually went out the
/// door, as opposed to the Available tab's remaining stock.
///
/// Rows are sales rather than items: a customer buying three pieces is one
/// transaction, one receipt, and one payment, and splitting it back into
/// pieces here would misrepresent what happened.
class SoldGoodsScreen extends StatefulWidget {
  const SoldGoodsScreen({super.key});

  @override
  State<SoldGoodsScreen> createState() => _SoldGoodsScreenState();
}

class _SoldGoodsScreenState extends State<SoldGoodsScreen> {
  String _query = '';
  DateTimeRange? _dateRange;

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final repo = context.watch<AppRepository>();

    var sales = repo
        .salesForBranch(appState.selectedBranch)
        .where((s) => s.verificationStatus == VerificationStatus.verified)
        .toList();

    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      sales = sales
          .where((s) =>
              s.customerName.toLowerCase().contains(q) ||
              s.id.toLowerCase().contains(q) ||
              s.lineItems.any((l) => l.item.description.toLowerCase().contains(q)))
          .toList();
    }
    if (_dateRange != null) {
      sales = sales.where((s) {
        final d = DateTime(s.date.year, s.date.month, s.date.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }
    sales.sort((a, b) => b.date.compareTo(a.date));

    final totalCentavos = sales.fold<int>(0, (sum, s) => sum + s.totalAmountCentavos);
    final totalGrams = sales.fold<double>(
      0,
      (sum, s) => sum + s.lineItems.fold<double>(0, (g, l) => g + l.effectiveFinalGrams),
    );

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: _SoldTotalCard(
            count: sales.length,
            totalCentavos: totalCentavos,
            totalGrams: totalGrams,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.sm, AppSpacing.md, 0),
          child: SearchField(
            hintText: 'Search sold by customer, item, or id',
            onChanged: (v) => setState(() => _query = v),
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.xs),
            children: [
              DateRangeChip(
                range: _dateRange,
                onChanged: (v) => setState(() => _dateRange = v),
              ),
            ],
          ),
        ),
        Expanded(
          child: sales.isEmpty
              ? EmptyState(
                  icon: Icons.receipt_long_outlined,
                  title: q.isEmpty && _dateRange == null
                      ? 'Nothing sold yet'
                      : 'No sales match these filters',
                  message: q.isEmpty && _dateRange == null
                      ? 'Completed sales show up here once a Cashier receives payment.'
                      : null,
                )
              : ListView.separated(
                  padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                  itemCount: sales.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _SoldSaleTile(sale: sales[i]),
                ),
        ),
      ],
    );
  }
}

class _SoldTotalCard extends StatelessWidget {
  final int count;
  final int totalCentavos;
  final double totalGrams;

  const _SoldTotalCard({
    required this.count,
    required this.totalCentavos,
    required this.totalGrams,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: sc.sellCoralSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: sc.sellCoral.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: sc.sellCoral.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.storefront_rounded, color: sc.sellCoral),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SOLD · $count SALE(S)',
                  style: AppTextStyles.labelSmall.copyWith(color: sc.sellCoral),
                ),
                Text(
                  AppFormat.peso(totalCentavos),
                  style: AppTextStyles.numericLarge.copyWith(color: sc.sellCoral),
                ),
                Text(
                  '${AppFormat.grams(totalGrams)} of gold out the door',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SoldSaleTile extends StatelessWidget {
  final Sale sale;

  const _SoldSaleTile({required this.sale});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final grams = sale.lineItems.fold<double>(0, (g, l) => g + l.effectiveFinalGrams);

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => SaleDetailScreen(saleId: sale.id)),
      ),
      leading: TransactionCustomerAvatar(customer: sale.customer, radius: 22),
      title: Text(
        sale.customerName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        '${sale.lineItems.length} item(s) · ${AppFormat.grams(grams)} · '
        '${sale.payment.label} · ${AppFormat.dateShort(sale.date)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: Text(
        AppFormat.peso(sale.totalAmountCentavos, whole: true),
        style: AppTextStyles.numericMedium.copyWith(color: sc.sellCoral),
      ),
    );
  }
}
