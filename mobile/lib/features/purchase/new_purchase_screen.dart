import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/purchase_batch.dart';
import '../../core/state/app_state.dart';
import '../../core/state/purchase_basket_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_fields.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/status_badges.dart';
import 'purchase_batch_detail_screen.dart';
import 'purchase_line_form_screen.dart';
import '../../core/navigation/layout.dart';

/// One counter transaction being built: who is selling, and every piece they
/// have handed over.
///
/// Items are staged here and written together, because a customer arriving
/// with five pieces is paid once — so the Cashier should be asked to release
/// cash once, against one record, not five times against five.
class NewPurchaseScreen extends StatefulWidget {
  const NewPurchaseScreen({super.key});

  @override
  State<NewPurchaseScreen> createState() => _NewPurchaseScreenState();
}

class _NewPurchaseScreenState extends State<NewPurchaseScreen> {
  @override
  void initState() {
    super.initState();
    final basket = context.read<PurchaseBasketState>();

    // The branch in view is almost always the branch buying; the picker below
    // is only there for an Admin standing in the combined view.
    final selected = context.read<AppState>().selectedBranch;
    if (basket.branch == null && selected != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => basket.setBranch(selected));
    }
  }

  @override
  Widget build(BuildContext context) {
    final basket = context.watch<PurchaseBasketState>();
    final repo = context.watch<AppRepository>();
    final branchBalance = basket.branch == null ? null : repo.cashBalance(basket.branch!);

    return Scaffold(
      appBar: AppBar(
        title: const Text('New Purchase'),
        actions: [
          if (!basket.isEmpty)
            TextButton(
              onPressed: () => _confirmDiscard(context, basket),
              child: Text('Discard', style: TextStyle(color: AppColors.danger)),
            ),
        ],
      ),
      body: FormPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (branchBalance != null)
              _CashOnHandCard(branchBalance: branchBalance, staged: basket.totalCentavos),
            const SizedBox(height: AppSpacing.md),
            Text('Customer', style: AppTextStyles.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            CustomerFields(
              initial: basket.customer,
              onChanged: basket.setCustomer,
            ),
            if (context.watch<AppState>().selectedBranch == null) ...[
              const SizedBox(height: AppSpacing.sm),
              DropdownButtonFormField<BranchId>(
                initialValue: basket.branch,
                decoration: const InputDecoration(labelText: 'Branch'),
                items: [
                  for (final b in BranchId.values)
                    DropdownMenuItem(value: b, child: Text(b.label)),
                ],
                onChanged: basket.setBranch,
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Items (${basket.lineCount})', style: AppTextStyles.titleMedium),
                TextButton.icon(
                  onPressed: () => _addLine(context, basket),
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('Add item'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xs),
            if (basket.isEmpty)
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.surfaceDim,
                  borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Text(
                  'No pieces added yet.',
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                ),
              )
            else
              for (var i = 0; i < basket.lines.length; i++) ...[
                _DraftLineCard(
                  line: basket.lines[i],
                  onEdit: () => _editLine(context, basket, i),
                  onRemove: () => basket.removeLine(i),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
            const SizedBox(height: AppSpacing.md),
            _TotalCard(totalCentavos: basket.totalCentavos, totalGrams: basket.totalNetGrams),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton(
              onPressed: basket.canSubmit ? () => _submit(context, basket) : null,
              child: const Text('Submit Purchase'),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Cash is released by a Cashier once, for the whole purchase.',
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }

  Future<void> _addLine(BuildContext context, PurchaseBasketState basket) async {
    final line = await Navigator.of(context).push<PurchaseDraftLine>(
      MaterialPageRoute(builder: (_) => const PurchaseLineFormScreen()),
    );
    if (line != null) basket.addLine(line);
  }

  Future<void> _editLine(BuildContext context, PurchaseBasketState basket, int index) async {
    final line = await Navigator.of(context).push<PurchaseDraftLine>(
      MaterialPageRoute(
        builder: (_) => PurchaseLineFormScreen(existing: basket.lines[index]),
      ),
    );
    if (line != null) basket.replaceLine(index, line);
  }

  Future<void> _confirmDiscard(BuildContext context, PurchaseBasketState basket) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Discard this purchase?'),
        content: Text(
          '${basket.lineCount} staged item(s) will be cleared. Nothing has been '
          'recorded yet, so there is nothing to undo afterwards.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Keep')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (confirmed == true && context.mounted) {
      basket.clear();
      Navigator.of(context).pop();
    }
  }

  void _submit(BuildContext context, PurchaseBasketState basket) {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final count = basket.lineCount;
    final batch = basket.submit(actor: context.read<AppState>().currentUser);

    navigator.pop();
    navigator.push(
      MaterialPageRoute(builder: (_) => PurchaseBatchDetailScreen(batchId: batch.id)),
    );
    messenger.showSnackBar(
      SnackBar(content: Text('Purchase ${batch.id} submitted — $count item(s) awaiting cash release.')),
    );
  }
}

class _CashOnHandCard extends StatelessWidget {
  final int branchBalance;
  final int staged;

  const _CashOnHandCard({required this.branchBalance, required this.staged});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final after = branchBalance - staged;
    final short = after < 0;

    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Cash on hand', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                Text(
                  AppFormat.peso(branchBalance, whole: true),
                  style: AppTextStyles.numericMedium.copyWith(color: AppColors.primaryBlue),
                ),
              ],
            ),
          ),
          Container(width: 1, height: 34, color: AppColors.outline),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    short ? 'Short by' : 'After this purchase',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                  Text(
                    AppFormat.peso(short ? -after : after, whole: true),
                    style: AppTextStyles.numericMedium.copyWith(
                      color: short ? sc.danger : AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DraftLineCard extends StatelessWidget {
  final PurchaseDraftLine line;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  const _DraftLineCard({required this.line, required this.onEdit, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;

    return InkWell(
      onTap: onEdit,
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          border: Border.all(color: AppColors.outline),
        ),
        child: Row(
          children: [
            if (line.photo != null)
              ItemPhotoThumbnail(photo: line.photo!, label: line.description, size: 40)
            else
              Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: PurityPalette.of(context, line.karat).surface,
                  borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                ),
                child: Text(
                  AppFormat.karat(line.karat),
                  style: AppTextStyles.numericSmall.copyWith(
                    color: PurityPalette.of(context, line.karat).text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    line.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        AppFormat.grams(line.weightGrams),
                        style: AppTextStyles.numericSmall.copyWith(color: AppColors.textSecondary),
                      ),
                      if (line.deductedGrams > 0.0005)
                        Text(
                          ' of ${AppFormat.grams(line.grossWeightGrams)}',
                          style: AppTextStyles.numericSmall.copyWith(color: AppColors.textDisabled),
                        ),
                      const SizedBox(width: 6),
                      ItemTypeBadge(type: line.type),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              AppFormat.peso(line.capitalAmountCentavos, whole: true),
              style: AppTextStyles.numericMedium.copyWith(color: sc.gold),
            ),
            IconButton(
              icon: const Icon(Icons.close_rounded, size: 18),
              color: AppColors.textSecondary,
              tooltip: 'Remove item',
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _TotalCard extends StatelessWidget {
  final int totalCentavos;
  final double totalGrams;

  const _TotalCard({required this.totalCentavos, required this.totalGrams});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: sc.buyGreenSurface,
        borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
        border: Border.all(color: sc.buyGreen.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('TOTAL TO PAY', style: AppTextStyles.labelSmall.copyWith(color: sc.buyGreen)),
              Text(
                '${AppFormat.grams(totalGrams)} net gold',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
          ),
          Text(
            AppFormat.peso(totalCentavos),
            style: AppTextStyles.numericLarge.copyWith(color: sc.buyGreen, fontSize: 24),
          ),
        ],
      ),
    );
  }
}
