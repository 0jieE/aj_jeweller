import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/item.dart';
import '../../core/models/item_status.dart';
import '../../core/models/purchase_batch.dart';
import '../../core/models/stored_receipt.dart';
import '../../core/services/receipt_service.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/receipt_actions.dart';
import '../../core/widgets/record_activity.dart';
import '../../core/widgets/status_badges.dart';
import 'lot_detail_screen.dart';

/// One purchase transaction end to end: the customer, every piece they sold,
/// and the single cash release that settles the lot.
///
/// This is both the Cashier's verification screen and, once cash is actually
/// released, the record a customer can be handed.
///
/// The receipt deliberately appears only after release. A batch still
/// awaiting verification is a claim, not a transaction — issuing a receipt
/// for cash that has not left the till would document something that never
/// happened. The item photos filed by the encoder show throughout, since
/// those are exactly what the Cashier verifies against.
class PurchaseBatchDetailScreen extends StatelessWidget {
  final String batchId;

  const PurchaseBatchDetailScreen({super.key, required this.batchId});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final batch = repo.findBatch(batchId);

    if (batch == null) {
      return const Scaffold(body: Center(child: Text('Purchase not found')));
    }

    final items = repo.itemsInBatch(batchId);
    final total = repo.batchTotalCentavos(batchId);
    // Gated here rather than at the entry point: this screen is reachable
    // from the queue, the list, and straight after submitting.
    final canMoveCash = context.watch<AppState>().role.canMoveCash;
    final awaiting = batch.verificationStatus == VerificationStatus.awaitingVerification;

    return Scaffold(
      appBar: AppBar(title: const Text('Purchase Record')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeaderCard(batch: batch, total: total, itemCount: items.length),
              const SizedBox(height: AppSpacing.sm),
              // Encoder and releaser side by side: the control this screen
              // exists for is that those are two different people.
              AccountabilityCard(
                children: [
                  AttributionRow(
                    icon: Icons.edit_note_rounded,
                    label: 'Encoded by',
                    userId: batch.submittedByUserId,
                    at: batch.date,
                  ),
                  AttributionRow(
                    icon: Icons.payments_outlined,
                    label: 'Cash released by',
                    userId: batch.releasedByUserId,
                    at: batch.releasedAt,
                    pendingText: 'Not yet released',
                  ),
                  if (batch.releaseProofPhoto != null)
                    Padding(
                      padding: const EdgeInsets.only(top: AppSpacing.sm),
                      child: Row(
                        children: [
                          ItemPhotoThumbnail(
                            photo: batch.releaseProofPhoto!,
                            label: 'Cash released to ${batch.customer.name}',
                            size: 56,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Text(
                              'Proof of cash released — tap to enlarge.',
                              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              Text('Items', style: AppTextStyles.titleMedium),
              const SizedBox(height: AppSpacing.sm),
              for (final item in items) ...[
                _BatchItemCard(item: item),
                const SizedBox(height: AppSpacing.sm),
              ],
            ],
          ),
          if (batch.verificationNote != null) ...[
            const SizedBox(height: AppSpacing.sm),
            _CorrectionNote(note: batch.verificationNote!),
          ],
          const SizedBox(height: AppSpacing.md),
          if (!awaiting)
            ReceiptActions(
              recordId: batch.id,
              kind: ReceiptKind.purchase,
              branch: batch.branch,
              counterparty: batch.customer.name,
              totalCentavos: total,
              buildReceipt: () => ReceiptService.purchase(batch: batch, items: items),
              buildText: () => ReceiptService.purchaseText(batch: batch, items: items),
            )
          else
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
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
                      'The receipt is issued once a Cashier releases the cash.',
                      style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          if (canMoveCash && awaiting) ...[
            const SizedBox(height: AppSpacing.lg),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(backgroundColor: context.semanticColors.success),
                icon: const Icon(Icons.payments_rounded),
                label: Text('Release ${AppFormat.peso(total, whole: true)}'),
                onPressed: () => _releaseCash(context, repo, batch, total),
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
                label: const Text('Return for Correction'),
                onPressed: () => _returnForCorrection(context, repo, batch),
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          Text('Activity', style: AppTextStyles.titleLarge),
          const SizedBox(height: AppSpacing.sm),
          RecordActivityList(entries: repo.logsForRecord(batch.id)),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  Future<void> _releaseCash(
    BuildContext context,
    AppRepository repo,
    PurchaseBatch batch,
    int total,
  ) async {
    final proof = await showDialog<Uint8List>(
      context: context,
      builder: (_) => _ReleaseCashDialog(
        batch: batch,
        totalCentavos: total,
        itemCount: repo.itemsInBatch(batch.id).length,
      ),
    );
    if (proof == null || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    repo.releaseBatchCash(
      batch.id,
      recordedByRole: context.read<AppState>().role,
      proofPhoto: proof,
      actor: context.read<AppState>().currentUser,
    );
    messenger.showSnackBar(
      SnackBar(content: Text('Cash released to ${batch.customer.name}.')),
    );
  }

  Future<void> _returnForCorrection(
    BuildContext context,
    AppRepository repo,
    PurchaseBatch batch,
  ) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => const _ReturnNoteDialog(),
    );
    if (note == null || note.trim().isEmpty || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    repo.returnBatchForCorrection(batch.id, note.trim(), actor: context.read<AppState>().currentUser);
    Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(content: Text('Purchase ${batch.id} returned for correction.')),
    );
  }
}

class _HeaderCard extends StatelessWidget {
  final PurchaseBatch batch;
  final int total;
  final int itemCount;

  const _HeaderCard({required this.batch, required this.total, required this.itemCount});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final customer = batch.customer;

    return Container(
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TransactionCustomerAvatar(customer: customer, radius: 26),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      customer.name,
                      style: AppTextStyles.headlineMedium.copyWith(fontSize: 19),
                    ),
                    if (customer.contactNumber != null)
                      Text(customer.contactNumber!, style: AppTextStyles.bodyMedium),
                    if (customer.address != null)
                      Text(
                        customer.address!,
                        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              VerificationStatusBadge(status: batch.verificationStatus),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Purchase ${batch.id} · ${batch.branch.label} · ${AppFormat.dateTimeShort(batch.date)}',
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.md),
          const Divider(),
          const SizedBox(height: AppSpacing.sm),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    batch.releasedAt == null ? 'TO PAY' : 'PAID',
                    style: AppTextStyles.labelSmall.copyWith(color: sc.buyGreen),
                  ),
                  Text(
                    '$itemCount item(s)',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
              Text(
                AppFormat.peso(total),
                style: AppTextStyles.numericLarge.copyWith(color: sc.buyGreen, fontSize: 24),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _BatchItemCard extends StatelessWidget {
  final Item item;

  const _BatchItemCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => LotDetailScreen(itemId: item.id)),
      ),
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      child: Container(
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
                // The photo the encoder filed, if there is one — this is what
                // the Cashier checks the description and weight against.
                if (item.hasPhoto)
                  ItemPhotoThumbnail(photo: item.photo!, label: item.description)
                else
                  Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: PurityPalette.of(context, item.karat).surface,
                      borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
                    ),
                    child: Text(
                      AppFormat.karat(item.karat),
                      style: AppTextStyles.numericSmall.copyWith(
                        color: PurityPalette.of(context, item.karat).text,
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
                        item.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                      ),
                      Text(
                        'Item ${item.id}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    ItemTypeBadge(type: item.type),
                    const SizedBox(height: 4),
                    KaratBadge(karat: item.karat),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _Figure(
                    label: 'Original',
                    value: AppFormat.grams(item.effectiveGrossWeightGrams),
                  ),
                ),
                Expanded(
                  child: _Figure(
                    label: 'Final (net)',
                    value: AppFormat.grams(item.weightGrams),
                  ),
                ),
                Expanded(
                  child: _Figure(
                    label: 'Amount',
                    value: AppFormat.peso(item.capitalAmountCentavos, whole: true),
                    color: sc.gold,
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

class _Figure extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _Figure({required this.label, required this.value, this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
        Text(
          value,
          style: AppTextStyles.numericSmall.copyWith(color: color ?? AppColors.textPrimary),
        ),
      ],
    );
  }
}

class _CorrectionNote extends StatelessWidget {
  final String note;

  const _CorrectionNote({required this.note});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: sc.danger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: sc.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.flag_rounded, size: 18, color: sc.danger),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              note,
              style: AppTextStyles.bodyMedium.copyWith(color: sc.danger),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReturnNoteDialog extends StatefulWidget {
  const _ReturnNoteDialog();

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
      title: const Text('Return for correction'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        maxLines: 3,
        decoration: const InputDecoration(
          hintText: 'What needs fixing? The encoder sees this note.',
        ),
        onChanged: (_) => setState(() {}),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _controller.text.trim().isEmpty
              ? null
              : () => Navigator.of(context).pop(_controller.text),
          child: const Text('Return'),
        ),
      ],
    );
  }
}

/// Confirms a purchase payout, with a photo as proof the cash was handed
/// over. The photo is required: this is the one moment money leaves the
/// drawer with nothing but a signature to show for it.
class _ReleaseCashDialog extends StatefulWidget {
  final PurchaseBatch batch;
  final int totalCentavos;
  final int itemCount;

  const _ReleaseCashDialog({
    required this.batch,
    required this.totalCentavos,
    required this.itemCount,
  });

  @override
  State<_ReleaseCashDialog> createState() => _ReleaseCashDialogState();
}

class _ReleaseCashDialogState extends State<_ReleaseCashDialog> {
  Uint8List? _photo;

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final batch = widget.batch;
    return AlertDialog(
      title: const Text('Release cash?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              AppFormat.peso(widget.totalCentavos),
              textAlign: TextAlign.center,
              style: AppTextStyles.numericLarge.copyWith(color: sc.danger),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'To ${batch.customer.name} for ${widget.itemCount} item(s) · '
              'out of ${batch.branch.label} Purchase Cash',
              textAlign: TextAlign.center,
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ItemPhotoField(
              photo: _photo,
              label: 'Proof of cash released (required)',
              caption: 'The counted cash as it is handed over — kept on this purchase.',
              onChanged: (bytes) => setState(() => _photo = bytes),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
          onPressed: _photo == null ? null : () => Navigator.of(context).pop(_photo),
          child: const Text('Release Cash'),
        ),
      ],
    );
  }
}
