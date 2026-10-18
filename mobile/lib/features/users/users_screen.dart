import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/app_user.dart';
import '../../core/models/branch.dart';
import '../../core/state/app_state.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/search_field.dart';
import 'user_form_screen.dart';
import '../../core/navigation/layout.dart';

/// The shop's staff, grouped by where they work. Admins can add people, edit
/// them, and deactivate or delete them; everyone else can look.
class UsersScreen extends StatefulWidget {
  const UsersScreen({super.key});

  @override
  State<UsersScreen> createState() => _UsersScreenState();
}

class _UsersScreenState extends State<UsersScreen> {
  String _query = '';
  bool _showInactive = false;

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final appState = context.watch<AppState>();
    final canManage = appState.role.canManageUsers;

    final q = _query.trim().toLowerCase();
    var users = repo.allUsers.where((u) => _showInactive || u.active).toList();
    if (q.isNotEmpty) {
      users = users
          .where((u) =>
              u.name.toLowerCase().contains(q) ||
              u.role.label.toLowerCase().contains(q) ||
              (u.contactNumber ?? '').contains(q))
          .toList();
    }
    users.sort((a, b) {
      final byRole = b.role.index.compareTo(a.role.index);
      return byRole != 0 ? byRole : a.name.compareTo(b.name);
    });
    final inactiveCount = repo.allUsers.where((u) => !u.active).length;

    // Admins oversee both branches; everyone else sits under their branch.
    final groups = <String, List<AppUser>>{
      'Both branches': users.where((u) => u.homeBranch == null).toList(),
      for (final b in BranchId.values) b.label: users.where((u) => u.homeBranch == b).toList(),
    }..removeWhere((_, list) => list.isEmpty);

    return Scaffold(
      appBar: AppBar(title: const Text('Users')),
      floatingActionButton: canManage
          ? FloatingActionButton.extended(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const UserFormScreen()),
              ),
              icon: const Icon(Icons.person_add_alt_1_rounded),
              label: const Text('Add User'),
            )
          : null,
      body: ReadableWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(AppSpacing.md, AppSpacing.md, AppSpacing.md, 96),
          children: [
            SearchField(
              hintText: 'Search by name, role, or number',
              onChanged: (v) => setState(() => _query = v),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${repo.users.length} active${inactiveCount == 0 ? '' : ' · $inactiveCount deactivated'}',
                    style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                  ),
                ),
                if (inactiveCount > 0)
                  FilterChip(
                    label: const Text('Show deactivated'),
                    selected: _showInactive,
                    onSelected: (v) => setState(() => _showInactive = v),
                  ),
              ],
            ),
            if (!canManage)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.xs),
                child: Text(
                  'Only an Admin can add or change users.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
            if (groups.isEmpty)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: Text('No users match.', textAlign: TextAlign.center, style: AppTextStyles.bodyMedium),
              ),
            for (final entry in groups.entries) ...[
              const SizedBox(height: AppSpacing.md),
              Text(entry.key.toUpperCase(), style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary, letterSpacing: 0.6)),
              const SizedBox(height: AppSpacing.xs),
              Container(
                decoration: BoxDecoration(
                  color: AppColors.cardSurface,
                  borderRadius: BorderRadius.circular(AppSpacing.cardRadius),
                  border: Border.all(color: AppColors.outline),
                ),
                child: Column(
                  children: [
                    for (var i = 0; i < entry.value.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _UserTile(
                        user: entry.value[i],
                        isYou: entry.value[i].id == appState.currentUser.id,
                        activity: repo.userActivityCount(entry.value[i].id),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  final AppUser user;
  final bool isYou;
  final int activity;

  const _UserTile({required this.user, required this.isYou, required this.activity});

  @override
  Widget build(BuildContext context) {
    final muted = !user.active;
    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => UserFormScreen(userId: user.id)),
      ),
      leading: CircleAvatar(
        backgroundColor: (muted ? AppColors.textDisabled : AppColors.primaryBlue).withValues(alpha: 0.12),
        child: Text(
          user.initials,
          style: AppTextStyles.labelSmall.copyWith(
            color: muted ? AppColors.textDisabled : AppColors.primaryBlue,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              user.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTextStyles.bodyLarge.copyWith(
                fontWeight: FontWeight.w600,
                color: muted ? AppColors.textDisabled : AppColors.textPrimary,
              ),
            ),
          ),
          if (isYou) ...[
            const SizedBox(width: AppSpacing.xs),
            const _Tag(label: 'YOU', color: AppColors.primaryBlue),
          ],
          if (muted) ...[
            const SizedBox(width: AppSpacing.xs),
            const _Tag(label: 'DEACTIVATED', color: AppColors.textSecondary),
          ],
        ],
      ),
      subtitle: Text(
        [
          user.role.label,
          if (user.contactNumber != null) user.contactNumber!,
          '$activity record(s)',
        ].join(' · '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: const Icon(Icons.chevron_right_rounded, color: AppColors.textDisabled),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  final Color color;

  const _Tag({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
      ),
      child: Text(label, style: AppTextStyles.labelSmall.copyWith(color: color, fontSize: 10)),
    );
  }
}
