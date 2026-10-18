import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/app_user.dart';
import '../../core/models/branch.dart';
import '../../core/models/user_role.dart';
import '../../core/state/app_state.dart';
import '../auth/session_actions.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/record_activity.dart';
import '../../core/navigation/layout.dart';

/// Adds a staff member, or shows and edits one — with deactivate and delete
/// for Admins. Non-admins see the details read-only.
class UserFormScreen extends StatefulWidget {
  /// Null to add a new user.
  final String? userId;

  const UserFormScreen({super.key, this.userId});

  @override
  State<UserFormScreen> createState() => _UserFormScreenState();
}

class _UserFormScreenState extends State<UserFormScreen> {
  late final TextEditingController _name;
  late final TextEditingController _contact;
  AppUserRole _role = AppUserRole.cashier;
  BranchId? _branch;
  AppUser? _original;

  bool get _isNew => widget.userId == null;

  @override
  void initState() {
    super.initState();
    final repo = context.read<AppRepository>();
    _original = widget.userId == null ? null : repo.findUser(widget.userId);
    _name = TextEditingController(text: _original?.name ?? '');
    _contact = TextEditingController(text: _original?.contactNumber ?? '');
    _role = _original?.role ?? AppUserRole.cashier;
    _branch = _original?.homeBranch ?? (_isNew ? context.read<AppState>().selectedBranch : null);
  }

  @override
  void dispose() {
    _name.dispose();
    _contact.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final appState = context.watch<AppState>();
    final user = _isNew ? null : repo.findUser(widget.userId);
    // A Supervisor takes on their branch's counter staff; they do not appoint
    // Supervisors, Admins or Superusers. The server refuses that too, so the
    // form never offers it rather than letting it be typed and bounced back.
    final offerable = appState.role.assignableRoles;
    final canManage = appState.role.canManageUsers &&
        (user == null || appState.role.canManageStaffOf(user.role));

    if (!_isNew && user == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: Text('User not found')));
    }

    final nameProblem = _name.text.trim().isEmpty ? null : repo.userNameProblem(_name.text, exceptId: user?.id);
    final needsBranch = !_role.runsTheShop;
    final valid = _name.text.trim().isNotEmpty && nameProblem == null && (!needsBranch || _branch != null);
    final isYou = user != null && user.id == appState.currentUser.id;
    final activity = user == null ? 0 : repo.userActivityCount(user.id);
    final deleteProblem = user == null ? null : repo.userDeleteProblem(user.id, actor: appState.currentUser);

    return Scaffold(
      appBar: AppBar(title: Text(_isNew ? 'Add User' : (canManage ? 'Edit User' : 'User'))),
      body: FormPane(
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.md),
          children: [
            if (user != null) ...[
              Row(
                children: [
                  StaffAvatar(user: user, radius: 26),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(user.name, style: AppTextStyles.titleLarge),
                        Text(
                          '${user.id} · ${user.active ? 'Active' : 'Deactivated'}${isYou ? ' · You' : ''} · $activity record(s)',
                          style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
            ],
            TextField(
              controller: _name,
              enabled: canManage,
              textCapitalization: TextCapitalization.words,
              decoration: InputDecoration(labelText: 'Full name', errorText: nameProblem),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: AppSpacing.md),
            Text('Role', style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary)),
            const SizedBox(height: 4),
            Container(
              decoration: BoxDecoration(
                color: AppColors.cardSurface,
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                border: Border.all(color: AppColors.outline),
              ),
              child: Column(
                children: [
                  for (final role in offerable) ...[
                    if (role != offerable.first) const Divider(height: 1),
                    InkWell(
                      onTap: canManage ? () => setState(() => _role = role) : null,
                      child: Padding(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        child: Row(
                          children: [
                            Icon(
                              _role == role ? Icons.radio_button_checked_rounded : Icons.radio_button_unchecked_rounded,
                              color: _role == role ? AppColors.primaryBlue : AppColors.textDisabled,
                              size: 22,
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(role.label, style: AppTextStyles.bodyLarge),
                                  Text(
                                    role.description,
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
            if (needsBranch)
              DropdownButtonFormField<BranchId>(
                key: ValueKey('branch-$_role'),
                initialValue: _branch,
                decoration: const InputDecoration(labelText: 'Branch'),
                items: [for (final b in BranchId.values) DropdownMenuItem(value: b, child: Text(b.label))],
                onChanged: canManage ? (v) => setState(() => _branch = v) : null,
              )
            else
              Text(
                'An Admin oversees both branches.',
                style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
              ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _contact,
              enabled: canManage,
              keyboardType: TextInputType.phone,
              inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9 +\-]'))],
              decoration: const InputDecoration(labelText: 'Contact number', hintText: 'Optional'),
            ),
            if (canManage) ...[
              const SizedBox(height: AppSpacing.lg),
              FilledButton.icon(
                onPressed: valid ? () => _save(context, repo) : null,
                icon: Icon(_isNew ? Icons.person_add_alt_1_rounded : Icons.save_rounded),
                label: Text(_isNew ? 'Add User' : 'Save Changes'),
              ),
            ],
            if (canManage && user != null) ...[
              const SizedBox(height: AppSpacing.lg),
              const Divider(),
              const SizedBox(height: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: () => showSetPinDialog(context, user),
                icon: const Icon(Icons.password_rounded),
                label: const Text('Set PIN'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: AppSpacing.sm),
                child: Text(
                  'For someone new, or someone who has forgotten theirs. They can '
                  'change it themselves once they are in.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
              OutlinedButton.icon(
                onPressed: isYou && user.active ? null : () => _toggleActive(context, repo, user),
                icon: Icon(user.active ? Icons.person_off_rounded : Icons.how_to_reg_rounded),
                label: Text(user.active ? 'Deactivate' : 'Reactivate'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: AppSpacing.sm),
                child: Text(
                  user.active
                      ? (isYou
                          ? 'You can\'t deactivate yourself — switch to another Admin first.'
                          : 'A deactivated user can\'t be picked to act as, but keeps their name on every record.')
                      : 'Reactivating lets them sign in again.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
              OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.danger,
                  side: BorderSide(color: deleteProblem == null ? AppColors.danger : AppColors.outline),
                ),
                onPressed: deleteProblem == null ? () => _delete(context, repo, user) : null,
                icon: const Icon(Icons.person_remove_rounded),
                label: const Text('Delete'),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  deleteProblem ?? 'Only for someone added by mistake — they have no records yet.',
                  style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                ),
              ),
            ],
            const SizedBox(height: AppSpacing.md),
            Text(
              'Changes are recorded in Transaction Logs.',
              textAlign: TextAlign.center,
              style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  void _save(BuildContext context, AppRepository repo) {
    final appState = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (_isNew) {
        final user = repo.addUser(
          name: _name.text,
          role: _role,
          homeBranch: _branch,
          contactNumber: _contact.text,
          actor: appState.currentUser,
        );
        messenger.showSnackBar(SnackBar(content: Text('${user.name} added.')));
      } else {
        final changes = repo.updateUser(
          widget.userId!,
          name: _name.text,
          role: _role,
          homeBranch: _branch,
          contactNumber: _contact.text,
          actor: appState.currentUser,
        );
        appState.syncWithStaff();
        messenger.showSnackBar(SnackBar(
          content: Text(changes.isEmpty ? 'Nothing changed.' : '${changes.length} change(s) saved.'),
        ));
      }
      Navigator.of(context).pop();
    } on ArgumentError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message.toString())));
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _toggleActive(BuildContext context, AppRepository repo, AppUser user) async {
    final appState = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final deactivating = user.active;
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('${deactivating ? 'Deactivate' : 'Reactivate'} ${user.name}?'),
        content: Text(deactivating
            ? 'They will no longer appear in the user picker. Their records stay as they are.'
            : 'They will be available to pick again.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(d).pop(true),
            child: Text(deactivating ? 'Deactivate' : 'Reactivate'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      repo.setUserActive(user.id, !deactivating, actor: appState.currentUser);
      appState.syncWithStaff();
      messenger.showSnackBar(SnackBar(content: Text('${user.name} ${deactivating ? 'deactivated' : 'reactivated'}.')));
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }

  Future<void> _delete(BuildContext context, AppRepository repo, AppUser user) async {
    final appState = context.read<AppState>();
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (d) => AlertDialog(
        title: Text('Delete ${user.name}?'),
        content: const Text('This removes the user completely. It is logged, but cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(d).pop(false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppColors.danger),
            onPressed: () => Navigator.of(d).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    try {
      repo.deleteUser(user.id, actor: appState.currentUser);
      appState.syncWithStaff();
      navigator.pop();
      messenger.showSnackBar(SnackBar(content: Text('${user.name} deleted.')));
    } on StateError catch (e) {
      messenger.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
