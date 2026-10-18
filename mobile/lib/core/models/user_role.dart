/// Staff roles.
///
/// A role says what someone is normally responsible for and who the server
/// notifies — not what they are allowed to do. The three branch roles can do
/// the same counter work, so when the Cashier is out the Appraiser or the
/// Sales Rep can release the cash, and the shop does not stop. What differs
/// is who gets told: a purchase waiting on cash notifies the Cashiers, an
/// order returned for correction notifies the Rep who sold it.
///
/// What is restricted is running the shop rather than working the counter:
/// the cash ledger, corrections, disposal, loans, staff. A Supervisor has
/// those for their own branch; an Admin for both; a Superuser is an Admin who
/// may also use the server's own administration site.
///
/// Every record names whoever actually did the thing, so standing in for an
/// absent colleague is visible in the log rather than hidden.
enum AppUserRole {
  assistantAppraiser,
  salesRep,
  cashier,
  supervisor,
  admin,
  superuser;

  /// Reads a role the server sent. A role this build has never heard of —
  /// one added to the server before the shop's phones are updated — comes
  /// back as the most limited role there is rather than throwing, so a new
  /// colleague appearing in the staff list can never stop an old phone
  /// signing in. What they may actually do is the server's word anyway.
  static AppUserRole parse(String? name) {
    for (final role in values) {
      if (role.name == name) return role;
    }
    return AppUserRole.salesRep;
  }

  /// Runs one branch: the cash ledger, corrections, disposal, that branch's
  /// loans and its counter staff — their own branch and no further.
  bool get runsABranch => this == AppUserRole.supervisor || runsTheShop;

  /// Both branches, and everything in them.
  bool get runsTheShop => this == AppUserRole.admin || this == AppUserRole.superuser;

  String get label {
    switch (this) {
      case AppUserRole.assistantAppraiser:
        return 'Assistant Appraiser';
      case AppUserRole.salesRep:
        return 'Sales Rep';
      case AppUserRole.cashier:
        return 'Cashier';
      case AppUserRole.supervisor:
        return 'Supervisor';
      case AppUserRole.admin:
        return 'Admin';
      case AppUserRole.superuser:
        return 'Superuser';
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
      case AppUserRole.supervisor:
        return 'Supervisor';
      case AppUserRole.admin:
        return 'Admin';
      case AppUserRole.superuser:
        return 'Superuser';
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
      case AppUserRole.supervisor:
        return 'Runs one branch — cash, corrections, disposal, its staff';
      case AppUserRole.admin:
        return 'Oversees both branches';
      case AppUserRole.superuser:
        return 'Oversees both branches, and the server itself';
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

  /// Can set the gold and silver rates. Everyone: the counter quotes from
  /// them all day, and a rate nobody present can correct is worse than one
  /// anybody can — every change is logged under the name of whoever made it.
  bool get canManageRates => true;

  // --- An Admin's own -----------------------------------------------------

  /// Can open the cash ledger: entries, expenses, withdrawals, transfers.
  /// Releasing a purchase and receiving payment are counter work and stay
  /// open to everyone — this is the shop's own money being moved and
  /// accounted for, which answers to whoever runs the branch.
  bool get canManageCash => runsABranch;

  /// Can run scrap disposal batches.
  bool get canRunDisposal => runsABranch;

  /// Can manage commitments — loans repaid in gold. A Supervisor's are their
  /// own branch's; a loan belonging to neither branch is the Admin's.
  bool get canManageCommitments => runsABranch;

  /// Can undo a lot partition, returning its grams and amount to the lot it
  /// was drawn from. Admin only — it rewrites how an already-released
  /// purchase is split, so it sits alongside disposal rather than with
  /// everyday encoding.
  bool get canDeletePartitions => runsABranch;

  /// Can correct an item's recorded details after the fact — weights,
  /// amount, karat, type. Admin only: a correction rewrites a record other
  /// people have already acted on, so it has to sit with whoever answers for
  /// the whole shop, and it is always written to the log under their name.
  bool get canCorrectRecords => runsABranch;

  /// Can see both branches at once. A Supervisor stays at theirs.
  bool get canViewAllBranches => runsTheShop;

  /// Can open the staff list and change who works here.
  bool get canManageUsers => runsABranch;

  /// Whether someone of this role may create or change staff of [target].
  ///
  /// A Supervisor runs their branch's counter, not the shop's hierarchy: they
  /// may take on a Cashier and set their PIN, but not make anyone a
  /// Supervisor, an Admin or a Superuser — including themselves. The server
  /// refuses it too; this is so the app never offers what would be refused.
  bool canManageStaffOf(AppUserRole target) =>
      runsTheShop || (this == AppUserRole.supervisor && !target.runsABranch);

  /// The roles this person may give someone.
  List<AppUserRole> get assignableRoles =>
      values.where(canManageStaffOf).toList();
}
