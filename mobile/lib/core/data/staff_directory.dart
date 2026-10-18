import '../models/app_user.dart';
import '../models/branch.dart';
import '../models/user_role.dart';

/// The shop's staff, as a lookup every screen and record can reach.
///
/// The people themselves are records owned by [AppRepository] — added,
/// edited, deactivated, and saved with the rest of the shop's data — which
/// keeps this directory in step through [replaceAll]. It stays a static
/// lookup because attribution is needed everywhere, including places with no
/// repository at hand (receipts, exports, seeded history).
///
/// Staff survive a demo reset: a cleared or reseeded shop still has the same
/// people working in it.
class StaffDirectory {
  StaffDirectory._();

  /// Who works here on a fresh install.
  static const List<AppUser> seed = [
    AppUser(
      id: 'USR-AJ01',
      name: 'Arnel Javier',
      role: AppUserRole.admin,
    ),
    AppUser(
      id: 'USR-K-APR',
      name: 'Liza Mendoza',
      role: AppUserRole.assistantAppraiser,
      homeBranch: BranchId.kidapawan,
    ),
    AppUser(
      id: 'USR-K-REP',
      name: 'Rhea Castillo',
      role: AppUserRole.salesRep,
      homeBranch: BranchId.kidapawan,
    ),
    AppUser(
      id: 'USR-K-CSH',
      name: 'Grace Ramos',
      role: AppUserRole.cashier,
      homeBranch: BranchId.kidapawan,
    ),
    AppUser(
      id: 'USR-D-APR',
      name: 'Joel Bautista',
      role: AppUserRole.assistantAppraiser,
      homeBranch: BranchId.davao,
    ),
    AppUser(
      id: 'USR-D-REP',
      name: 'Paolo Delos Reyes',
      role: AppUserRole.salesRep,
      homeBranch: BranchId.davao,
    ),
    AppUser(
      id: 'USR-D-CSH',
      name: 'Ben Soriano',
      role: AppUserRole.cashier,
      homeBranch: BranchId.davao,
    ),
  ];

  static List<AppUser> _users = List.of(seed);

  /// Called by the repository whenever the staff records change.
  static void replaceAll(List<AppUser> users) => _users = List.of(users);

  /// Staff who can currently act — the people offered in pickers.
  static List<AppUser> get all => List.unmodifiable(_users.where((u) => u.active));

  /// Everyone on file, including people who have left.
  static List<AppUser> get everyone => List.unmodifiable(_users);

  /// Finds anyone on file, active or not — a record keeps naming whoever
  /// made it after they leave.
  static AppUser? byId(String? id) {
    if (id == null) return null;
    for (final user in _users) {
      if (user.id == id) return user;
    }
    return null;
  }

  /// The admin — the default person the app opens as.
  static AppUser get admin {
    for (final user in _users) {
      if (user.active && user.role == AppUserRole.admin) return user;
    }
    return _users.firstWhere((u) => u.active, orElse: () => _users.first);
  }

  /// Who holds [role] at [branch]: the branch's own active staff member when
  /// there is one, otherwise anyone active in that role, otherwise the Admin
  /// (who can do every job).
  static AppUser forRole(AppUserRole role, {BranchId? branch}) {
    for (final user in _users) {
      if (user.active && user.role == role && user.homeBranch == branch) return user;
    }
    for (final user in _users) {
      if (user.active && user.role == role) return user;
    }
    return admin;
  }
}
