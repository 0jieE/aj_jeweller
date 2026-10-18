import 'package:flutter/material.dart';

import 'branch.dart';
import 'user_role.dart';

/// What happened, in the terms staff would use to describe it.
enum LogAction {
  purchaseRecorded,
  cashReleased,
  purchaseReturned,
  purchaseResubmitted,
  partitionCreated,
  partitionReturned,
  itemEdited,
  photoAttached,
  saleSubmitted,
  saleResubmitted,
  paymentReceived,
  saleReturned,
  disposalCompleted,
  commitmentAdded,
  commitmentReceived,
  cashEntryRecorded,
  cashTransferred,
  cashEntryEdited,
  cashEntryDeleted,
  goldRateUpdated,
  goldRateAdded,
  customerPhotoUpdated,
  userAdded,
  userUpdated,
  userDeactivated,
  userReactivated,
  userDeleted;

  String get label {
    switch (this) {
      case LogAction.purchaseRecorded:
        return 'Purchase recorded';
      case LogAction.cashReleased:
        return 'Cash released';
      case LogAction.purchaseReturned:
        return 'Purchase returned';
      case LogAction.purchaseResubmitted:
        return 'Purchase resubmitted';
      case LogAction.partitionCreated:
        return 'Partition created';
      case LogAction.partitionReturned:
        return 'Partition returned';
      case LogAction.itemEdited:
        return 'Item edited';
      case LogAction.photoAttached:
        return 'Photo attached';
      case LogAction.saleSubmitted:
        return 'Sale submitted';
      case LogAction.saleResubmitted:
        return 'Sale resubmitted';
      case LogAction.paymentReceived:
        return 'Payment received';
      case LogAction.saleReturned:
        return 'Sale returned';
      case LogAction.disposalCompleted:
        return 'Disposal completed';
      case LogAction.commitmentAdded:
        return 'Commitment added';
      case LogAction.commitmentReceived:
        return 'Loan cash received';
      case LogAction.cashEntryRecorded:
        return 'Cash entry';
      case LogAction.cashTransferred:
        return 'Cash transfer';
      case LogAction.cashEntryEdited:
        return 'Cash entry edited';
      case LogAction.cashEntryDeleted:
        return 'Cash entry deleted';
      case LogAction.goldRateUpdated:
        return 'Rate updated';
      case LogAction.goldRateAdded:
        return 'Rate added';
      case LogAction.customerPhotoUpdated:
        return 'Customer photo';
      case LogAction.userAdded:
        return 'User added';
      case LogAction.userUpdated:
        return 'User edited';
      case LogAction.userDeactivated:
        return 'User deactivated';
      case LogAction.userReactivated:
        return 'User reactivated';
      case LogAction.userDeleted:
        return 'User deleted';
    }
  }

  LogCategory get category {
    switch (this) {
      case LogAction.purchaseRecorded:
      case LogAction.cashReleased:
      case LogAction.purchaseReturned:
      case LogAction.purchaseResubmitted:
      case LogAction.partitionCreated:
      case LogAction.partitionReturned:
      case LogAction.itemEdited:
      case LogAction.photoAttached:
        return LogCategory.purchase;
      case LogAction.saleSubmitted:
      case LogAction.saleResubmitted:
      case LogAction.paymentReceived:
      case LogAction.saleReturned:
        return LogCategory.sale;
      case LogAction.disposalCompleted:
      case LogAction.commitmentAdded:
      case LogAction.commitmentReceived:
        return LogCategory.scrap;
      case LogAction.cashEntryRecorded:
      case LogAction.cashTransferred:
      case LogAction.cashEntryEdited:
      case LogAction.cashEntryDeleted:
        return LogCategory.cash;
      case LogAction.goldRateUpdated:
      case LogAction.goldRateAdded:
      case LogAction.customerPhotoUpdated:
      case LogAction.userAdded:
      case LogAction.userUpdated:
      case LogAction.userDeactivated:
      case LogAction.userReactivated:
      case LogAction.userDeleted:
        return LogCategory.admin;
    }
  }

  IconData get icon {
    switch (this) {
      case LogAction.purchaseRecorded:
        return Icons.add_shopping_cart_rounded;
      case LogAction.cashReleased:
        return Icons.payments_rounded;
      case LogAction.purchaseReturned:
      case LogAction.saleReturned:
        return Icons.flag_rounded;
      case LogAction.purchaseResubmitted:
      case LogAction.saleResubmitted:
        return Icons.replay_rounded;
      case LogAction.partitionCreated:
        return Icons.call_split_rounded;
      case LogAction.partitionReturned:
        return Icons.undo_rounded;
      case LogAction.itemEdited:
        return Icons.edit_rounded;
      case LogAction.photoAttached:
        return Icons.photo_camera_rounded;
      case LogAction.saleSubmitted:
        return Icons.shopping_bag_rounded;
      case LogAction.paymentReceived:
        return Icons.point_of_sale_rounded;
      case LogAction.disposalCompleted:
        return Icons.delete_sweep_rounded;
      case LogAction.commitmentAdded:
        return Icons.handshake_rounded;
      case LogAction.commitmentReceived:
        return Icons.account_balance_rounded;
      case LogAction.cashEntryRecorded:
        return Icons.account_balance_wallet_rounded;
      case LogAction.cashTransferred:
        return Icons.swap_horiz_rounded;
      case LogAction.cashEntryEdited:
        return Icons.edit_note_rounded;
      case LogAction.cashEntryDeleted:
        return Icons.delete_outline_rounded;
      case LogAction.goldRateUpdated:
        return Icons.show_chart_rounded;
      case LogAction.goldRateAdded:
        return Icons.add_chart_rounded;
      case LogAction.customerPhotoUpdated:
        return Icons.face_rounded;
      case LogAction.userAdded:
        return Icons.person_add_alt_1_rounded;
      case LogAction.userUpdated:
        return Icons.manage_accounts_rounded;
      case LogAction.userDeactivated:
        return Icons.person_off_rounded;
      case LogAction.userReactivated:
        return Icons.how_to_reg_rounded;
      case LogAction.userDeleted:
        return Icons.person_remove_rounded;
    }
  }
}

/// The broad area an action belongs to â€” what the log filters on.
enum LogCategory {
  purchase,
  sale,
  scrap,
  cash,
  admin;

  String get label {
    switch (this) {
      case LogCategory.purchase:
        return 'Purchase';
      case LogCategory.sale:
        return 'Sale';
      case LogCategory.scrap:
        return 'Scrap & Loans';
      case LogCategory.cash:
        return 'Cash';
      case LogCategory.admin:
        return 'Admin';
    }
  }
}

/// What kind of record an entry points at, so it can be opened.
enum LogRecordKind { purchaseBatch, item, sale, disposal, commitment, cashEntry, customer, user }

/// One field's value before and after an edit.
class FieldChange {
  final String field;
  final String before;
  final String after;

  const FieldChange({required this.field, required this.before, required this.after});
}

/// One entry in the shop's transaction log: who did what, when, to which
/// record.
///
/// Append-only by construction â€” the repository adds entries as a side
/// effect of each action and exposes nothing that edits or removes them. A
/// log that can be quietly corrected is not evidence of anything.
class TransactionLog {
  final String id;
  final DateTime at;
  final LogAction action;

  /// Null only for entries with no identifiable person behind them.
  final String? userId;

  /// The person's name as it stood when they acted, so the log still reads
  /// correctly if the staff directory later changes.
  final String userName;
  final AppUserRole role;

  final BranchId? branch;
  final String? recordId;
  final LogRecordKind? recordKind;

  /// One line, in plain words: "Released â‚±26,100.00 to Rico Dela Cruz".
  final String summary;

  /// The money the action moved or concerned, when there was any.
  final int? amountCentavos;

  /// Before/after values, for edits.
  final List<FieldChange> changes;

  const TransactionLog({
    required this.id,
    required this.at,
    required this.action,
    required this.userId,
    required this.userName,
    required this.role,
    required this.summary,
    this.branch,
    this.recordId,
    this.recordKind,
    this.amountCentavos,
    this.changes = const [],
  });
}
