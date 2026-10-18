import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/gold_rate.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/numeric_input_field.dart';
import '../../core/widgets/status_badges.dart';
import 'rate_change_tile.dart';
import 'rate_history_screen.dart';

/// Gold and silver rates in two tabs: the table as it stands, and the
/// history of every price set — filterable by date and purity, with a way to
/// put a past price back. Admins can also add a purity and edit a price.
class GoldRateReferenceScreen extends StatefulWidget {
  const GoldRateReferenceScreen({super.key});

  @override
  State<GoldRateReferenceScreen> createState() => _GoldRateReferenceScreenState();
}

class _GoldRateReferenceScreenState extends State<GoldRateReferenceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() {
      if (!_tabs.indexIsChanging) setState(() {});
    });

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final role = context.watch<AppState>().role;
    final editable = role.canManageCommitmentsAndRates;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Gold & Silver Rates'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white70,
          indicatorColor: Colors.white,
          tabs: const [
            Tab(text: 'Rates'),
            Tab(text: 'History'),
          ],
        ),
      ),
      floatingActionButton: editable && _tabs.index == 0
          ? FloatingActionButton.extended(
              onPressed: () => _addRate(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add Rate'),
            )
          : null,
      body: TabBarView(
        controller: _tabs,
        children: [
          _RatesTab(editable: editable),
          _HistoryTab(editable: editable),
        ],
      ),
    );
  }

  Future<void> _addRate(BuildContext context) async {
    final added = await showDialog<GoldRate>(
      context: context,
      builder: (_) => const _AddRateDialog(),
    );
    if (added != null && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${rateName(added.karat)} rate added.')),
      );
    }
  }
}

class _RatesTab extends StatelessWidget {
  final bool editable;

  const _RatesTab({required this.editable});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();

    Widget card(GoldRate r) => _RateCard(
          rate: r,
          changeCount: repo.rateHistory(r.karat).length,
          editable: editable,
          onEdit: () => editRate(context, r),
          onOpen: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => RateHistoryScreen(karat: r.karat)),
          ),
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
      children: [
        Text('Gold', style: AppTextStyles.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        for (final r in repo.goldRates) card(r),
        const SizedBox(height: AppSpacing.md),
        Text('Silver', style: AppTextStyles.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        if (repo.silverRates.isEmpty)
          Text(
            'No silver rates yet.',
            style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
          ),
        for (final r in repo.silverRates) card(r),
      ],
    );
  }
}

/// The rate table as it stood on one chosen day, gold and silver, next to
/// today's prices — with one button per metal to bring that whole day's
/// table back as the current rates.
class _HistoryTab extends StatefulWidget {
  final bool editable;

  const _HistoryTab({required this.editable});

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> with AutomaticKeepAliveClientMixin {
  late DateTime _day = _dateOnly(DateTime.now());

  // The chosen day survives swiping over to Rates and back.
  @override
  bool get wantKeepAlive => true;

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  Future<void> _pickDay(AppRepository repo) async {
    final history = repo.allRateHistory;
    final today = _dateOnly(DateTime.now());
    final earliest = history.isEmpty ? today : _dateOnly(history.last.at);
    final picked = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: earliest,
      lastDate: today,
      helpText: 'Show rates as of',
    );
    if (picked != null) setState(() => _day = _dateOnly(picked));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final repo = context.watch<AppRepository>();
    final changesThatDay = repo.rateChangesOn(_day);
    final isToday = _day == _dateOnly(DateTime.now());

    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, AppSpacing.xl),
      children: [
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _pickDay(repo),
                icon: const Icon(Icons.calendar_today_rounded, size: 18),
                label: Text(isToday ? 'Today · ${AppFormat.dateShort(_day)}' : AppFormat.dateShort(_day)),
              ),
            ),
            if (!isToday) ...[
              const SizedBox(width: AppSpacing.sm),
              TextButton(
                onPressed: () => setState(() => _day = _dateOnly(DateTime.now())),
                child: const Text('Today'),
              ),
            ],
          ],
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Rates in force at the close of this day. '
          '${changesThatDay.isEmpty ? 'No prices were changed on it.' : '${changesThatDay.length} price change(s) were made on it.'}',
          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: AppSpacing.md),
        _DaySection(day: _day, silver: false, editable: widget.editable),
        const SizedBox(height: AppSpacing.lg),
        _DaySection(day: _day, silver: true, editable: widget.editable),
        if (changesThatDay.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.lg),
          Text('Changes Made This Day', style: AppTextStyles.titleMedium),
          const SizedBox(height: AppSpacing.sm),
          Container(
            decoration: BoxDecoration(
              color: AppColors.cardSurface,
              borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              children: [
                for (var i = 0; i < changesThatDay.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  RateChangeTile(change: changesThatDay[i], showPurity: true),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// One metal's table on the chosen day, and the button that makes it current.
class _DaySection extends StatelessWidget {
  final DateTime day;
  final bool silver;
  final bool editable;

  const _DaySection({required this.day, required this.silver, required this.editable});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final rates = silver ? repo.silverRates : repo.goldRates;
    final metal = silver ? 'Silver' : 'Gold';
    final rows = [
      for (final r in rates) (rate: r, then: repo.rateOn(r.karat, day)),
    ];
    final differing = rows.where((row) => row.then != null && row.then != row.rate.pricePerGramCentavos).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(metal, style: AppTextStyles.titleMedium),
        const SizedBox(height: AppSpacing.sm),
        Container(
          decoration: BoxDecoration(
            color: AppColors.cardSurface,
            borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
            border: Border.all(color: AppColors.outline),
          ),
          child: Column(
            children: [
              for (var i = 0; i < rows.length; i++) ...[
                if (i > 0) const Divider(height: 1),
                _DayRateRow(karat: rows[i].rate.karat, then: rows[i].then, now: rows[i].rate.pricePerGramCentavos),
              ],
              if (rows.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: Text('No ${metal.toLowerCase()} rates.', style: AppTextStyles.bodyMedium),
                ),
            ],
          ),
        ),
        if (editable) ...[
          const SizedBox(height: AppSpacing.sm),
          FilledButton.icon(
            onPressed: differing.isEmpty
                ? null
                : () => _confirmApply(context, repo, [for (final d in differing) (karat: d.rate.karat, from: d.rate.pricePerGramCentavos, to: d.then!)]),
            icon: const Icon(Icons.restore_rounded, size: 18),
            label: Text(
              differing.isEmpty
                  ? '$metal rates already match this day'
                  : 'Use $metal Rates from ${AppFormat.dateShort(day)}',
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _confirmApply(
    BuildContext context,
    AppRepository repo,
    List<({int karat, int from, int to})> changes,
  ) async {
    final metal = silver ? 'silver' : 'gold';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Use $metal rates from ${AppFormat.dateShort(day)}?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${changes.length} rate(s) will change:', style: AppTextStyles.bodyMedium),
            const SizedBox(height: AppSpacing.sm),
            for (final c in changes)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: [
                    SizedBox(width: 48, child: KaratBadge(karat: c.karat)),
                    const SizedBox(width: AppSpacing.sm),
                    Expanded(
                      child: Text(
                        '${AppFormat.peso(c.from)} → ${AppFormat.peso(c.to)}',
                        style: AppTextStyles.numericSmall,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Each is added to the history as a new change; nothing earlier is erased.',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Use These Rates'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final count = repo.applyRatesFrom(day, silver: silver, actor: context.read<AppState>().currentUser);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('$count $metal rate(s) set from ${AppFormat.dateShort(day)}.')),
    );
  }
}

/// A rate on the chosen day beside what it is now.
class _DayRateRow extends StatelessWidget {
  final int karat;
  final int? then;
  final int now;

  const _DayRateRow({required this.karat, required this.then, required this.now});

  @override
  Widget build(BuildContext context) {
    final sc = context.semanticColors;
    final palette = PurityPalette.of(context, karat);
    final diff = then == null ? 0 : now - then!;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
      child: Row(
        children: [
          SizedBox(width: 48, child: KaratBadge(karat: karat)),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: then == null
                ? Text(
                    'Not set yet',
                    style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textDisabled),
                  )
                : Text(
                    AppFormat.peso(then!),
                    style: AppTextStyles.numericMedium.copyWith(color: palette.text),
                  ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                'Now ${AppFormat.peso(now)}',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
              if (then != null)
                Text(
                  diff == 0 ? 'Same as now' : '${AppFormat.pesoSigned(diff)} since',
                  style: AppTextStyles.caption.copyWith(
                    color: diff == 0 ? AppColors.textSecondary : (diff > 0 ? sc.success : sc.danger),
                    fontWeight: FontWeight.w600,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String rateName(int karat) => isSilverPurity(karat) ? '$karat silver' : '$karat-karat gold';

/// Edits one rate's price. Shared by the table and the history screen.
Future<void> editRate(BuildContext context, GoldRate rate) async {
  final repo = context.read<AppRepository>();
  double? newValue = rate.pricePerGramCentavos / 100;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text('Edit ${rateName(rate.karat)} rate'),
      content: NumericInputField(
        label: 'Price per gram',
        kind: NumericInputKind.peso,
        initialValue: rate.pricePerGramCentavos / 100,
        autofocus: true,
        helperText: 'Currently ${AppFormat.peso(rate.pricePerGramCentavos)}',
        onChanged: (v) => newValue = v,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Save'),
        ),
      ],
    ),
  );

  if (confirmed != true || newValue == null || newValue! <= 0 || !context.mounted) return;
  final cents = (newValue! * 100).round();
  final messenger = ScaffoldMessenger.of(context);
  if (cents == rate.pricePerGramCentavos) {
    messenger.showSnackBar(const SnackBar(content: Text('Price unchanged.')));
    return;
  }
  repo.updateGoldRate(rate.karat, cents, actor: context.read<AppState>().currentUser);
  messenger.showSnackBar(SnackBar(content: Text('${rateName(rate.karat)} rate updated.')));
}

class _AddRateDialog extends StatefulWidget {
  const _AddRateDialog();

  @override
  State<_AddRateDialog> createState() => _AddRateDialogState();
}

class _AddRateDialogState extends State<_AddRateDialog> {
  bool _silver = false;
  final _purity = TextEditingController();
  int? _priceCentavos;

  @override
  void dispose() {
    _purity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final purity = int.tryParse(_purity.text.trim());
    // Checked as the number is typed, so a duplicate is explained before
    // anyone presses Add — not refused after.
    final problem = purity == null ? null : repo.rateAddProblem(purity, silver: _silver);
    final existing = purity == null ? null : repo.rateForKarat(purity);
    final canAdd = purity != null && problem == null && (_priceCentavos ?? 0) > 0;
    final taken = (_silver ? repo.silverRates : repo.goldRates).map((r) => AppFormat.karat(r.karat)).join(', ');

    return AlertDialog(
      title: const Text('Add Rate'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('Gold')),
                ButtonSegment(value: true, label: Text('Silver')),
              ],
              selected: {_silver},
              onSelectionChanged: (s) => setState(() => _silver = s.first),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _purity,
              autofocus: true,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(3),
              ],
              decoration: InputDecoration(
                labelText: _silver ? 'Fineness' : 'Karat',
                hintText: _silver ? 'e.g. 950' : 'e.g. 16',
                suffixText: _silver ? null : 'K',
                errorText: problem,
                errorMaxLines: 3,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (existing != null) ...[
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Current price: ${AppFormat.peso(existing.pricePerGramCentavos)}/g',
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
            ],
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Already priced: ${taken.isEmpty ? 'none' : taken}',
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            NumericInputField(
              label: 'Price per gram',
              kind: NumericInputKind.peso,
              onChanged: (v) => setState(() => _priceCentavos = v == null ? null : (v * 100).round()),
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
          onPressed: canAdd
              ? () {
                  try {
                    final rate = repo.addRate(
                      purity,
                      _priceCentavos!,
                      silver: _silver,
                      actor: context.read<AppState>().currentUser,
                    );
                    Navigator.of(context).pop(rate);
                  } on ArgumentError catch (error) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(error.message.toString())),
                    );
                  }
                }
              : null,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

class _RateCard extends StatelessWidget {
  final GoldRate rate;
  final int changeCount;
  final bool editable;
  final VoidCallback onEdit;
  final VoidCallback onOpen;

  const _RateCard({
    required this.rate,
    required this.changeCount,
    required this.editable,
    required this.onEdit,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final palette = PurityPalette.of(context, rate.karat);
    return Card(
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: AppSpacing.sm),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: palette.surface,
                  borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                ),
                child: Text(
                  AppFormat.karat(rate.karat),
                  style: AppTextStyles.numericBody.copyWith(color: palette.text, fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(rateName(rate.karat), style: AppTextStyles.bodyLarge),
                    Text(
                      '$changeCount price change${changeCount == 1 ? '' : 's'} · history',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                  ],
                ),
              ),
              Text(
                AppFormat.peso(rate.pricePerGramCentavos),
                style: AppTextStyles.numericMedium.copyWith(color: palette.text),
              ),
              if (editable)
                IconButton(
                  icon: const Icon(Icons.edit_outlined),
                  color: AppColors.textSecondary,
                  tooltip: 'Edit rate',
                  onPressed: onEdit,
                )
              else
                const Icon(Icons.chevron_right_rounded, color: AppColors.textDisabled),
            ],
          ),
        ),
      ),
    );
  }
}
