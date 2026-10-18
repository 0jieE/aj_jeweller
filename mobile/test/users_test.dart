// Unit tests for staff management: add, edit, deactivate, delete, the
// guards around them, and that staff survive data resets and restarts.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/core/data/app_repository.dart';
import 'package:davao_aj_jewellers/core/data/staff_directory.dart';
import 'package:davao_aj_jewellers/core/models/branch.dart';
import 'package:davao_aj_jewellers/core/models/item_status.dart';
import 'package:davao_aj_jewellers/core/models/transaction_log.dart';
import 'package:davao_aj_jewellers/core/models/user_role.dart';
import 'package:davao_aj_jewellers/core/state/app_state.dart';
import 'support/proof_photo.dart';

void main() {
  test('adding a user makes them pickable and logs it', () {
    final repo = AppRepository();
    final user = repo.addUser(name: 'Mika Santos', role: AppUserRole.cashier, homeBranch: BranchId.davao, contactNumber: '0917 000 1111');

    expect(repo.users.map((u) => u.id), contains(user.id));
    expect(StaffDirectory.byId(user.id)!.name, 'Mika Santos');
    final log = repo.logs.firstWhere((l) => l.action == LogAction.userAdded && l.recordId == user.id);
    expect(log.recordKind, LogRecordKind.user);
  });

  test('names must be unique, and branch staff need a branch', () {
    final repo = AppRepository();
    expect(() => repo.addUser(name: ' grace  ramos ', role: AppUserRole.cashier, homeBranch: BranchId.davao), throwsArgumentError);
    expect(() => repo.addUser(name: 'No Branch', role: AppUserRole.salesRep), throwsArgumentError);
    expect(() => repo.addUser(name: '  ', role: AppUserRole.admin), throwsArgumentError);
  });

  test('editing a user changes how existing records name them, and logs before/after', () {
    final repo = AppRepository();
    final grace = repo.findUser('USR-K-CSH')!;
    final changes = repo.updateUser(grace.id, name: 'Grace R. Ramos', homeBranch: BranchId.davao);

    expect(changes.map((c) => c.field), containsAll(['Name', 'Branch']));
    expect(StaffDirectory.byId(grace.id)!.name, 'Grace R. Ramos');
    expect(repo.logs.where((l) => l.action == LogAction.userUpdated && l.recordId == grace.id), hasLength(1));
  });

  test('the only active admin cannot be demoted, deactivated, or deleted', () {
    final repo = AppRepository();
    final admin = StaffDirectory.admin;
    expect(() => repo.updateUser(admin.id, role: AppUserRole.cashier, homeBranch: BranchId.davao), throwsStateError);
    expect(() => repo.setUserActive(admin.id, false), throwsStateError);
    expect(repo.userDeleteProblem(admin.id), isNotNull);
  });

  test('a deactivated user drops out of the pickers but still names their records', () {
    final repo = AppRepository();
    final grace = repo.findUser('USR-K-CSH')!;
    repo.setUserActive(grace.id, false, actor: StaffDirectory.admin);

    expect(repo.users.map((u) => u.id), isNot(contains(grace.id)));
    expect(StaffDirectory.byId(grace.id), isNotNull);
    expect(StaffDirectory.forRole(AppUserRole.cashier, branch: BranchId.kidapawan).id, isNot(grace.id));
    expect(repo.logs.where((l) => l.action == LogAction.userDeactivated && l.recordId == grace.id), hasLength(1));

    repo.setUserActive(grace.id, true);
    expect(repo.users.map((u) => u.id), contains(grace.id));
  });

  test('you cannot deactivate or delete yourself', () {
    final repo = AppRepository();
    final second = repo.addUser(name: 'Second Admin', role: AppUserRole.admin);
    expect(() => repo.setUserActive(second.id, false, actor: second), throwsStateError);
    expect(repo.userDeleteProblem(second.id, actor: second), isNotNull);
  });

  test('only users with no records can be deleted; others must be deactivated', () {
    final repo = AppRepository();
    expect(repo.userDeleteProblem('USR-K-CSH'), contains('Deactivate'));

    final mistake = repo.addUser(name: 'Typo Person', role: AppUserRole.salesRep, homeBranch: BranchId.kidapawan);
    // Adding them wrote a log naming them as the record, not as the actor.
    expect(repo.userDeleteProblem(mistake.id), isNull);
    repo.deleteUser(mistake.id);
    expect(repo.findUser(mistake.id), isNull);
    expect(repo.logs.where((l) => l.action == LogAction.userDeleted && l.recordId == mistake.id), hasLength(1));
  });

  test('staff survive Start Empty, Reset Demo Data, and a restart', () {
    final repo = AppRepository();
    final added = repo.addUser(name: 'Kept Staff', role: AppUserRole.assistantAppraiser, homeBranch: BranchId.davao);
    repo.resetToEmpty();
    expect(repo.findUser(added.id), isNotNull);
    repo.resetToSeed();
    expect(repo.findUser(added.id), isNotNull);

    final saved = jsonDecode(jsonEncode(repo.toSnapshot())) as Map<String, dynamic>;
    final fresh = AppRepository();
    expect(fresh.findUser(added.id), isNull);
    fresh.restoreSnapshot(saved);
    expect(fresh.findUser(added.id)!.name, 'Kept Staff');
  });

  test('the session moves off a user who is deactivated, and picks up edits', () {
    final repo = AppRepository();
    final grace = repo.findUser('USR-K-CSH')!;
    final state = AppState(initialUser: grace);

    repo.updateUser(grace.id, name: 'Grace Ramos-Cruz');
    state.syncWithStaff();
    expect(state.currentUser.name, 'Grace Ramos-Cruz');

    repo.setUserActive(grace.id, false);
    state.syncWithStaff();
    expect(state.currentUser.id, isNot(grace.id));
    expect(state.currentUser.role, AppUserRole.admin);
  });

  group('what a role may do', () {
    test('the three branch roles can all do the counter work', () {
      for (final role in [AppUserRole.cashier, AppUserRole.assistantAppraiser, AppUserRole.salesRep]) {
        expect(role.canMoveCash, isTrue, reason: '$role covers the counter');
        expect(role.canManageCash, isFalse, reason: "moving the shop's own money is not counter work");
        expect(role.canVerifyRecords, isTrue);
        expect(role.canEncodePurchases, isTrue);
        expect(role.canMakeSales, isTrue);
      }
    });

    test("what is the Admin's stays the Admin's", () {
      for (final role in [AppUserRole.cashier, AppUserRole.assistantAppraiser, AppUserRole.salesRep]) {
        expect(role.canCorrectRecords, isFalse);
        expect(role.canManageCash, isFalse, reason: "the ledger is the Admin's");
        expect(role.canRunDisposal, isFalse);
        expect(role.canManageCommitments, isFalse);
        expect(role.canManageRates, isTrue, reason: 'anyone at the counter keeps the rates current');
        expect(role.canManageUsers, isFalse);
        expect(role.canViewAllBranches, isFalse);
        expect(role.canDeletePartitions, isFalse);
      }
      expect(AppUserRole.admin.canCorrectRecords, isTrue);
      expect(AppUserRole.admin.canManageCash, isTrue);
      expect(AppUserRole.admin.canManageUsers, isTrue);
      expect(AppUserRole.admin.canViewAllBranches, isTrue);
    });

    test('a Supervisor runs their branch, not the shop', () {
      const supervisor = AppUserRole.supervisor;
      expect(supervisor.runsABranch, isTrue);
      expect(supervisor.runsTheShop, isFalse);
      // Running a branch: the ledger, corrections, disposal, its loans.
      expect(supervisor.canManageCash, isTrue);
      expect(supervisor.canCorrectRecords, isTrue);
      expect(supervisor.canRunDisposal, isTrue);
      expect(supervisor.canManageCommitments, isTrue);
      expect(supervisor.canManageUsers, isTrue);
      // But only theirs: the branch picker is what keeps them there.
      expect(supervisor.canViewAllBranches, isFalse);
    });

    test('a Superuser is an Admin everywhere in the shop', () {
      for (final power in [
        (AppUserRole r) => r.canManageCash,
        (AppUserRole r) => r.canCorrectRecords,
        (AppUserRole r) => r.canRunDisposal,
        (AppUserRole r) => r.canManageCommitments,
        (AppUserRole r) => r.canManageUsers,
        (AppUserRole r) => r.canViewAllBranches,
        (AppUserRole r) => r.canDeletePartitions,
      ]) {
        expect(power(AppUserRole.superuser), power(AppUserRole.admin));
      }
    });

    test('a Supervisor may take on counter staff, never another manager', () {
      const supervisor = AppUserRole.supervisor;
      for (final target in [AppUserRole.cashier, AppUserRole.assistantAppraiser, AppUserRole.salesRep]) {
        expect(supervisor.canManageStaffOf(target), isTrue);
      }
      for (final target in [AppUserRole.supervisor, AppUserRole.admin, AppUserRole.superuser]) {
        expect(supervisor.canManageStaffOf(target), isFalse, reason: 'no climbing out of a branch');
      }
      expect(supervisor.assignableRoles, isNot(contains(AppUserRole.admin)));
      // An Admin and a Superuser may appoint anyone.
      for (final boss in [AppUserRole.admin, AppUserRole.superuser]) {
        expect(boss.assignableRoles, AppUserRole.values);
      }
    });

    test('a role this build has never heard of does not break the phone', () {
      // A server updated before the shop's phones: the staff list still
      // loads, and the server remains the judge of what they may do.
      expect(AppUserRole.parse('supervisor'), AppUserRole.supervisor);
      expect(AppUserRole.parse('superuser'), AppUserRole.superuser);
      expect(AppUserRole.parse('nightWatchman'), AppUserRole.salesRep);
      expect(AppUserRole.parse(null), AppUserRole.salesRep);
      expect(AppUserRole.parse('nightWatchman').runsABranch, isFalse);
    });

    test('a Sales Rep can release a purchase when the Cashier is out', () {
      final repo = AppRepository();
      final rep = repo.users.firstWhere((u) => u.role == AppUserRole.salesRep && u.homeBranch == BranchId.kidapawan);
      final batch = repo.purchaseBatchesAwaitingRelease(branchId: BranchId.kidapawan).first;
      final before = repo.cashBalance(BranchId.kidapawan);
      final total = repo.batchTotalCentavos(batch.id);

      repo.releaseBatchCash(batch.id, actor: rep, proofPhoto: proofPhoto);

      final released = repo.findBatch(batch.id)!;
      expect(released.verificationStatus, VerificationStatus.verified);
      expect(repo.cashBalance(BranchId.kidapawan), before - total);
      // Whoever actually did it is on the record, not the role it belongs to.
      expect(released.releasedByUserId, rep.id);
    });
  });
}
