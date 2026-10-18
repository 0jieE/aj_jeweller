import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/services/export_formats.dart';
import '../../core/services/export_service.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/formatters.dart';

/// Exports one kind of record as a CSV spreadsheet for the branch in view,
/// over a chosen period — previewed first, so what gets sent is what was
/// meant to be sent.
class ExportScreen extends StatefulWidget {
  final ExportKind kind;

  const ExportScreen({super.key, required this.kind});

  @override
  State<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends State<ExportScreen> {
  // This month so far — the period a bookkeeper most often asks for.
  late DateTimeRange? _range = () {
    final now = DateTime.now();
    return DateTimeRange(start: DateTime(now.year, now.month, 1), end: DateTime(now.year, now.month, now.day));
  }();
  bool _sharing = false;
  ExportFormat _format = ExportFormat.excel;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final branch = context.watch<AppState>().selectedBranch;
    final table = ExportService.build(repo, widget.kind, branch: branch, range: _range);
    final filename = ExportService.filename(widget.kind, branch, _range, _format);

    return Scaffold(
      appBar: AppBar(title: Text('Export ${widget.kind.label}')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.md),
        children: [
          Row(
            children: [
              DateRangeChip(range: _range, onChanged: (v) => setState(() => _range = v)),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: Text(
                  branch == null ? 'Both branches' : '${branch.label} branch',
                  textAlign: TextAlign.right,
                  style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.md),
          Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.cardSurface,
              borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
              border: Border.all(color: AppColors.outline),
            ),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.primaryBlue.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                  ),
                  child: Icon(widget.kind.icon, color: AppColors.primaryBlue),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${table.rows.length} row(s)', style: AppTextStyles.titleMedium),
                      Text(
                        _range == null
                            ? 'All dates'
                            : '${AppFormat.dateShort(_range!.start)} – ${AppFormat.dateShort(_range!.end)}',
                        style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('Total', style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary)),
                    Text(AppFormat.peso(table.totalCentavos), style: AppTextStyles.numericMedium),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Text('File format', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          Container(
            decoration: BoxDecoration(
              color: AppColors.cardSurface,
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              children: [
                for (final format in ExportFormat.values) ...[
                  if (format != ExportFormat.values.first) const Divider(height: 1),
                  InkWell(
                    onTap: () => setState(() => _format = format),
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      child: Row(
                        children: [
                          Icon(
                            _format == format
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            color: _format == format ? AppColors.primaryBlue : AppColors.textDisabled,
                            size: 22,
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Icon(format.icon, size: 18, color: AppColors.textSecondary),
                          const SizedBox(width: AppSpacing.sm),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(format.label, style: AppTextStyles.bodyLarge),
                                Text(
                                  format.description,
                                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          FilledButton.icon(
            onPressed: table.rows.isEmpty || _sharing
                ? null
                : () async {
                    final messenger = ScaffoldMessenger.of(context);
                    setState(() => _sharing = true);
                    try {
                      await ExportService.share(
                        table,
                        filename,
                        kind: widget.kind,
                        format: _format,
                        branch: branch,
                        range: _range,
                      );
                    } catch (error) {
                      messenger.showSnackBar(SnackBar(content: Text('Could not export: $error')));
                    } finally {
                      if (mounted) setState(() => _sharing = false);
                    }
                  },
            icon: _sharing
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.ios_share_rounded),
            label: Text(table.rows.isEmpty ? 'Nothing to export' : 'Export ${_format.label}'),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            filename,
            textAlign: TextAlign.center,
            style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
          ),
          const SizedBox(height: AppSpacing.lg),
          Text('Preview', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          if (table.rows.isEmpty)
            Text(
              'No ${widget.kind.label.toLowerCase()} in this period. Widen the date range.',
              style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                border: Border.all(color: AppColors.outline),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowHeight: 36,
                  dataRowMinHeight: 32,
                  dataRowMaxHeight: 40,
                  columnSpacing: AppSpacing.md,
                  headingTextStyle: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
                  columns: [for (final h in table.headers) DataColumn(label: Text(h))],
                  rows: [
                    for (final row in table.rows.take(20))
                      DataRow(cells: [for (final c in row) DataCell(Text(c, style: AppTextStyles.bodyMedium))]),
                  ],
                ),
              ),
            ),
          if (table.rows.length > 20)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.xs),
              child: Text(
                'Showing the first 20 of ${table.rows.length} rows — the export has them all.',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}
