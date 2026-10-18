/// Staff roles.
///
/// A role says what someone is normally responsible for and who the server
/// notifies — not what they are allowed to do. The three branch roles can do
/// the same counter work, so when the Cashier is out the Appraiser or the
/// Sales Rep can release the cash, and the shop does not stop. What differs
/// is who gets told: a purchase waiting on cash notifies the Cashiers, an
/// order returned for correction notifies the Rep who sold it.
///
/// Only an Admin's extra powers are actually restricted — corrections,
/// disposal, rates and loans, staff, and seeing both branches at once.
///
/// Every record names whoever actually did the thing, so standing in for an
/// absent colleague is visible in the log rather than hidden.
enum AppUserRole {
  assistantAppraiser,
  salesRep,
  cashier,
  admin;

  String get label {
    switch (this) {
      case AppUserRole.assistantAppraiser:
        return 'Assistant Appraiser';
      case AppUserRole.salesRep:
        return 'Sales Rep';
      case AppUserRole.cashier:
        return 'Cashier';
      case AppUserRole.admin:
        return 'Admin';
    }
  }

  /// Compact form for the app bar, where the full label can't share a phone's
  /// width with a screen title and a branch picker.
  String get shortLabel {
    switch (this) {
      case AppUserRole.assistantAppraiser:
        return 'Appraiser';
      case AppUserRole.salesRep:
        return 'Sales Rep';
      case AppUserRole.cashier:
        return 'Cashier';
      case AppUserRole.admin:
        return 'Admin';
    }
  }

  String get description {
    switch (this) {
      case AppUserRole.assistantAppraiser:
        return 'Encodes purchased items · can cover the counter';
      case AppUserRole.salesRep:
        return 'Handles sales and customer orders · can cover the counter';
      case AppUserRole.cashier:
        return 'Verifies records, releases and receives cash';
      case AppUserRole.admin:
        return 'Oversees both branches';
    }
  }

  // --- Counter work -------------------------------------------------------
  // Shared by everyone, so an absence never leaves a customer waiting. The
  // getters stay because the screens read them, and because the day the shop
  // wants one of these narrowed again, there is one place to do it.

  /// Can encode newly purchased items into inventory.
  bool get canEncodePurchases => true;

  /// Can build/handle customer sales.
  bool get canMakeSales => true;

  /// Can verify records submitted by whoever encoded them.
  bool get canVerifyRecords => true;

  /// Can release cash (purchases) or receive cash (sales).
  bool get canMoveCash => true;

  // --- An Admin's own -----------------------------------------------------

  /// Can open the cash ledger: entries, expenses, withdrawals, transfers
  /// between branches. Releasing a purchase and receiving payment are counter
  /// work and stay open to everyone — this is the shop's own money being
  /// moved and accounted for, which answers to one person.
  bool get canManageCash => this == AppUserRole.admin;

  /// Can run scrap disposal batches.
  bool get canRunDisposal => this == AppUserRole.admin;

  /// Can manage commitments (loans repaid in gold) and gold rates.
  bool get canManageCommitmentsAndRates => this == AppUserRole.admin;

  /// Can undo a lot partition, returning its grams and amount to the lot it
  /// was drawn from. Admin only — it rewrites how an already-released
  /// purchase is split, so it sits alongside disposal rather than with
  /// everyday encoding.
  bool get canDeletePartitions => this == AppUserRole.admin;

  /// Can correct an item's recorded details after the fact — weights,
  /// amount, karat, type. Admin only: a correction rewrites a record other
  /// people have already acted on, so it has to sit with whoever answers for
  /// the whole shop, and it is always written to the log under their name.
  bool get canCorrectRecords => this == AppUserRole.admin;

  /// Can see both branches at once.
  bool get canViewAllBranches => this == AppUserRole.admin;

  /// Can add, edit, deactivate, and delete staff.
  bool get canManageUsers => this == AppUserRole.admin;
}
