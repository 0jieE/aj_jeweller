import 'package:flutter/foundation.dart';

import '../data/app_repository.dart';
import '../data/staff_directory.dart';
import '../models/app_user.dart';
import '../models/branch.dart';
import '../models/user_role.dart';

/// Who is using the app, and which branch they are looking at.
///
/// Who it is comes from signing in with a PIN; every screen reads the person,
/// their role and the branch through this one class. The role here is only
/// what the app offers — the server decides what it actually allows — so it
/// has to follow a promotion or a demotion rather than holding yesterday's
/// answer until the next sign-in.
class AppState extends ChangeNotifier {
  AppUser _user;
  BranchId? _selectedBranch;

  /// The data store, so the session can follow staff edits. Optional: tests
  /// build an AppState on its own.
  final AppRepository? repository;

  AppState({
    AppUser? initialUser,
    this.repository,
    BranchId? initialBranch = BranchId.kidapawan,
  })  : _user = initialUser ?? StaffDirectory.admin,
        _selectedBranch = (initialUser ?? StaffDirectory.admin).role.canViewAllBranches
            ? initialBranch
            : ((initialUser?.homeBranch) ?? initialBranch ?? BranchId.kidapawan);

  /// The person acting. Every record the app writes names them.
  AppUser get currentUser => _user;

  /// What [currentUser] is allowed to do.
  AppUserRole get role => _user.role;

  /// Null means "all branches" — only ever valid when [role] is Admin.
  BranchId? get selectedBranch => _selectedBranch;

  bool get isViewingAllBranches => _selectedBranch == null;

  void setUser(AppUser user) {
    if (user.id == _user.id) return;
    _user = user;
    // Branch staff open on their own branch; an Admin keeps whatever view
    // they were already standing in.
    if (user.homeBranch != null) {
      _selectedBranch = user.homeBranch;
    } else if (!user.role.canViewAllBranches && _selectedBranch == null) {
      _selectedBranch = BranchId.kidapawan;
    }
    notifyListeners();
  }

  /// Takes the signed-in person's record as the shop now has it — after a
  /// sync has brought the server's version, or after an edit on this phone.
  /// A role changed elsewhere reaches this phone here, so someone made a
  /// Supervisor this morning is not still offered yesterday's screens.
  ///
  /// Returns the person as they now stand, so the session can save them.
  AppUser refreshSignedInUser() {
    syncWithStaff();
    return _user;
  }

  /// Keeps the session in step with the staff records: picks up edits to the
  /// current person, and moves off them if they are deactivated or deleted.
  void syncWithStaff() {
    final latest = repository?.findUser(_user.id) ?? StaffDirectory.byId(_user.id);
    if (latest == null || !latest.active) {
      // Nothing to stand on: with a server, signing out is the right answer
      // and the next request would be refused anyway. Without one — the
      // local build and the tests — fall back to the shop's Admin.
      if (repository != null) return;
      _user = StaffDirectory.admin;
      if (!_user.role.canViewAllBranches && _selectedBranch == null) {
        _selectedBranch = _user.homeBranch ?? BranchId.kidapawan;
      }
      notifyListeners();
      return;
    }
    if (latest.name != _user.name ||
        latest.role != _user.role ||
        latest.homeBranch != _user.homeBranch ||
        latest.contactNumber != _user.contactNumber) {
      _user = latest;
      if (!_user.role.canViewAllBranches && _selectedBranch == null) {
        _selectedBranch = _user.homeBranch ?? BranchId.kidapawan;
      }
      notifyListeners();
    }
  }

  /// Takes the person the server signed in. Branch staff are fixed to their
  /// own branch; only an Admin may stand in the combined view.
  void signedInAs(AppUser user) {
    _user = user;
    if (!user.role.canViewAllBranches) {
      _selectedBranch = user.homeBranch ?? BranchId.kidapawan;
    }
    notifyListeners();
  }

  /// Switches to whoever holds [role] at the branch in view.
  void setRole(AppUserRole role) {
    if (role == _user.role) return;
    setUser(StaffDirectory.forRole(role, branch: _selectedBranch));
  }

  void setBranch(BranchId? branch) {
    if (branch == null && !role.canViewAllBranches) return;
    if (branch == _selectedBranch) return;
    _selectedBranch = branch;
    notifyListeners();
  }
}
