import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/state/app_state.dart';
import '../../core/models/item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/item_photo_field.dart';
import '../../core/widgets/numeric_input_field.dart';

/// Draws a smaller item out of a parent lot. Both grams and amount are
/// drawn down simultaneously and the remaining balance previews live as the
/// user types — over-drawing either figure is blocked with an inline
/// explanation, never a generic error toast.
class CreatePartitionSheet extends StatefulWidget {
  final String parentId;

  const CreatePartitionSheet({super.key, required this.parentId});

  @override
  State<CreatePartitionSheet> createState() => _CreatePartitionSheetState();
}

class _CreatePartitionSheetState extends State<CreatePartitionSheet> {
  final _descriptionController = TextEditingController();
  ItemType? _type;
  double? _grams;
  int? _amountCentavos;
  Uint8List? _photo;

  @override
  void dispose() {
    _descriptionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final parent = repo.findItem(widget.parentId);

    if (parent == null) {
      return const SizedBox(height: 120, child: Center(child: Text('Lot not found')));
    }

    _type ??= parent.type;
    final remainingGrams = parent.effectiveRemainingGrams;
    final remainingAmount = parent.effectiveRemainingAmountCentavos;

    final gramsError = _grams != null && _grams! > remainingGrams
        ? 'Only ${AppFormat.grams(remainingGrams)} remain on this lot — reduce the weight.'
        : null;
    final amountError = _amountCentavos != null && _amountCentavos! > remainingAmount
        ? 'Only ${AppFormat.peso(remainingAmount)} remain on this lot — reduce the amount.'
        : null;

    final previewGrams = (remainingGrams - (_grams ?? 0)).clamp(0, remainingGrams);
    final previewAmount = (remainingAmount - (_amountCentavos ?? 0)).clamp(0, remainingAmount);

    final isValid = _descriptionController.text.trim().isNotEmpty &&
        _grams != null &&
        _grams! > 0 &&
        gramsError == null &&
        _amountCentavos != null &&
        _amountCentavos! > 0 &&
        amountError == null;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        expand: false,
        builder: (context, scrollController) {
          return ListView(
            controller: scrollController,
            padding: const EdgeInsets.all(AppSpacing.md),
            children: [
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: AppSpacing.md),
                  decoration: BoxDecoration(color: AppColors.outline, borderRadius: BorderRadius.circular(2)),
                ),
              ),
              Text('Create Partition', style: AppTextStyles.headlineMedium.copyWith(fontSize: 19)),
              const SizedBox(height: 2),
              Text(
                'From "${parent.description}"',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.md),
              _RemainingCard(remainingGrams: remainingGrams, remainingAmount: remainingAmount),
              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _descriptionController,
                decoration: const InputDecoration(labelText: 'Description'),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: AppSpacing.md),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Type', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
                  const SizedBox(height: 6),
                  SegmentedButton<ItemType>(
                    // A partition is the same metal as its lot.
                    segments: [
                      for (final t in ItemType.values)
                        ButtonSegment(
                          value: t,
                          label: Text(t.label),
                          enabled: t.isSilver == parent.type.isSilver,
                        ),
                    ],
                    selected: {_type!},
                    onSelectionChanged: (s) => setState(() => _type = s.first),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              NumericInputField(
                label: 'Weight to draw',
                kind: NumericInputKind.grams,
                onChanged: (v) => setState(() => _grams = v),
              ),
              if (gramsError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(gramsError, style: AppTextStyles.caption.copyWith(color: AppColors.danger)),
                ),
              const SizedBox(height: AppSpacing.md),
              NumericInputField(
                label: 'Amount to draw',
                kind: NumericInputKind.peso,
                onChanged: (v) => setState(() => _amountCentavos = v != null ? (v * 100).round() : null),
              ),
              if (amountError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(amountError, style: AppTextStyles.caption.copyWith(color: AppColors.danger)),
                ),
              const SizedBox(height: AppSpacing.md),
              ItemPhotoField(
                photo: _photo,
                label: 'Partition photo',
                caption: 'Filed with this partition — shows the piece that was drawn out.',
                onChanged: (bytes) => setState(() => _photo = bytes),
              ),
              const SizedBox(height: AppSpacing.md),
              _PreviewCard(previewGrams: previewGrams.toDouble(), previewAmount: previewAmount.toInt()),
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(
                onPressed: isValid
                    ? () {
                        final messenger = ScaffoldMessenger.of(context);
                        repo.createPartition(
                          actor: context.read<AppState>().currentUser,
                          parentId: parent.id,
                          description: _descriptionController.text.trim(),
                          type: _type!,
                          weightGrams: _grams!,
                          amountCentavos: _amountCentavos!,
                          photo: _photo,
                        );
                        Navigator.of(context).pop();
                        messenger.showSnackBar(
                          const SnackBar(content: Text('Partition created.')),
                        );
                      }
                    : null,
                child: const Text('Create Partition'),
              ),
              const SizedBox(height: AppSpacing.md),
            ],
          );
        },
      ),
    );
  }
}

class _RemainingCard extends StatelessWidget {
  final double remainingGrams;
  final int remainingAmount;

  const _RemainingCard({required this.remainingGrams, required this.remainingAmount});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      decoration: BoxDecoration(
        color: AppColors.surfaceDim,
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Figure(label: 'Remaining on lot', value: AppFormat.grams(remainingGrams)),
          ),
          Expanded(
            child: _Figure(label: ' ', value: AppFormat.peso(remainingAmount, whole: true)),
          ),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  final double previewGrams;
  final int previewAmount;

  const _PreviewCard({required this.previewGrams, required this.previewAmount});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm + 2),
      decoration: BoxDecoration(
        color: AppColors.primaryBlue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
        border: Border.all(color: AppColors.primaryBlue.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: _Figure(
              label: 'Remaining after this draw',
              value: AppFormat.grams(previewGrams),
              color: AppColors.primaryBlue,
            ),
          ),
          Expanded(
            child: _Figure(
              label: ' ',
              value: AppFormat.peso(previewAmount, whole: true),
              color: AppColors.primaryBlue,
            ),
          ),
        ],
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
        Text(value, style: AppTextStyles.numericBody.copyWith(color: color ?? AppColors.textPrimary)),
      ],
    );
  }
}
