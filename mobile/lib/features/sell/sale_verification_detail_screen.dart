import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/sale.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/confirm_cash_dialog.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/status_badges.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/numeric_input_field.dart';
import 'sale_detail_screen.dart';

/// The Cashier's check screen: every line item laid out so the physical
/// pieces can be confirmed against the order one by one, then a hard fork —
/// receive payment (completes the sale) or return it to the rep.
class SaleVerificationDetailScreen extends StatefulWidget {
  final String saleId;

  const SaleVerificationDetailScreen({super.key, required this.saleId});

  @override
  State<SaleVerificationDetailScreen> createState() => _SaleVerificationDetailScreenState();
}

class _SaleVerificationDetailScreenState extends State<SaleVerificationDetailScreen> {
  /// What the Cashier has actually counted. Starts as the rep's stated
  /// intent and gets corrected against the money on the counter.
  SalePayment? _payment;

  /// Rebuilt so a recalculated half reaches its field.
  Key _cashKey = UniqueKey();
  Key _bankKey = UniqueKey();

  /// Entering one half settles the other: the total is fixed by the order, so
  /// the two tenders are one number split, never two independent amounts that
  /// could quietly fail to add up.
  void _setCash(int cash, int total) {
    final clamped = cash.clamp(0, total);
    setState(() {
      _payment = SalePayment(cashCentavos: clamped, bankCentavos: total - clamped);
      _bankKey = UniqueKey();
    });
  }

  void _setBank(int bank, int total) {
    final clamped = bank.clamp(0, total);
    setState(() {
      _payment = SalePayment(cashCentavos: total - clamped, bankCentavos: clamped);
      _cashKey = UniqueKey();
    });
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final sale = repo.findSale(widget.saleId);

    if (sale == null) {
      return const Scaffold(body: Center(child: Text('Order not found')));
    }
    // The two tenders are one number split, and the order fixes that number,
    // so a stated intent that no longer adds up starts over as all cash.
    _payment ??= sale.payment.totalCentavos == sale.totalAmountCentavos
        ? sale.payment
        : SalePayment(cashCentavos: sale.totalAmountCentavos);
    // Centralized here, not just at the queue's entry point — this screen
    // is reachable from more than one place (the Cashier queue, the
    // Dashboard), so the payment/return actions must gate themselves
    // rather than trust whoever navigated in.
    final canMoveCash = context.watch<AppState>().role.canMoveCash;

    return Scaffold(
      appBar: AppBar(title: const Text('Verify Order')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.cardSurface,
              borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    TransactionCustomerAvatar(customer: sale.customer, radius: 22),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(sale.customerName, style: AppTextStyles.headlineMedium.copyWith(fontSize: 19)),
                    ),
                  ],
                ),
                if (sale.note != null) ...[
                  const SizedBox(height: 2),
                  Text(sale.note!, style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary)),
                ],
                const SizedBox(height: 2),
                Text(
                  '${sale.branch.label} · ${AppFormat.dateShort(sale.date)}',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('Items being released (${sale.lineItems.length})', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          for (final line in sale.lineItems) _LineItemCheckCard(line: line),
          const SizedBox(height: AppSpacing.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm + 2),
            decoration: BoxDecoration(
              color: AppColors.surfaceDim,
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('Total to receive', style: AppTextStyles.bodyLarge.copyWith(color: AppColors.textSecondary)),
                Text(
                  AppFormat.peso(sale.totalAmountCentavos),
                  style: AppTextStyles.numericLarge.copyWith(color: context.semanticColors.gold),
                ),
              ],
            ),
          ),
          if (canMoveCash) ...[
            const SizedBox(height: AppSpacing.md),
            _PaymentSplitEntry(
              total: sale.totalAmountCentavos,
              payment: _payment!,
              cashKey: _cashKey,
              bankKey: _bankKey,
              onCashChanged: (v) => _setCash(v, sale.totalAmountCentavos),
              onBankChanged: (v) => _setBank(v, sale.totalAmountCentavos),
            ),
            const SizedBox(height: AppSpacing.xl),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: context.semanticColors.success),
                icon: const Icon(Icons.payments_rounded),
                label: const Text('Receive Payment'),
                onPressed: () => _receivePayment(context, repo, sale),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: const BorderSide(color: AppColors.danger, width: 1.4),
                ),
                icon: const Icon(Icons.flag_outlined),
                label: const Text('Return to Rep'),
                onPressed: () => _returnToRep(context, repo, sale),
              ),
            ),
          ] else ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppColors.surfaceDim,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              ),
              child: Row(
                children: [
                  const Icon(Icons.lock_outline_rounded, size: 16, color: AppColors.textSecondary),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Payment is received by whoever is at the counter — sign in to take it.',
                      style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _receivePayment(BuildContext context, AppRepository repo, Sale sale) async {
    final confirmed = await ConfirmCashDialog.show(
      context,
      direction: CashDirection.receive,
      amountCentavos: sale.totalAmountCentavos,
      branch: sale.branch,
      counterparty: sale.customerName,
      reason: 'the sale of ${sale.lineItems.length} item(s)',
      // Cash taken over the counter goes to Sales Cash; a bank transfer goes
      // straight to Cash in Bank — never into the purchase float.
      breakdown: [
        if (_payment!.cashCentavos > 0)
          (label: '${sale.branch.label} Sales Cash', amountCentavos: _payment!.cashCentavos),
        if (_payment!.bankCentavos > 0)
          (label: '${sale.branch.label} Cash in Bank', amountCentavos: _payment!.bankCentavos),
      ],
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    repo.completeSale(
      actor: context.read<AppState>().currentUser,
      sale.id,
      payment: _payment!,
      recordedByRole: context.read<AppState>().role,
    );
    // Straight to the completed record, which is where the customer's receipt
    // and the snapshot live — the moment payment lands is when they are
    // actually wanted.
    navigator.pop();
    navigator.push(
      MaterialPageRoute(builder: (_) => SaleDetailScreen(saleId: sale.id)),
    );
    messenger.showSnackBar(
      SnackBar(content: Text('Payment received from ${sale.customerName} — receipt ready.')),
    );
  }

  Future<void> _returnToRep(BuildContext context, AppRepository repo, Sale sale) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ReturnNoteDialog(customerName: sale.customerName),
    );
    if (note == null || note.trim().isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    repo.returnSaleForCorrection(sale.id, note.trim(), actor: context.read<AppState>().currentUser);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Returned to ${sale.submittedByRole.label} for correction.')),
    );
  }
}

/// Cash and bank sides of one payment, each settling the other against the
/// order total.
class _PaymentSplitEntry extends StatelessWidget {
  final int total;
  final SalePayment payment;
  final Key cashKey;
  final Key bankKey;
  final ValueChanged<int> onCashChanged;
  final ValueChanged<int> onBankChanged;

  const _PaymentSplitEntry({
    required this.total,
    required this.payment,
    required this.cashKey,
    required this.bankKey,
    required this.onCashChanged,
    required this.onBankChanged,
  });

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Payment received',
          style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.sm),
        Row(
          children: [
            Expanded(
              child: NumericInputField(
                key: cashKey,
                label: 'Cash',
                kind: NumericInputKind.peso,
                initialValue: payment.cashCentavos / 100,
                onChanged: (v) => onCashChanged(v == null ? 0 : (v * 100).round()),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: NumericInputField(
                key: bankKey,
                label: 'Bank transfer',
                kind: NumericInputKind.peso,
                initialValue: payment.bankCentavos / 100,
                onChanged: (v) => onBankChanged(v == null ? 0 : (v * 100).round()),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Row(
          children: [
            Icon(Icons.check_circle_rounded, size: 14, color: sc.success),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                payment.isSplit
                    ? 'Split — ${AppFormat.peso(payment.cashCentavos)} goes to Sales Cash, '
                        '${AppFormat.peso(payment.bankCentavos)} goes to Cash in Bank.'
                    : payment.bankCentavos > 0
                        ? 'The full ${AppFormat.peso(total)} goes to Cash in Bank.'
                        : 'The full ${AppFormat.peso(total)} goes to Sales Cash.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _LineItemCheckCard extends StatelessWidget {
  final SaleLineItem line;

  const _LineItemCheckCard({required this.line});

  @override
  Widget build(BuildContext context) {
    final item = line.item;

    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.cardSurface,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: AppColors.outline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // The photo filed when the piece was encoded or picked for this
              // order — what the Cashier checks the goods against.
              if (item.hasPhoto) ...[
                ItemPhotoThumbnail(photo: item.photo!, label: item.description),
                const SizedBox(width: AppSpacing.sm),
              ],
              Expanded(child: Text(item.description, style: AppTextStyles.titleMedium)),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              Expanded(
                child: _Field(
                  label: 'Final weight',
                  value: AppFormat.grams(line.effectiveFinalGrams),
                ),
              ),
              Expanded(child: _Field(label: item.type.isSilver ? 'Purity' : 'Karat', value: AppFormat.karat(item.karat), color: PurityPalette.of(context, item.karat).text)),
              Expanded(
                child: _Field(
                  label: 'Per gram',
                  value: AppFormat.peso(line.pricePerGramCentavos),
                ),
              ),
              Expanded(child: _Field(label: 'Price', value: AppFormat.peso(line.negotiatedPriceCentavos))),
            ],
          ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Field({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        Text(value, style: AppTextStyles.numericBody.copyWith(color: color ?? AppColors.textPrimary)),
      ],
    );
  }
}

class _ReturnNoteDialog extends StatefulWidget {
  final String customerName;

  const _ReturnNoteDialog({required this.customerName});

  @override
  State<_ReturnNoteDialog> createState() => _ReturnNoteDialogState();
}

class _ReturnNoteDialogState extends State<_ReturnNoteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppSpacing.cardRadius)),
      title: const Text('Return to rep?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Explain what needs to be fixed on ${widget.customerName}\'s order. This note goes back to the rep.',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(labelText: 'Correction note', hintText: 'e.g. price on the ring looks wrong'),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _controller.text.trim().isEmpty ? null : () => Navigator.of(context).pop(_controller.text),
          child: const Text('Return'),
        ),
      ],
    );
  }
}
