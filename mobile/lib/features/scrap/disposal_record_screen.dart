import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/branch.dart';
import '../../core/models/item.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/numeric_input_field.dart';
import '../../core/widgets/value_display.dart';
import 'disposal_tag_commitment_screen.dart';
import '../../core/navigation/layout.dart';

/// Capital is pulled automatically from the selected records and rendered
/// read-only; gross grams and gross amount are always typed by hand here,
/// because the actual disposal result never matches a theoretical number.
class DisposalRecordScreen extends StatefulWidget {
  final List<String> itemIds;
  final BranchId branch;

  const DisposalRecordScreen({super.key, required this.itemIds, required this.branch});

  @override
  State<DisposalRecordScreen> createState() => _DisposalRecordScreenState();
}

class _DisposalRecordScreenState extends State<DisposalRecordScreen> {
  DateTime _date = DateTime.now();
  double? _grossGrams;
  int? _grossAmountCentavos;

  bool get _isValid => _grossGrams != null && _grossGrams! > 0 && _grossAmountCentavos != null && _grossAmountCentavos! > 0;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final items = [for (final id in widget.itemIds) repo.findItem(id)].whereType<Item>().toList();
    final capitalCentavos = items.fold<int>(0, (sum, i) => sum + i.effectiveRemainingAmountCentavos);
    final totalGrams = items.fold<double>(0, (sum, i) => sum + i.effectiveRemainingGrams);
    final netCentavos = _grossAmountCentavos != null ? _grossAmountCentavos! - capitalCentavos : null;

    return Scaffold(
      appBar: AppBar(title: const Text('Record Disposal')),
      body: FormPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            Text('Batch Composition (${items.length})', style: AppTextStyles.titleMedium),
            const SizedBox(height: AppSpacing.sm),
            Container(
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                border: Border.all(color: AppColors.outline),
              ),
              constraints: const BoxConstraints(maxHeight: 220),
              child: Scrollbar(
                child: ListView.separated(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  shrinkWrap: true,
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, i) => _CompositionRow(item: items[i]),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Nominal weight ${AppFormat.grams(totalGrams)} — for reference only; enter the actual disposal result below.',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ValueDisplay(
              label: 'Capital (pulled from selection)',
              value: AppFormat.peso(capitalCentavos),
              origin: FigureOrigin.derived,
            ),
            const SizedBox(height: AppSpacing.md),
            _DateField(date: _date, onChanged: (d) => setState(() => _date = d)),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              label: 'Gross Grams (actual)',
              kind: NumericInputKind.grams,
              onChanged: (v) => setState(() => _grossGrams = v),
            ),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              label: 'Gross Amount (actual)',
              kind: NumericInputKind.peso,
              onChanged: (v) => setState(() => _grossAmountCentavos = v != null ? (v * 100).round() : null),
            ),
            if (netCentavos != null) ...[
              const SizedBox(height: AppSpacing.md),
              ValueDisplay(
                label: 'Batch Net (shop profit) = Gross − Capital',
                value: AppFormat.pesoSigned(netCentavos),
                origin: FigureOrigin.derived,
                valueColor: netCentavos >= 0 ? context.semanticColors.success : context.semanticColors.danger,
              ),
            ],
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton(
              onPressed: _isValid
                  ? () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => DisposalTagCommitmentScreen(
                            itemIds: widget.itemIds,
                            branch: widget.branch,
                            date: _date,
                            capitalCentavos: capitalCentavos,
                            grossGrams: _grossGrams!,
                            grossAmountCentavos: _grossAmountCentavos!,
                          ),
                        ),
                      )
                  : null,
              child: const Text('Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CompositionRow extends StatelessWidget {
  final Item item;

  const _CompositionRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: AppSpacing.xs),
      child: Row(
        children: [
          Expanded(
            child: Text(
              item.description,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyMedium,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Text(AppFormat.karat(item.karat), style: AppTextStyles.numericSmall.copyWith(color: sc.goldDark)),
          const SizedBox(width: AppSpacing.sm),
          SizedBox(
            width: 70,
            child: Text(
              AppFormat.grams(item.effectiveRemainingGrams),
              textAlign: TextAlign.right,
              style: AppTextStyles.numericSmall,
            ),
          ),
          SizedBox(
            width: 80,
            child: Text(
              AppFormat.peso(item.effectiveRemainingAmountCentavos, whole: true),
              textAlign: TextAlign.right,
              style: AppTextStyles.numericSmall.copyWith(color: AppColors.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}

class _DateField extends StatelessWidget {
  final DateTime date;
  final ValueChanged<DateTime> onChanged;

  const _DateField({required this.date, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: date,
          firstDate: DateTime(now.year - 1),
          lastDate: now,
        );
        if (picked != null) onChanged(picked);
      },
      child: InputDecorator(
        decoration: const InputDecoration(labelText: 'Disposal Date'),
        child: Row(
          children: [
            Expanded(child: Text(AppFormat.dateShort(date), style: AppTextStyles.bodyLarge)),
            const Icon(Icons.calendar_today_rounded, size: 18, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}
