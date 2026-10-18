import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/data/staff_directory.dart';
import '../../core/models/app_user.dart';
import '../../core/models/transaction_log.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/date_range_chip.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/filter_menu_chip.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/record_activity.dart';
import '../../core/widgets/search_field.dart';
import 'log_detail_screen.dart';

/// Everything anyone has done in the shop, newest first: who, what, when,
/// and to which record.
///
/// Filterable by area, by person, and by date, because the questions asked of
/// a log are narrow ones — "what did Grace release yesterday?", "who touched
/// this lot?" — not "show me everything".
class TransactionLogsScreen extends StatefulWidget {
  const TransactionLogsScreen({super.key});

  @override
  State<TransactionLogsScreen> createState() => _TransactionLogsScreenState();
}

class _TransactionLogsScreenState extends State<TransactionLogsScreen> {
  String _query = '';
  LogCategory? _category;
  AppUser? _person;
  DateTimeRange? _dateRange;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final branchId = context.watch<AppState>().selectedBranch;

    var logs = repo.logsForBranch(branchId);
    if (_category != null) {
      logs = logs.where((l) => l.action.category == _category).toList();
    }
    if (_person != null) {
      logs = logs.where((l) => l.userId == _person!.id).toList();
    }
    if (_dateRange != null) {
      logs = logs.where((l) {
        final d = DateTime(l.at.year, l.at.month, l.at.day);
        return !d.isBefore(_dateRange!.start) && !d.isAfter(_dateRange!.end);
      }).toList();
    }
    final q = _query.trim().toLowerCase();
    if (q.isNotEmpty) {
      logs = logs
          .where(
            (l) =>
                l.summary.toLowerCase().contains(q) ||
                l.userName.toLowerCase().contains(q) ||
                (l.recordId ?? '').toLowerCase().contains(q) ||
                l.action.label.toLowerCase().contains(q),
          )
          .toList();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction Logs')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.md,
              AppSpacing.md,
              0,
            ),
            child: SearchField(
              hintText: 'Search by action, person, or record id',
              onChanged: (v) => setState(() => _query = v),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.xs,
              ),
              children: [
                FilterMenuChip<LogCategory>(
                  label: _category?.label ?? 'All areas',
                  active: _category != null,
                  allLabel: 'All areas',
                  values: LogCategory.values,
                  labelOf: (c) => c.label,
                  onChanged: (v) => setState(() => _category = v),
                ),
                const SizedBox(width: AppSpacing.sm),
                FilterMenuChip<AppUser>(
                  label: _person?.name ?? 'All staff',
                  active: _person != null,
                  allLabel: 'All staff',
                  values: StaffDirectory.all,
                  labelOf: (u) => '${u.name} · ${u.role.shortLabel}',
                  onChanged: (v) => setState(() => _person = v),
                ),
                const SizedBox(width: AppSpacing.sm),
                DateRangeChip(
                  range: _dateRange,
                  onChanged: (v) => setState(() => _dateRange = v),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.xs,
              AppSpacing.md,
              AppSpacing.xs,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${logs.length} entr${logs.length == 1 ? 'y' : 'ies'}'
                '${branchId == null ? ' · both branches' : ' · ${branchId.label}'}',
                style: AppTextStyles.caption.copyWith(
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
          Expanded(
            child: logs.isEmpty
                ? const EmptyState(
                    icon: Icons.history_rounded,
                    title: 'No entries match',
                    message:
                        'Every purchase, release, sale, disposal, and correction is recorded here.',
                  )
                : ListView.builder(
                    padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                    itemCount: logs.length,
                    itemBuilder: (context, i) {
                      final entry = logs[i];
                      final showDay =
                          i == 0 || !_sameDay(logs[i - 1].at, entry.at);
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (showDay) _DayHeader(day: entry.at),
                          _LogTile(entry: entry),
                        ],
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _DayHeader extends StatelessWidget {
  final DateTime day;

  const _DayHeader({required this.day});

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(day.year, day.month, day.day);
    final label = d == today
        ? 'Today'
        : d == today.subtract(const Duration(days: 1))
        ? 'Yesterday'
        : AppFormat.dateShort(day);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.md,
        AppSpacing.xs,
      ),
      child: Text(
        label.toUpperCase(),
        style: AppTextStyles.labelSmall.copyWith(
          color: AppColors.textSecondary,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _LogTile extends StatelessWidget {
  final TransactionLog entry;

  const _LogTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final color = logCategoryColor(context, entry.action.category);
    final time = TimeOfDay.fromDateTime(entry.at).format(context);

    return InkWell(
      onTap: () => Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => LogDetailScreen(entry: entry))),
      // A uniform border with the category colour as a separate strip. A
      // rounded box whose sides are different colours cannot be painted —
      // Flutter throws while drawing it, and on a device the row came out
      // blank.
      child: Container(
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: 3,
        ),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: AppColors.cardSurface,
          borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
          border: Border.all(color: AppColors.outline),
        ),
        child: IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(width: 3, color: color),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.sm + 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(
                            AppSpacing.badgeRadius,
                          ),
                        ),
                        child: Icon(entry.action.icon, size: 17, color: color),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.action.label,
                                    style: AppTextStyles.bodyMedium.copyWith(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                Text(
                                  time,
                                  style: AppTextStyles.caption.copyWith(
                                    color: AppColors.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              entry.summary,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.bodyMedium,
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '${entry.userName} · ${entry.role.shortLabel}'
                              '${entry.branch == null ? '' : ' · ${entry.branch!.label}'}'
                              '${entry.changes.isEmpty ? '' : ' · ${entry.changes.length} change(s)'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: AppTextStyles.caption.copyWith(
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
