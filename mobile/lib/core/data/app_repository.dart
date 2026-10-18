import 'package:flutter/foundation.dart';

import '../models/app_user.dart';
import '../models/branch.dart';
import '../models/cash_entry.dart';
import '../models/commitment.dart';
import '../models/customer.dart';
import '../models/disposal_batch.dart';
import '../models/gold_rate.dart';
import '../models/item.dart';
import '../models/item_status.dart';
import '../models/purchase_batch.dart';
import '../models/rate_change.dart';
import '../models/sale.dart';
import '../models/stored_receipt.dart';
import '../models/transaction_log.dart';
import '../models/user_role.dart';
import 'id_generator.dart';
import 'money_text.dart';
import '../sync/outbox.dart';
import 'seed_data.dart';
import 'snapshot_codec.dart';
import 'staff_directory.dart';

/// The single in-memory data store for the prototype. Holds every branch,
/// item, sale, commitment, and disposal batch, seeded on construction.
/// There's no backend — state lives here for the life of the app and resets
/// via [resetToSeed] (wired to the drawer's "Reset demo data" action).
///
/// Feature tabs read through this repository rather than holding their own
/// copies, so mutations made from one screen are immediately visible on the
/// Dashboard and elsewhere.
class AppRepository extends ChangeNotifier {
  final IdGenerator _ids;

  AppRepository({IdGenerator? idGenerator}) : _ids = idGenerator ?? IdGenerator() {
    // Staff are set once and outlive every data reset — see [StaffDirectory].
    _users = List.of(StaffDirectory.seed);
    StaffDirectory.replaceAll(_users);
    _loadSeed();
  }

  late List<AppUser> _users;

  /// Where a write goes to be told to the server, once there is a server.
  /// Null in tests and before sign-in: the app then works exactly as it did,
  /// entirely on the device.
  void Function(SyncOperation operation)? onWrite;

  /// True while a change from the server is being applied, so replaying it
  /// never queues it straight back to the server it came from.
  bool _applyingRemote = false;

  int _opSeq = 0;

  /// Queues one write for the server. Photos travel as base64 inside the
  /// body, since a queued operation is plain JSON.
  void _queue(
    String method,
    String path, {
    Map<String, dynamic> body = const {},
    required String summary,
    DateTime? at,
  }) {
    final sink = onWrite;
    if (sink == null || _applyingRemote) return;
    final now = DateTime.now();
    sink(SyncOperation(
      key: '${now.microsecondsSinceEpoch.toRadixString(36)}-${_opSeq++}-${_newId()}',
      method: method,
      path: path,
      body: {for (final e in body.entries) if (e.value != null) e.key: e.value},
      recordedAt: at ?? now,
      summary: summary,
    ));
  }

  /// The customer as the server's endpoints take them.
  static Map<String, dynamic> _customerBody(CustomerDetails c) => {
        'id': c.customerId,
        'name': c.name.trim(),
        'contact_number': c.contactNumber,
        'address': c.address,
      };

  static String _grams(double value) => value.toStringAsFixed(3);

  late List<Branch> _branches;
  late List<GoldRate> _goldRates;
  late List<RateChange> _rateHistory;
  late List<Item> _items;
  late List<Sale> _sales;
  late List<Commitment> _commitments;
  late List<DisposalBatch> _disposalBatches;
  late List<CashEntry> _cashEntries;
  late List<PurchaseBatch> _purchaseBatches;
  late List<StoredReceipt> _receipts;
  late List<Customer> _customers;
  late List<TransactionLog> _logs;

  /// Every record shares one id space, so a code read off a receipt points at
  /// exactly one thing whatever kind of record it turns out to be.
  bool _idTaken(String id) =>
      _items.any((i) => i.id == id) ||
      _sales.any((s) => s.id == id) ||
      _receipts.any((r) => r.id == id) ||
      _customers.any((c) => c.id == id) ||
      _purchaseBatches.any((b) => b.id == id) ||
      _commitments.any((c) => c.id == id) ||
      _disposalBatches.any((d) => d.id == id) ||
      _cashEntries.any((e) => e.id == id) ||
      _logs.any((l) => l.id == id);

  String _newId() => _ids.next(_idTaken);

  // List.of(...) here, not a bare assignment — SeedData.branches() is a
  // `const` list literal, and directly assigning it leaves _branches
  // unmodifiable, which throws the moment releaseCash() tries to update a
  // balance. Every seed list gets the same defensive copy.
  void _loadSeed() {
    _branches = List.of(SeedData.branches());
    _goldRates = List.of(SeedData.goldRates());
    _rateHistory = List.of(SeedData.rateHistory(_goldRates));
    _items = List.of(SeedData.items());
    _sales = List.of(SeedData.sales(_items));
    _commitments = List.of(SeedData.commitments());
    _disposalBatches = List.of(SeedData.disposalBatches());
    _purchaseBatches = List.of(SeedData.purchaseBatches(_items));
    _customers = List.of(SeedData.customers(_purchaseBatches, _sales));
    _linkSeedTransactionsToCustomers();
    _cashEntries = List.of(
      SeedData.cashEntries(_items, _sales, _commitments, _purchaseBatches),
    );
    // Receipts are issued, never seeded — a demo reset should not invent
    // documents the shop never handed anyone.
    _receipts = [];
    _logs = List.of(SeedData.transactionLogs(
      items: _items,
      batches: _purchaseBatches,
      sales: _sales,
      disposals: _disposalBatches,
      commitments: _commitments,
      rateHistory: _rateHistory,
    ));
  }

  /// Points seeded transactions at the customer records built from them.
  ///
  /// The book is derived from the transactions, so the ids only exist once
  /// that pass has run — without this second pass every seeded purchase and
  /// sale would carry a name but no link, and a customer's history would
  /// read as empty.
  void _linkSeedTransactionsToCustomers() {
    String? idFor(String name) {
      final key = Customer.matchKey(name);
      for (final c in _customers) {
        if (c.key == key) return c.id;
      }
      return null;
    }

    for (var i = 0; i < _purchaseBatches.length; i++) {
      final batch = _purchaseBatches[i];
      final id = idFor(batch.customer.name);
      if (id != null) {
        _purchaseBatches[i] = batch.copyWith(customer: batch.customer.withId(id));
      }
    }
    for (var i = 0; i < _sales.length; i++) {
      final sale = _sales[i];
      final id = idFor(sale.customer.name);
      if (id != null) {
        _sales[i] = sale.copyWith(customer: sale.customer.withId(id));
      }
    }
  }

  // --- Saving between launches ----------------------------------------------

  static const snapshotVersion = 1;

  /// Every record, as JSON — what [AppStorage] writes to the device.
  Map<String, dynamic> toSnapshot() => {
        'version': snapshotVersion,
        'savedAt': DateTime.now().toIso8601String(),
        'users': [for (final u in _users) SnapshotCodec.user(u)],
        'branches': [for (final b in _branches) SnapshotCodec.branch(b)],
        'goldRates': [for (final r in _goldRates) SnapshotCodec.goldRate(r)],
        'rateHistory': [for (final c in _rateHistory) SnapshotCodec.rateChange(c)],
        'items': [for (final i in _items) SnapshotCodec.item(i)],
        'sales': [for (final x in _sales) SnapshotCodec.sale(x)],
        'commitments': [for (final c in _commitments) SnapshotCodec.commitment(c)],
        'disposalBatches': [for (final d in _disposalBatches) SnapshotCodec.disposalBatch(d)],
        'cashEntries': [for (final e in _cashEntries) SnapshotCodec.cashEntry(e)],
        'purchaseBatches': [for (final b in _purchaseBatches) SnapshotCodec.purchaseBatch(b)],
        'receipts': [for (final r in _receipts) SnapshotCodec.receipt(r)],
        'customers': [for (final c in _customers) SnapshotCodec.customer(c)],
        'logs': [for (final l in _logs) SnapshotCodec.log(l)],
      };

  /// Replaces every record with a saved snapshot. Parsed in full before
  /// anything is swapped in, so a bad file leaves the current data untouched.
  void restoreSnapshot(Map<String, dynamic> json) {
    List<T> list<T>(String key, T Function(Map<String, dynamic>) parse) => [
          for (final raw in (json[key] as List? ?? const [])) parse((raw as Map).cast<String, dynamic>()),
        ];

    final branches = list('branches', SnapshotCodec.parseBranch);
    if (branches.length != BranchId.values.length) {
      throw const FormatException('Saved data is missing a branch');
    }
    final goldRates = list('goldRates', SnapshotCodec.parseGoldRate);
    final rateHistory = list('rateHistory', SnapshotCodec.parseRateChange);
    final items = list('items', SnapshotCodec.parseItem);
    final sales = list('sales', SnapshotCodec.parseSale);
    final commitments = list('commitments', SnapshotCodec.parseCommitment);
    final disposals = list('disposalBatches', SnapshotCodec.parseDisposalBatch);
    final cash = list('cashEntries', SnapshotCodec.parseCashEntry);
    final batches = list('purchaseBatches', SnapshotCodec.parsePurchaseBatch);
    final receipts = list('receipts', SnapshotCodec.parseReceipt);
    final customers = list('customers', SnapshotCodec.parseCustomer);
    final logs = list('logs', SnapshotCodec.parseLog);
    final users = list('users', SnapshotCodec.parseUser);

    _branches = branches;
    _goldRates = goldRates;
    _rateHistory = rateHistory;
    _items = items;
    _sales = sales;
    _commitments = commitments;
    _disposalBatches = disposals;
    _cashEntries = cash;
    _purchaseBatches = batches;
    _receipts = receipts;
    _customers = customers;
    _logs = logs;
    // Older saves had no staff section; keep the current staff for those.
    if (users.any((u) => u.active && u.role == AppUserRole.admin)) {
      _users = users;
      _syncUsers();
    }
    _releaseAbandonedReservations();
    notifyListeners();
  }

  /// A cart lives only while the app is open. Items it had reserved but never
  /// turned into an order would otherwise stay "reserved" forever after a
  /// restart — so anything reserved that no open order holds goes back on sale.
  void _releaseAbandonedReservations() {
    final held = <String>{
      for (final sale in _sales)
        if (sale.verificationStatus != VerificationStatus.verified)
          for (final line in sale.lineItems) line.item.id,
    };
    for (var i = 0; i < _items.length; i++) {
      final item = _items[i];
      if (item.itemStatus == ItemStatus.reserved && !held.contains(item.id)) {
        _items[i] = item.copyWith(itemStatus: ItemStatus.listed);
      }
    }
  }

  /// Takes one page of `GET /sync/changes`: the server's version of each
  /// record replaces the phone's, and anything it lists as gone is removed.
  ///
  /// Nothing here is queued back to the server — these changes came from it.
  void applySyncChanges({
    Map<String, dynamic> changes = const {},
    Map<String, dynamic> deleted = const {},
  }) {
    _applyingRemote = true;
    try {
      void upsert<T>(
        String key,
        List<T> target,
        T Function(Map<String, dynamic>) parse,
        String Function(T) idOf,
      ) {
        for (final raw in (changes[key] as List? ?? const [])) {
          final record = parse((raw as Map).cast<String, dynamic>());
          final index = target.indexWhere((existing) => idOf(existing) == idOf(record));
          if (index == -1) {
            target.add(record);
          } else {
            target[index] = record;
          }
        }
        for (final id in (deleted[key] as List? ?? const [])) {
          target.removeWhere((existing) => idOf(existing) == '$id');
        }
      }

      upsert('branches', _branches, SnapshotCodec.parseBranch, (b) => b.id.name);
      upsert('users', _users, SnapshotCodec.parseUser, (u) => u.id);
      upsert('customers', _customers, SnapshotCodec.parseCustomer, (c) => c.id);
      upsert('items', _items, SnapshotCodec.parseItem, (i) => i.id);
      upsert('purchaseBatches', _purchaseBatches, SnapshotCodec.parsePurchaseBatch, (b) => b.id);
      upsert('sales', _sales, SnapshotCodec.parseSale, (x) => x.id);
      upsert('commitments', _commitments, SnapshotCodec.parseCommitment, (c) => c.id);
      upsert('disposalBatches', _disposalBatches, SnapshotCodec.parseDisposalBatch, (d) => d.id);
      upsert('cashEntries', _cashEntries, SnapshotCodec.parseCashEntry, (e) => e.id);
      upsert('receipts', _receipts, SnapshotCodec.parseReceipt, (r) => r.id);
      // The phone writes its own log row the moment something happens, and
      // the server writes one when it takes the same change. They describe
      // one event under two ids, so the server's row replaces the phone's.
      for (final raw in (changes['logs'] as List? ?? const [])) {
        final record = SnapshotCodec.parseLog((raw as Map).cast<String, dynamic>());
        final index = _logs.indexWhere((existing) =>
            existing.id == record.id || _sameEvent(existing, record));
        if (index == -1) {
          _logs.add(record);
        } else {
          _logs[index] = record;
        }
      }
      for (final id in (deleted['logs'] as List? ?? const [])) {
        _logs.removeWhere((existing) => existing.id == '$id');
      }
      upsert('goldRates', _goldRates, SnapshotCodec.parseGoldRate, (r) => '${r.karat}');
      // Rate history has no id of its own; it is replaced wholesale when sent.
      if (changes['rateHistory'] is List) {
        for (final raw in changes['rateHistory'] as List) {
          final change = SnapshotCodec.parseRateChange((raw as Map).cast<String, dynamic>());
          final already = _rateHistory.any((c) =>
              c.karat == change.karat && c.at == change.at && c.afterCentavos == change.afterCentavos);
          if (!already) _rateHistory.add(change);
        }
      }
      _syncUsers();
    } finally {
      _applyingRemote = false;
    }
    notifyListeners();
  }

  /// Two log rows for one event: same action, same record, same person, same
  /// money, within a couple of minutes of each other. Only ever used to let
  /// the server's row take the place of the phone's.
  static bool _sameEvent(TransactionLog a, TransactionLog b) =>
      a.action == b.action &&
      a.recordId == b.recordId &&
      a.recordId != null &&
      a.userId == b.userId &&
      a.amountCentavos == b.amountCentavos &&
      a.at.difference(b.at).abs() < const Duration(minutes: 2);

  /// Replaces everything with a server snapshot, without queueing any of it
  /// back. Used right after sign-in.
  void applyServerSnapshot(Map<String, dynamic> snapshot) {
    _applyingRemote = true;
    try {
      restoreSnapshot(snapshot);
    } finally {
      _applyingRemote = false;
    }
  }

  void resetToSeed() {
    _loadSeed();
    notifyListeners();
  }

  /// Wipes every transactional record — items, sales, commitments, disposal
  /// batches, cash ledger entries — and zeroes both branches' starting
  /// balances, for testers who'd rather start from a genuinely blank slate
  /// than the populated demo state. Branch identities and gold rates stay,
  /// since the app has nowhere to record a purchase or loan without them.
  void resetToEmpty() {
    _branches = [
      for (final b in SeedData.branches())
        Branch(id: b.id, startingCashBalanceCentavos: 0, startingSalesCashCentavos: 0, bankBalanceCentavos: 0),
    ];
    _goldRates = List.of(SeedData.goldRates());
    _rateHistory = List.of(SeedData.rateHistory(_goldRates));
    _items = [];
    _sales = [];
    _commitments = [];
    _disposalBatches = [];
    _purchaseBatches = [];
    _customers = [];
    _logs = [];
    _receipts = [];
    _cashEntries = [];
    notifyListeners();
  }

  // --- Staff -------------------------------------------------------------
  /// Staff who can currently act.
  List<AppUser> get users => StaffDirectory.all;

  /// Everyone on file, including deactivated staff.
  List<AppUser> get allUsers => List.unmodifiable(_users);

  AppUser? findUser(String? id) => StaffDirectory.byId(id);

  void _syncUsers() => StaffDirectory.replaceAll(_users);

  static String? _blankOrNull(String? v) => (v == null || v.trim().isEmpty) ? null : v.trim();

  /// Why [name] can't be used for a new or renamed user, or null if it can.
  /// Two staff with one name would make every record naming them ambiguous.
  String? userNameProblem(String name, {String? exceptId}) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return 'A user needs a name';
    final key = trimmed.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    for (final u in _users) {
      if (u.id == exceptId) continue;
      if (u.name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ') == key) {
        return '${u.name} is already on file${u.active ? '' : ' (deactivated)'}';
      }
    }
    return null;
  }

  static void _checkBranchForRole(AppUserRole role, BranchId? branch) {
    if (role != AppUserRole.admin && branch == null) {
      throw ArgumentError('A ${role.label} works from one branch — pick it');
    }
  }

  int get _activeAdminCount => _users.where((u) => u.active && u.role == AppUserRole.admin).length;

  /// How many records name [userId] — purchases, sales, cash, rates, logs.
  int userActivityCount(String userId) {
    var n = 0;
    n += _logs.where((l) => l.userId == userId).length;
    n += _items.where((i) => i.encodedByUserId == userId).length;
    n += _purchaseBatches.where((b) => b.submittedByUserId == userId || b.releasedByUserId == userId).length;
    n += _sales.where((x) => x.submittedByUserId == userId || x.receivedByUserId == userId).length;
    n += _cashEntries.where((e) => e.recordedByUserId == userId).length;
    n += _rateHistory.where((c) => c.userId == userId).length;
    return n;
  }

  AppUser addUser({
    required String name,
    required AppUserRole role,
    BranchId? homeBranch,
    String? contactNumber,
    AppUser? actor,
  }) {
    final problem = userNameProblem(name);
    if (problem != null) throw ArgumentError(problem);
    _checkBranchForRole(role, homeBranch);
    final user = AppUser(
      id: 'USR-${_newId()}',
      name: name.trim(),
      role: role,
      homeBranch: role == AppUserRole.admin ? null : homeBranch,
      contactNumber: _blankOrNull(contactNumber),
    );
    _users.add(user);
    _syncUsers();
    _log(
      action: LogAction.userAdded,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: user.homeBranch,
      recordId: user.id,
      recordKind: LogRecordKind.user,
      summary: 'Added ${user.name} as ${role.label}${user.homeBranch == null ? '' : ' at ${user.homeBranch!.label}'}',
    );
    _queue(
      'POST',
      'users',
      body: {
        'id': user.id,
        'name': user.name,
        'role': role.name,
        'home_branch': user.homeBranch?.name,
        'contact_number': user.contactNumber,
      },
      summary: 'Add user · ${user.name}',
    );
    notifyListeners();
    return user;
  }

  /// Edits a staff member's details. Past records keep their id, so they now
  /// show the corrected name — the person didn't change, only how they're
  /// written.
  List<FieldChange> updateUser(
    String id, {
    String? name,
    AppUserRole? role,
    BranchId? homeBranch,
    String? contactNumber,
    AppUser? actor,
  }) {
    final idx = _users.indexWhere((u) => u.id == id);
    if (idx == -1) throw ArgumentError('User not found');
    final old = _users[idx];
    final newName = name?.trim() ?? old.name;
    final newRole = role ?? old.role;
    final newBranch = newRole == AppUserRole.admin ? null : (homeBranch ?? old.homeBranch);
    final newContact = contactNumber == null ? old.contactNumber : _blankOrNull(contactNumber);

    if (newName != old.name) {
      final problem = userNameProblem(newName, exceptId: id);
      if (problem != null) throw ArgumentError(problem);
    }
    _checkBranchForRole(newRole, newBranch);
    if (old.active && old.role == AppUserRole.admin && newRole != AppUserRole.admin && _activeAdminCount <= 1) {
      throw StateError('${old.name} is the only active Admin — make someone else Admin first');
    }

    final changes = <FieldChange>[
      if (newName != old.name) FieldChange(field: 'Name', before: old.name, after: newName),
      if (newRole != old.role) FieldChange(field: 'Role', before: old.role.label, after: newRole.label),
      if (newBranch != old.homeBranch)
        FieldChange(
          field: 'Branch',
          before: old.homeBranch?.label ?? 'Both branches',
          after: newBranch?.label ?? 'Both branches',
        ),
      if (newContact != old.contactNumber)
        FieldChange(field: 'Contact', before: old.contactNumber ?? '—', after: newContact ?? '—'),
    ];
    if (changes.isEmpty) return changes;

    _users[idx] = AppUser(
      id: old.id,
      name: newName,
      role: newRole,
      homeBranch: newBranch,
      contactNumber: newContact,
      active: old.active,
    );
    _syncUsers();
    _log(
      action: LogAction.userUpdated,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: newBranch,
      recordId: id,
      recordKind: LogRecordKind.user,
      summary: 'Edited $newName — ${changes.map((c) => c.field.toLowerCase()).join(', ')}',
      changes: changes,
    );
    _queue(
      'PATCH',
      'users/$id',
      body: {
        'name': newName,
        'role': newRole.name,
        'home_branch': newBranch?.name,
        'contact_number': newContact,
      },
      summary: 'Edit user · $newName',
    );
    notifyListeners();
    return changes;
  }

  /// Turns a staff member off or back on. A deactivated person can't be
  /// picked to act as, but every record they made still names them.
  void setUserActive(String id, bool active, {AppUser? actor}) {
    final idx = _users.indexWhere((u) => u.id == id);
    if (idx == -1) throw ArgumentError('User not found');
    final old = _users[idx];
    if (old.active == active) return;
    if (!active) {
      if (actor != null && actor.id == id) {
        throw StateError('You can\'t deactivate yourself — switch to another Admin first');
      }
      if (old.role == AppUserRole.admin && _activeAdminCount <= 1) {
        throw StateError('${old.name} is the only active Admin — the shop needs at least one');
      }
    }
    _users[idx] = old.copyWith(active: active);
    _syncUsers();
    _log(
      action: active ? LogAction.userReactivated : LogAction.userDeactivated,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: old.homeBranch,
      recordId: id,
      recordKind: LogRecordKind.user,
      summary: '${active ? 'Reactivated' : 'Deactivated'} ${old.name} (${old.role.label})',
    );
    _queue(
      'POST',
      'users/$id/${active ? 'reactivate' : 'deactivate'}',
      summary: '${active ? 'Reactivate' : 'Deactivate'} user · ${old.name}',
    );
    notifyListeners();
  }

  /// Why [id] can't be deleted outright, or null if it can. Anyone who has
  /// done anything stays on file — deleting them would leave records naming
  /// nobody — so they are deactivated instead.
  String? userDeleteProblem(String id, {AppUser? actor}) {
    final user = findUser(id);
    if (user == null) return 'User not found';
    if (actor != null && actor.id == id) return 'You can\'t delete yourself';
    if (user.active && user.role == AppUserRole.admin && _activeAdminCount <= 1) {
      return '${user.name} is the only active Admin';
    }
    final count = userActivityCount(id);
    if (count > 0) {
      return '${user.name} appears on $count record(s). Deactivate them instead, so those records keep their name.';
    }
    return null;
  }

  void deleteUser(String id, {AppUser? actor}) {
    final problem = userDeleteProblem(id, actor: actor);
    if (problem != null) throw StateError(problem);
    final user = findUser(id)!;
    _users.removeWhere((u) => u.id == id);
    _syncUsers();
    _log(
      action: LogAction.userDeleted,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: user.homeBranch,
      recordId: id,
      recordKind: LogRecordKind.user,
      summary: 'Deleted ${user.name} (${user.role.label}) — added by mistake, never used',
    );
    _queue('DELETE', 'users/$id', summary: 'Delete user · ${user.name}');
    notifyListeners();
  }

  /// Whoever a record names, falling back to the staff member holding [role]
  /// at [branch] when the caller didn't say. Every record names a person.
  AppUser _actorOr(AppUser? actor, AppUserRole role, BranchId? branch) =>
      actor ?? StaffDirectory.forRole(role, branch: branch);

  // --- Transaction log ---------------------------------------------------
  // Append-only: entries are written as a side effect of each action and
  // nothing here edits or removes one. A log that could be quietly corrected
  // would not be evidence of anything.
  List<TransactionLog> get logs =>
      List.unmodifiable(_logs.toList()..sort((a, b) => b.at.compareTo(a.at)));

  /// Entries for one branch, plus the company-wide ones (a gold rate change
  /// applies wherever you stand).
  List<TransactionLog> logsForBranch(BranchId? branchId) {
    final list = branchId == null
        ? List.of(_logs)
        : _logs.where((l) => l.branch == null || l.branch == branchId).toList();
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  /// Everything the log holds about one record, oldest first — its story.
  List<TransactionLog> logsForRecord(String recordId) {
    final list = _logs.where((l) => l.recordId == recordId).toList();
    list.sort((a, b) => a.at.compareTo(b.at));
    return list;
  }

  void _log({
    required LogAction action,
    required AppUser actor,
    required String summary,
    BranchId? branch,
    String? recordId,
    LogRecordKind? recordKind,
    int? amountCentavos,
    List<FieldChange> changes = const [],
  }) {
    _logs.add(TransactionLog(
      id: _newId(),
      at: DateTime.now(),
      action: action,
      userId: actor.id,
      userName: actor.name,
      role: actor.role,
      summary: summary,
      branch: branch,
      recordId: recordId,
      recordKind: recordKind,
      amountCentavos: amountCentavos,
      changes: changes,
    ));
  }

  // --- Branches --------------------------------------------------------
  List<Branch> get branches => List.unmodifiable(_branches);

  Branch branch(BranchId id) => _branches.firstWhere((b) => b.id == id);

  // --- Gold rates --------------------------------------------------------
  /// Gold karats only, highest first. Silver fineness lives alongside in the
  /// same table but is listed through [silverRates].
  List<GoldRate> get goldRates => List.unmodifiable(
      (_goldRates.where((r) => !r.isSilver).toList())..sort((a, b) => b.karat.compareTo(a.karat)));

  List<GoldRate> get silverRates => List.unmodifiable(
      (_goldRates.where((r) => r.isSilver).toList())..sort((a, b) => b.karat.compareTo(a.karat)));

  /// The purities a piece of this type can be recorded at.
  List<GoldRate> ratesForType(ItemType type) => type.isSilver ? silverRates : goldRates;

  /// Silver takes a fineness, gold a karat — a 925 "goods" ring or an 18K
  /// "silver" chain would be priced from the wrong table.
  static void _checkPurity(ItemType type, int karat) {
    if (type.isSilver != isSilverPurity(karat)) {
      throw ArgumentError(type.isSilver
          ? 'A silver piece needs a silver purity (e.g. 925), not a gold karat'
          : 'A gold piece needs a karat, not a silver purity');
    }
  }

  GoldRate? rateForKarat(int karat) {
    for (final r in _goldRates) {
      if (r.karat == karat) return r;
    }
    return null;
  }

  /// Updates the buying rate for one karat — the admin-only edit path so a
  /// tester can plug in real market rates instead of the seeded demo ones.
  void updateGoldRate(int karat, int pricePerGramCentavos, {AppUser? actor, DateTime? restoredFrom}) {
    final i = _goldRates.indexWhere((r) => r.karat == karat);
    if (i == -1) return;
    if (pricePerGramCentavos <= 0) {
      throw ArgumentError('A rate must be above zero');
    }
    final before = _goldRates[i].pricePerGramCentavos;
    // Saving the same figure again is not a change, and must not clutter the
    // history with a row that says nothing happened.
    if (before == pricePerGramCentavos) return;
    final who = _actorOr(actor, AppUserRole.admin, null);
    _rateHistory.add(RateChange(
      karat: karat,
      beforeCentavos: before,
      afterCentavos: pricePerGramCentavos,
      at: DateTime.now(),
      userId: who.id,
      userName: who.name,
      restoredFrom: restoredFrom,
    ));
    _log(
      action: LogAction.goldRateUpdated,
      actor: who,
      summary: restoredFrom == null
          ? '${_purityText(karat)} rate changed from ${_peso(before)} to ${_peso(pricePerGramCentavos)} per gram'
          : '${_purityText(karat)} rate restored to ${_peso(pricePerGramCentavos)} per gram (was ${_peso(before)})',
      changes: [
        FieldChange(field: '${_purityText(karat)} per gram', before: _peso(before), after: _peso(pricePerGramCentavos)),
      ],
    );
    _goldRates[i] = _goldRates[i].copyWith(
      pricePerGramCentavos: pricePerGramCentavos,
      updatedAt: DateTime.now(),
    );
    _queue(
      'PATCH',
      'rates/$karat',
      body: {'price_per_gram_centavos': pricePerGramCentavos},
      summary: 'Rate · ${_purityText(karat)}',
    );
    notifyListeners();
  }

  /// Every price change across all gold and silver rates, newest first.
  List<RateChange> get allRateHistory =>
      List.unmodifiable(_rateHistory.toList()..sort((a, b) => b.at.compareTo(a.at)));

  /// The price in force for [karat] at the close of [day] — the last change
  /// made on or before it — or null if the rate hadn't been set yet.
  int? rateOn(int karat, DateTime day) {
    final close = DateTime(day.year, day.month, day.day).add(const Duration(days: 1));
    RateChange? latest;
    for (final c in _rateHistory) {
      if (c.karat != karat || !c.at.isBefore(close)) continue;
      if (latest == null || !c.at.isBefore(latest.at)) latest = c;
    }
    return latest?.afterCentavos;
  }

  /// Price changes made on [day] itself, newest first.
  List<RateChange> rateChangesOn(DateTime day) {
    return allRateHistory
        .where((c) => c.at.year == day.year && c.at.month == day.month && c.at.day == day.day)
        .toList();
  }

  /// Makes every gold (or every silver) rate what it was at the close of
  /// [day], in one go — the day's table is one set of quotes, and bringing
  /// back 18K from Tuesday next to 22K from today would be a table the shop
  /// never actually had. Rates not yet set on that day, or already at that
  /// price, are left alone. Returns how many rates changed.
  int applyRatesFrom(DateTime day, {required bool silver, AppUser? actor}) {
    final date = DateTime(day.year, day.month, day.day);
    var changed = 0;
    for (final rate in silver ? silverRates : goldRates) {
      final price = rateOn(rate.karat, date);
      if (price == null || price == rate.pricePerGramCentavos) continue;
      updateGoldRate(rate.karat, price, actor: actor, restoredFrom: date);
      changed++;
    }
    return changed;
  }

  /// Every price a karat or fineness has been set at, newest first.
  List<RateChange> rateHistory(int karat) {
    final list = _rateHistory.where((c) => c.karat == karat).toList();
    list.sort((a, b) => b.at.compareTo(a.at));
    return list;
  }

  /// Why [karat] can't be added as a new rate, or null if it can. Shared by
  /// the add dialog (to explain before the button is pressed) and [addRate]
  /// (to refuse regardless of what the UI allowed).
  String? rateAddProblem(int karat, {required bool silver}) {
    if (silver) {
      if (karat < 100 || karat > 999) {
        return 'Silver fineness is 100 to 999 (e.g. 925)';
      }
    } else if (karat < 1 || karat > 24) {
      return 'Gold karat is 1 to 24';
    }
    if (rateForKarat(karat) != null) {
      return '${_purityText(karat)} already has a rate — edit its price instead';
    }
    return null;
  }

  /// Adds a purity the shop hasn't priced before. One rate per karat or
  /// fineness: a second "18K" would leave the purchase form two different
  /// setup prices to choose from for the same gold.
  GoldRate addRate(int karat, int pricePerGramCentavos, {required bool silver, AppUser? actor}) {
    final problem = rateAddProblem(karat, silver: silver);
    if (problem != null) throw ArgumentError(problem);
    if (pricePerGramCentavos <= 0) {
      throw ArgumentError('A rate must be above zero');
    }
    final who = _actorOr(actor, AppUserRole.admin, null);
    final now = DateTime.now();
    final rate = GoldRate(karat: karat, pricePerGramCentavos: pricePerGramCentavos, updatedAt: now);
    _goldRates.add(rate);
    _rateHistory.add(RateChange(
      karat: karat,
      afterCentavos: pricePerGramCentavos,
      at: now,
      userId: who.id,
      userName: who.name,
    ));
    _log(
      action: LogAction.goldRateAdded,
      actor: who,
      summary: 'Added a ${_purityText(karat)} rate at ${_peso(pricePerGramCentavos)} per gram',
      changes: [
        FieldChange(field: '${_purityText(karat)} per gram', before: '—', after: _peso(pricePerGramCentavos)),
      ],
    );
    _queue(
      'POST',
      'rates',
      body: {'karat': karat, 'price_per_gram_centavos': pricePerGramCentavos, 'silver': silver},
      summary: 'Add rate · ${_purityText(karat)}',
    );
    notifyListeners();
    return rate;
  }

  // --- Cash ledger ---------------------------------------------------------
  // The single source of truth for every branch's cash balance. Nothing
  // else in this repository may add a stored balance field or mutate one
  // directly — every movement, whether it's the side effect of a purchase,
  // sale, or commitment, or a manual entry from the Cash screen, goes
  // through [_writeCashEntry] so [cashBalance] always reflects reality.
  List<CashEntry> get cashEntries => List.unmodifiable(_cashEntries);

  List<CashEntry> cashEntriesForBranch(BranchId? branchId, {CashAccount? account}) {
    final list = _cashEntries
        .where((e) => (branchId == null || e.branch == branchId) && (account == null || e.account == account))
        .toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  /// What [account] held at [branchId] before any ledger entry.
  int startingBalance(BranchId branchId, CashAccount account) {
    final b = branch(branchId);
    switch (account) {
      case CashAccount.purchase:
        return b.startingCashBalanceCentavos;
      case CashAccount.sales:
        return b.startingSalesCashCentavos;
      case CashAccount.bank:
        return b.bankBalanceCentavos;
    }
  }

  /// The live balance of one of a branch's three pools of money: its opening
  /// figure plus every signed ledger entry posted to it. Nothing else moves
  /// a balance.
  int accountBalance(BranchId branchId, CashAccount account) {
    final net = _cashEntries
        .where((e) => e.branch == branchId && e.account == account)
        .fold<int>(0, (sum, e) => sum + e.signedAmountCentavos);
    return startingBalance(branchId, account) + net;
  }

  /// Purchase cash — the float customers are paid out of. The figure the
  /// purchase screens check a release against.
  int cashBalance(BranchId branchId) => accountBalance(branchId, CashAccount.purchase);

  int salesCashBalance(BranchId branchId) => accountBalance(branchId, CashAccount.sales);

  /// Money into and out of one cash source on [day] (today when omitted).
  ({int inCentavos, int outCentavos}) cashFlowOn(BranchId branchId, CashAccount account, [DateTime? day]) {
    final d = day ?? DateTime.now();
    var inflow = 0;
    var outflow = 0;
    for (final e in _cashEntries) {
      if (e.branch != branchId || e.account != account) continue;
      if (e.date.year != d.year || e.date.month != d.month || e.date.day != d.day) continue;
      if (e.type.isCredit) {
        inflow += e.amountCentavos;
      } else {
        outflow += e.amountCentavos;
      }
    }
    return (inCentavos: inflow, outCentavos: outflow);
  }

  int bankBalance(BranchId branchId) => accountBalance(branchId, CashAccount.bank);

  /// Combined cash balance across every branch — Admin's "all branches" view.
  int combinedCashBalance() => _branches.fold<int>(0, (sum, b) => sum + cashBalance(b.id));

  CashEntry _writeCashEntry({
    required BranchId branch,
    required CashEntryType type,
    CashAccount account = CashAccount.purchase,
    String? id,
    required int amountCentavos,
    required String note,
    String? category,
    required DateTime date,
    required AppUserRole recordedByRole,
    String? recordedByUserId,
    CashEntrySourceType sourceType = CashEntrySourceType.manual,
    String? linkedRecordId,
    String? transferPairId,
  }) {
    final entry = CashEntry(
      id: id ?? _newId(),
      branch: branch,
      type: type,
      account: account,
      amountCentavos: amountCentavos,
      note: note,
      category: category,
      date: date,
      recordedByRole: recordedByRole,
      recordedByUserId: recordedByUserId,
      sourceType: sourceType,
      linkedRecordId: linkedRecordId,
      transferPairId: transferPairId,
    );
    _cashEntries.insert(0, entry);
    return entry;
  }

  /// Records a manual cash-in / expense / withdrawal entry — the three
  /// single-sided types a Cashier/Admin picks from New Cash Entry. A
  /// transfer always writes as a matched pair instead (see [recordTransfer])
  /// since it touches two branches at once.
  CashEntry recordCashEntry({
    required BranchId branch,
    required CashEntryType type,
    CashAccount account = CashAccount.purchase,
    required int amountCentavos,
    required String note,
    String? category,
    required DateTime date,
    required AppUserRole recordedByRole,
    AppUser? actor,
  }) {
    assert(
      type == CashEntryType.cashIn || type == CashEntryType.expense || type == CashEntryType.withdrawal,
      'Transfers must go through recordTransfer so both sides stay matched.',
    );
    final who = _actorOr(actor, recordedByRole, branch);
    final entry = _writeCashEntry(
      branch: branch,
      type: type,
      account: account,
      amountCentavos: amountCentavos,
      note: note,
      category: category,
      date: date,
      recordedByRole: recordedByRole,
      recordedByUserId: who.id,
    );
    _log(
      action: LogAction.cashEntryRecorded,
      actor: who,
      branch: branch,
      recordId: entry.id,
      recordKind: LogRecordKind.cashEntry,
      amountCentavos: amountCentavos,
      summary: '${type.label} of ${_peso(amountCentavos)} (${account.label}) — $note',
    );
    _queue(
      'POST',
      'cash/entries',
      body: {
        'id': entry.id,
        'branch': branch.name,
        'type': type.name,
        'account': account.name,
        'amount_centavos': amountCentavos,
        'note': note,
        'category': category,
        'date': date.toIso8601String(),
      },
      summary: '${type.label} · ${_peso(amountCentavos)}',
      at: date,
    );
    notifyListeners();
    return entry;
  }

  /// Moves cash between branches as one atomic matched pair — a
  /// `transferOut` from [from] and a `transferIn` into [to], sharing a
  /// transfer id so the two sides can never drift apart or be edited
  /// independently.
  (CashEntry, CashEntry) recordTransfer({
    required BranchId from,
    required BranchId to,
    CashAccount fromAccount = CashAccount.purchase,
    CashAccount toAccount = CashAccount.purchase,
    required int amountCentavos,
    required String note,
    required DateTime date,
    required AppUserRole recordedByRole,
    AppUser? actor,
  }) {
    // Within one branch a transfer moves money between its pools (sales
    // takings into the float, cash to the bank); it only has to go somewhere.
    if (from == to && fromAccount == toAccount) {
      throw ArgumentError('A transfer needs a different branch or a different cash source');
    }
    final who = _actorOr(actor, recordedByRole, from);
    final pairId = _newId();
    final outEntry = _writeCashEntry(
      branch: from,
      type: CashEntryType.transferOut,
      account: fromAccount,
      amountCentavos: amountCentavos,
      note: note,
      date: date,
      recordedByRole: recordedByRole,
      recordedByUserId: who.id,
      transferPairId: pairId,
    );
    final inEntry = _writeCashEntry(
      branch: to,
      type: CashEntryType.transferIn,
      account: toAccount,
      amountCentavos: amountCentavos,
      note: note,
      date: date,
      recordedByRole: recordedByRole,
      recordedByUserId: who.id,
      transferPairId: pairId,
    );
    _log(
      action: LogAction.cashTransferred,
      actor: who,
      branch: from,
      recordId: outEntry.id,
      recordKind: LogRecordKind.cashEntry,
      amountCentavos: amountCentavos,
      summary: 'Moved ${_peso(amountCentavos)} from ${from.label} ${fromAccount.label} '
          'to ${to.label} ${toAccount.label} — $note',
    );
    _queue(
      'POST',
      'cash/transfers',
      body: {
        'from_branch': from.name,
        'from_account': fromAccount.name,
        'to_branch': to.name,
        'to_account': toAccount.name,
        'amount_centavos': amountCentavos,
        'note': note,
        'date': date.toIso8601String(),
        'out_id': outEntry.id,
        'in_id': inEntry.id,
        'pair_id': pairId,
      },
      summary: 'Transfer · ${_peso(amountCentavos)}',
      at: date,
    );
    notifyListeners();
    return (outEntry, inEntry);
  }

  CashEntry? findCashEntry(String id) {
    for (final e in _cashEntries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Both halves of a transfer, out first — or just [entry] if it isn't one.
  List<CashEntry> cashEntryGroup(CashEntry entry) {
    if (entry.transferPairId == null) return [entry];
    return _cashEntries.where((e) => e.transferPairId == entry.transferPairId).toList()
      ..sort((a, b) => a.type == CashEntryType.transferOut ? -1 : (b.type == CashEntryType.transferOut ? 1 : 0));
  }

  /// Why [entry] can't be changed by hand, or null if it can. Linked entries
  /// are the cash side of a purchase, sale, or loan — editing one here would
  /// leave the ledger disagreeing with the record it came from, so they are
  /// corrected on that record instead.
  String? cashEntryLockReason(CashEntry entry) {
    if (entry.isManual) return null;
    return 'This entry was written by a ${entry.sourceType.name} '
        '(${entry.linkedRecordId ?? 'record'}). Correct it on that record, not in the cash history.';
  }

  static String _entryLabel(CashEntry e) => '${e.type.label} ${e.id}';

  /// Corrects a hand-typed cash entry. For a transfer, amount, note, and date
  /// change on both halves together, and each side can change its source;
  /// [type] and [category] apply to single entries only. Every changed field
  /// is written to the log with its before and after value.
  List<FieldChange> updateCashEntry(
    String id, {
    CashEntryType? type,
    CashAccount? account,
    CashAccount? destinationAccount,
    int? amountCentavos,
    String? note,
    String? category,
    DateTime? date,
    AppUser? actor,
  }) {
    final entry = findCashEntry(id);
    if (entry == null) throw ArgumentError('Cash entry not found');
    final lock = cashEntryLockReason(entry);
    if (lock != null) throw StateError(lock);
    if (amountCentavos != null && amountCentavos <= 0) {
      throw ArgumentError('Amount must be above zero');
    }
    if (note != null && note.trim().isEmpty) {
      throw ArgumentError('An entry needs a note');
    }

    final group = cashEntryGroup(entry);
    final changes = <FieldChange>[];
    final first = group.first;

    if (entry.isTransfer) {
      if (type != null && type != first.type) {
        throw ArgumentError('A transfer stays a transfer — delete it and record a new entry instead');
      }
      final out = group.firstWhere((e) => e.type == CashEntryType.transferOut, orElse: () => first);
      final inn = group.firstWhere((e) => e.type == CashEntryType.transferIn, orElse: () => first);
      final newFrom = account ?? out.account;
      final newTo = destinationAccount ?? inn.account;
      if (out.branch == inn.branch && newFrom == newTo) {
        throw ArgumentError('A transfer needs a different branch or a different cash source');
      }
      if (newFrom != out.account) {
        changes.add(FieldChange(field: 'From source', before: out.account.label, after: newFrom.label));
      }
      if (newTo != inn.account) {
        changes.add(FieldChange(field: 'To source', before: inn.account.label, after: newTo.label));
      }
    } else {
      if (type != null && type != entry.type) {
        if (!(type == CashEntryType.cashIn || type == CashEntryType.expense || type == CashEntryType.withdrawal)) {
          throw ArgumentError('Only cash in, expense, or withdrawal');
        }
        changes.add(FieldChange(field: 'Type', before: entry.type.label, after: type.label));
      }
      if (account != null && account != entry.account) {
        changes.add(FieldChange(field: 'Cash source', before: entry.account.label, after: account.label));
      }
      final newType = type ?? entry.type;
      final newCategory = newType == CashEntryType.expense ? (category ?? entry.category) : null;
      if (newType == CashEntryType.expense && (newCategory == null || newCategory.isEmpty)) {
        throw ArgumentError('An expense needs a category');
      }
      if (newCategory != entry.category) {
        changes.add(FieldChange(field: 'Category', before: entry.category ?? '—', after: newCategory ?? '—'));
      }
    }
    if (amountCentavos != null && amountCentavos != first.amountCentavos) {
      changes.add(FieldChange(field: 'Amount', before: _peso(first.amountCentavos), after: _peso(amountCentavos)));
    }
    if (note != null && note.trim() != first.note) {
      changes.add(FieldChange(field: 'Note', before: first.note, after: note.trim()));
    }
    if (date != null && date != first.date) {
      changes.add(FieldChange(
        field: 'Date',
        before: '${first.date.year}-${first.date.month}-${first.date.day}',
        after: '${date.year}-${date.month}-${date.day}',
      ));
    }
    if (changes.isEmpty) return changes;

    for (final e in group) {
      final idx = _cashEntries.indexWhere((x) => x.id == e.id);
      final newType = entry.isTransfer ? e.type : (type ?? e.type);
      _cashEntries[idx] = e.copyWith(
        type: newType,
        account: entry.isTransfer
            ? (e.type == CashEntryType.transferOut ? (account ?? e.account) : (destinationAccount ?? e.account))
            : (account ?? e.account),
        amountCentavos: amountCentavos,
        note: note?.trim(),
        category: category,
        clearCategory: !entry.isTransfer && newType != CashEntryType.expense,
        date: date,
      );
    }
    _log(
      action: LogAction.cashEntryEdited,
      actor: _actorOr(actor, AppUserRole.admin, entry.branch),
      branch: entry.branch,
      recordId: entry.id,
      recordKind: LogRecordKind.cashEntry,
      amountCentavos: amountCentavos ?? first.amountCentavos,
      summary: 'Corrected ${_entryLabel(first)} — ${changes.map((c) => c.field.toLowerCase()).join(', ')}',
      changes: changes,
    );
    _queue(
      'PATCH',
      'cash/entries/$id',
      body: {
        'type': entry.isTransfer ? null : (type ?? entry.type).name,
        'account': (account ?? first.account).name,
        'destination_account': entry.isTransfer ? (destinationAccount ?? group.last.account).name : null,
        'amount_centavos': amountCentavos,
        'note': note?.trim(),
        'category': category,
        'date': date?.toIso8601String(),
      },
      summary: 'Edit cash entry · $id',
    );
    notifyListeners();
    return changes;
  }

  /// Removes a hand-typed cash entry recorded by mistake — both halves, for a
  /// transfer. The balance moves back as if it had never been entered; the
  /// log keeps what it was, who removed it, and why.
  void deleteCashEntry(String id, {String? reason, AppUser? actor}) {
    final entry = findCashEntry(id);
    if (entry == null) throw ArgumentError('Cash entry not found');
    final lock = cashEntryLockReason(entry);
    if (lock != null) throw StateError(lock);

    final group = cashEntryGroup(entry);
    final ids = group.map((e) => e.id).toSet();
    _cashEntries.removeWhere((e) => ids.contains(e.id));

    final first = group.first;
    final where = entry.isTransfer
        ? '${group.first.branch.label} ${group.first.account.label} → ${group.last.branch.label} ${group.last.account.label}'
        : '${entry.branch.label} ${entry.account.label}';
    _log(
      action: LogAction.cashEntryDeleted,
      actor: _actorOr(actor, AppUserRole.admin, entry.branch),
      branch: entry.branch,
      recordId: first.id,
      recordKind: LogRecordKind.cashEntry,
      amountCentavos: first.amountCentavos,
      summary: 'Deleted ${_entryLabel(first)} of ${_peso(first.amountCentavos)} ($where) — ${first.note}'
          '${reason == null || reason.trim().isEmpty ? '' : '. Reason: ${reason.trim()}'}',
      changes: [
        FieldChange(field: 'Type', before: first.type.label, after: '—'),
        FieldChange(field: 'Amount', before: _peso(first.amountCentavos), after: '—'),
        FieldChange(field: 'Source', before: where, after: '—'),
        FieldChange(field: 'Note', before: first.note, after: '—'),
        if (first.category != null) FieldChange(field: 'Category', before: first.category!, after: '—'),
      ],
    );
    _queue('DELETE', 'cash/entries/$id', body: {'reason': reason}, summary: 'Delete cash entry · $id');
    notifyListeners();
  }

  // --- Items ---------------------------------------------------------------
  List<Item> get items => List.unmodifiable(_items);

  // Always a fresh, mutable copy — never the raw `items` getter. A caller
  // with no active filters (e.g. combined-branch view, nothing narrowed
  // yet) would otherwise inherit an unmodifiable list and crash the
  // moment it tries to sort it in place.
  List<Item> itemsForBranch(BranchId? branchId) {
    if (branchId == null) return List.of(_items);
    return _items.where((i) => i.branch == branchId).toList();
  }

  /// Items encoded by [role] still waiting on cashier verification —
  /// what an Appraiser/Sales Rep sees as "my submissions".
  List<Item> itemsAwaitingVerificationFor(AppUserRole role, {BranchId? branchId}) {
    return itemsForBranch(branchId)
        .where((i) =>
            i.submittedByRole == role &&
            i.verificationStatus == VerificationStatus.awaitingVerification)
        .toList();
  }

  /// Newly encoded purchases still sitting in the cashier's queue.
  List<Item> purchasesAwaitingCashRelease({BranchId? branchId}) {
    return itemsForBranch(branchId)
        .where((i) => i.itemStatus == ItemStatus.pending)
        .toList();
  }

  /// Scrap sitting in the disposal pool — verified, `forDisposal`, and with
  /// actual weight left (a partitioned lot fully drawn down has nothing
  /// left to dispose of even if its status hasn't been touched since).
  ///
  /// With [silver], the pool is silver stock instead: any verified silver
  /// piece still listed (not sold, not held in an order) can be disposed,
  /// just as it can be sold — whichever happens first takes it off the other.
  List<Item> itemsForDisposal({BranchId? branchId, bool silver = false}) {
    if (silver) {
      return itemsForBranch(branchId)
          .where((i) =>
              i.type == ItemType.silver &&
              i.itemStatus == ItemStatus.listed &&
              i.verificationStatus == VerificationStatus.verified &&
              i.effectiveRemainingGrams > 0)
          .toList();
    }
    return itemsForBranch(branchId)
        .where((i) => i.itemStatus == ItemStatus.forDisposal && i.effectiveRemainingGrams > 0)
        .toList();
  }

  /// Every verified silver piece for the branch — listed, sold, or disposed —
  /// for the Dispose tab's Silver list.
  List<Item> allSilver({BranchId? branchId}) {
    return itemsForBranch(branchId)
        .where((i) => i.type == ItemType.silver && i.verificationStatus == VerificationStatus.verified)
        .toList();
  }

  /// Every scrap record for the branch — bulk lots and the partitions drawn
  /// out of them, disposed or not. [itemsForDisposal] is the narrower live
  /// pool still waiting on a batch.
  List<Item> allScrap({BranchId? branchId}) {
    return itemsForBranch(branchId).where((i) => i.type == ItemType.scrap).toList();
  }

  Item? findItem(String id) {
    for (final i in _items) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Direct children partitioned out of [parentId], newest first.
  List<Item> partitionsOf(String parentId) {
    return _items.where((i) => i.parentLotId == parentId).toList()
      ..sort((a, b) => b.purchaseDate.compareTo(a.purchaseDate));
  }

  /// Items this [role] submitted that a Cashier sent back — surfaced on the
  /// Purchase tab so the appraiser knows to fix and resubmit them.
  List<Item> returnedForCorrectionFor(AppUserRole role, {BranchId? branchId}) {
    return itemsForBranch(branchId)
        .where((i) =>
            i.submittedByRole == role &&
            i.verificationStatus == VerificationStatus.returnedForCorrection)
        .toList();
  }

  ItemStatus _postVerificationStatus(ItemType type) =>
      type == ItemType.scrap ? ItemStatus.forDisposal : ItemStatus.listed;

  // --- Customers -----------------------------------------------------------
  // Kept as records rather than text copied onto each transaction: the same
  // person sells scrap in March and buys a ring in December, and their
  // history has to be answerable from the person, not just from the pile.
  List<Customer> get customers =>
      List.unmodifiable(_customers.toList()..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase())));

  Customer? findCustomer(String id) {
    for (final c in _customers) {
      if (c.id == id) return c;
    }
    return null;
  }

  Customer? customerByName(String name) {
    final key = Customer.matchKey(name);
    if (key.isEmpty) return null;
    for (final c in _customers) {
      if (c.key == key) return c;
    }
    return null;
  }

  /// Name matches for a type-ahead, best first: names that start with what
  /// has been typed before names that merely contain it, since someone
  /// keying "ma" is far more often reaching for Maria than for Norma.
  List<Customer> searchCustomers(String query, {int limit = 6}) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];

    final starts = <Customer>[];
    final contains = <Customer>[];
    for (final c in _customers) {
      final name = c.name.toLowerCase();
      if (name.startsWith(q)) {
        starts.add(c);
      } else if (name.contains(q) || (c.contactNumber ?? '').contains(q)) {
        contains.add(c);
      }
    }
    int byName(Customer a, Customer b) => a.name.toLowerCase().compareTo(b.name.toLowerCase());
    starts.sort(byName);
    contains.sort(byName);
    return [...starts, ...contains].take(limit).toList();
  }

  /// Files the customer on a transaction, reusing the existing record when
  /// the name matches one.
  ///
  /// Details already on file are never blanked by a transaction that omitted
  /// them — a rushed counter entry with no address must not erase the address
  /// captured last month — but newly supplied details do update the record.
  Customer upsertCustomer(CustomerDetails details) {
    final existing = details.customerId != null
        ? findCustomer(details.customerId!)
        : customerByName(details.name);

    if (existing == null) {
      final customer = Customer(
        id: _newId(),
        name: details.name.trim(),
        contactNumber: _blankToNull(details.contactNumber),
        address: _blankToNull(details.address),
        firstSeen: DateTime.now(),
        photo: details.photo,
      );
      _customers.add(customer);
      notifyListeners();
      return customer;
    }

    final updated = existing.copyWith(
      name: details.name.trim().isEmpty ? null : details.name.trim(),
      contactNumber: _blankToNull(details.contactNumber),
      address: _blankToNull(details.address),
      // A newly taken photo replaces the old one; no photo on this visit
      // leaves the one on file alone.
      photo: details.photo,
    );
    _customers[_customers.indexWhere((c) => c.id == existing.id)] = updated;
    _queue(
      'PATCH',
      'customers/${updated.id}',
      body: {
        'name': updated.name,
        'contact_number': updated.contactNumber,
        'address': updated.address,
      },
      summary: 'Customer · ${updated.name}',
    );
    notifyListeners();
    return updated;
  }

  /// The live record behind a transaction's customer, if it is linked.
  Customer? customerFor(CustomerDetails details) =>
      details.customerId == null ? null : findCustomer(details.customerId!);

  /// Files or replaces a customer's photo outside of any transaction — from
  /// their record in the customer book.
  void setCustomerPhoto(String customerId, Uint8List photo, {AppUser? actor}) {
    final idx = _customers.indexWhere((c) => c.id == customerId);
    if (idx == -1) return;
    final customer = _customers[idx];
    _customers[idx] = customer.copyWith(photo: photo);
    _log(
      action: LogAction.customerPhotoUpdated,
      actor: _actorOr(actor, AppUserRole.admin, null),
      recordId: customer.id,
      recordKind: LogRecordKind.customer,
      summary: '${customer.hasPhoto ? 'Replaced' : 'Added'} the photo of ${customer.name}',
    );
    _queue(
      'PUT',
      'customers/$customerId/photo',
      body: {'photo': SnapshotCodec.encodePhoto(photo)},
      summary: 'Customer photo · ${customer.name}',
    );
    notifyListeners();
  }

  static String _karatText(int karat) => isSilverPurity(karat) ? '$karat' : '${karat}K';

  static String _purityText(int karat) => isSilverPurity(karat) ? '$karat silver' : '${karat}K';

  static String? _blankToNull(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Everything the shop has done with one customer, newest first — what they
  /// sold in, what they bought, and for how much.
  List<PurchaseBatch> purchasesByCustomer(String customerId) {
    final list = _purchaseBatches
        .where((b) => b.customer.customerId == customerId)
        .toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  List<Sale> salesByCustomer(String customerId) {
    final list = _sales.where((s) => s.customer.customerId == customerId).toList();
    list.sort((a, b) => b.date.compareTo(a.date));
    return list;
  }

  // --- Issued receipts -----------------------------------------------------
  // The shop's own copy of every document it has handed out. Kept here rather
  // than only pushed to a share sheet, so a receipt can be reopened months
  // later without the customer's copy being the only one that exists.
  List<StoredReceipt> get receipts =>
      List.unmodifiable(_receipts.toList()..sort((a, b) => b.issuedAt.compareTo(a.issuedAt)));

  List<StoredReceipt> receiptsForBranch(BranchId? branchId) {
    final list = branchId == null
        ? List.of(_receipts)
        : _receipts.where((r) => r.branch == branchId).toList();
    list.sort((a, b) => b.issuedAt.compareTo(a.issuedAt));
    return list;
  }

  /// The receipt issued for one purchase batch or sale, if there is one.
  StoredReceipt? receiptForRecord(String recordId) {
    for (final r in _receipts) {
      if (r.recordId == recordId) return r;
    }
    return null;
  }

  /// Whether the record behind a receipt has reached the point where a
  /// receipt means anything: the cash is out of the drawer, or the payment
  /// is in it. Returns null when it has, or the reason it has not.
  String? receiptBlockedReason(String recordId, ReceiptKind kind) {
    switch (kind) {
      case ReceiptKind.purchase:
        final batch = findBatch(recordId);
        if (batch == null) return 'That purchase is no longer on this phone.';
        if (batch.verificationStatus != VerificationStatus.verified) {
          return 'The receipt is issued once a Cashier releases the cash.';
        }
      case ReceiptKind.sale:
        final sale = findSale(recordId);
        if (sale == null) return 'That order is no longer on this phone.';
        if (sale.verificationStatus != VerificationStatus.verified) {
          return 'The receipt is issued once payment is received.';
        }
    }
    return null;
  }

  /// Files a freshly generated receipt. Re-issuing for the same record
  /// replaces the stored copy rather than piling up near-identical documents.
  StoredReceipt storeReceipt({
    required String recordId,
    required ReceiptKind kind,
    required BranchId branch,
    required String counterparty,
    required int totalCentavos,
    required Uint8List bytes,
    String text = '',
  }) {
    final blocked = receiptBlockedReason(recordId, kind);
    if (blocked != null) throw StateError(blocked);
    final receipt = StoredReceipt(
      id: _newId(),
      recordId: recordId,
      kind: kind,
      branch: branch,
      counterparty: counterparty,
      totalCentavos: totalCentavos,
      issuedAt: DateTime.now(),
      bytes: bytes,
      text: text,
    );
    _receipts.removeWhere((r) => r.recordId == recordId);
    _receipts.insert(0, receipt);
    _queue(
      'POST',
      'receipts',
      body: {'id': receipt.id, 'record_id': recordId, 'kind': kind.name},
      summary: '${kind.label} receipt · $recordId',
    );
    notifyListeners();
    return receipt;
  }

  // --- Purchase batches ----------------------------------------------------
  // A purchase is a transaction, not a piece: a customer walks in with
  // however many items and is paid once for the lot. The batch carries the
  // customer and the verification status; the items carry the goods.
  List<PurchaseBatch> get purchaseBatches => List.unmodifiable(_purchaseBatches);

  List<PurchaseBatch> purchaseBatchesForBranch(BranchId? branchId) {
    if (branchId == null) return List.of(_purchaseBatches);
    return _purchaseBatches.where((b) => b.branch == branchId).toList();
  }

  PurchaseBatch? findBatch(String id) {
    for (final b in _purchaseBatches) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Every item recorded under one batch, in the order they were entered.
  /// Partitions are excluded — they inherit their lot's batch for provenance
  /// but were never part of what the customer handed over.
  List<Item> itemsInBatch(String batchId) => _items
      .where((i) => i.batchId == batchId && !i.isPartitioned)
      .toList()
      .reversed
      .toList();

  /// What the customer is owed for the whole batch.
  int batchTotalCentavos(String batchId) =>
      itemsInBatch(batchId).fold<int>(0, (sum, i) => sum + i.capitalAmountCentavos);

  /// Batches sitting in the Cashier's queue, waiting on one release decision.
  List<PurchaseBatch> purchaseBatchesAwaitingRelease({BranchId? branchId}) {
    return purchaseBatchesForBranch(branchId)
        .where((b) => b.verificationStatus == VerificationStatus.awaitingVerification)
        .toList();
  }

  /// Batches [role] submitted that are still waiting on a Cashier.
  List<PurchaseBatch> batchesAwaitingVerificationFor(AppUserRole role, {BranchId? branchId}) {
    return purchaseBatchesForBranch(branchId)
        .where((b) =>
            b.submittedByRole == role &&
            b.verificationStatus == VerificationStatus.awaitingVerification)
        .toList();
  }

  /// Batches a Cashier sent back to [role] to fix.
  List<PurchaseBatch> returnedBatchesFor(AppUserRole role, {BranchId? branchId}) {
    return purchaseBatchesForBranch(branchId)
        .where((b) =>
            b.submittedByRole == role &&
            b.verificationStatus == VerificationStatus.returnedForCorrection)
        .toList();
  }

  /// Records a whole counter transaction: the customer, and every piece they
  /// brought in. Cash has NOT moved yet — the batch sits
  /// `awaitingVerification` until a Cashier releases it via
  /// [releaseBatchCash].
  PurchaseBatch recordPurchaseBatch({
    required CustomerDetails customer,
    required List<PurchaseDraftLine> lines,
    required BranchId branch,
    required DateTime purchaseDate,
    required AppUserRole submittedByRole,
    AppUser? actor,
  }) {
    if (lines.isEmpty) {
      throw ArgumentError('A purchase needs at least one item');
    }
    for (final line in lines) {
      _checkPurity(line.type, line.karat);
    }
    final who = _actorOr(actor, submittedByRole, branch);
    // File the counterparty before the transaction, so the batch carries a
    // link back to a real record rather than only a name.
    final saved = upsertCustomer(customer);
    final batch = PurchaseBatch(
      id: _newId(),
      customer: customer.withId(saved.id),
      branch: branch,
      date: purchaseDate,
      submittedByRole: submittedByRole,
      submittedByUserId: who.id,
      verificationStatus: VerificationStatus.awaitingVerification,
    );
    _purchaseBatches.insert(0, batch);

    for (final line in lines) {
      _items.insert(
        0,
        Item(
          id: _newId(),
          description: line.description,
          weightGrams: line.weightGrams,
          grossWeightGrams: line.grossWeightGrams,
          karat: line.karat,
          type: line.type,
          capitalAmountCentavos: line.capitalAmountCentavos,
          origin: customer.name,
          branch: branch,
          itemStatus: ItemStatus.pending,
          verificationStatus: VerificationStatus.awaitingVerification,
          purchaseDate: purchaseDate,
          submittedByRole: submittedByRole,
          photo: line.photo,
          encodedByUserId: who.id,
          batchId: batch.id,
        ),
      );
    }
    final total = lines.fold<int>(0, (sum, l) => sum + l.capitalAmountCentavos);
    _log(
      action: LogAction.purchaseRecorded,
      actor: who,
      branch: branch,
      recordId: batch.id,
      recordKind: LogRecordKind.purchaseBatch,
      amountCentavos: total,
      summary: 'Recorded ${lines.length} item(s) from ${customer.name} for ${_peso(total)}',
    );
    _queue(
      'POST',
      'purchases',
      body: {
        'id': batch.id,
        'branch': branch.name,
        'date': purchaseDate.toIso8601String(),
        'customer': _customerBody(batch.customer),
        'lines': [
          for (final item in itemsInBatch(batch.id))
            {
              'id': item.id,
              'description': item.description,
              'weight_grams': _grams(item.weightGrams),
              'gross_weight_grams': _grams(item.effectiveGrossWeightGrams),
              'karat': item.karat,
              'type': item.type.name,
              'amount_centavos': item.capitalAmountCentavos,
              'photo': SnapshotCodec.encodePhoto(item.photo),
            },
        ],
      },
      summary: 'Purchase ${batch.id} · ${batch.customer.name}',
      at: purchaseDate,
    );
    notifyListeners();
    return batch;
  }

  /// Convenience for the places that record exactly one piece — a
  /// single-item purchase is simply a batch of one.
  Item addPurchase({
    required String description,
    required double weightGrams,
    double? grossWeightGrams,
    required int karat,
    required ItemType type,
    required int capitalAmountCentavos,
    required String origin,
    required BranchId branch,
    required DateTime purchaseDate,
    required AppUserRole submittedByRole,
    AppUser? actor,
  }) {
    _checkPurity(type, karat);
    final batch = recordPurchaseBatch(
      customer: CustomerDetails(name: origin),
      lines: [
        PurchaseDraftLine(
          description: description,
          grossWeightGrams: grossWeightGrams ?? weightGrams,
          weightGrams: weightGrams,
          karat: karat,
          type: type,
          capitalAmountCentavos: capitalAmountCentavos,
        ),
      ],
      branch: branch,
      purchaseDate: purchaseDate,
      submittedByRole: submittedByRole,
      actor: actor,
    );
    return itemsInBatch(batch.id).first;
  }

  /// Re-encodes a `returnedForCorrection` item and puts its batch back in the
  /// Cashier's queue.
  void resubmitItem(
    String id, {
    required String description,
    required double weightGrams,
    double? grossWeightGrams,
    required int karat,
    required ItemType type,
    required int capitalAmountCentavos,
    required String origin,
    AppUser? actor,
  }) {
    _checkPurity(type, karat);
    final idx = _items.indexWhere((i) => i.id == id);
    if (idx == -1) return;
    final old = _items[idx];
    _items[idx] = Item(
      id: old.id,
      description: description,
      weightGrams: weightGrams,
      grossWeightGrams: grossWeightGrams ?? old.grossWeightGrams,
      karat: karat,
      type: type,
      capitalAmountCentavos: capitalAmountCentavos,
      origin: origin,
      branch: old.branch,
      itemStatus: ItemStatus.pending,
      verificationStatus: VerificationStatus.awaitingVerification,
      purchaseDate: old.purchaseDate,
      submittedByRole: old.submittedByRole,
      // Rebuilt from scratch, so anything not restated here is lost — the
      // photo and the encoder in particular must survive a correction.
      photo: old.photo,
      encodedByUserId: old.encodedByUserId,
      batchId: old.batchId,
      parentLotId: old.parentLotId,
      originalGrams: old.originalGrams,
      originalAmountCentavos: old.originalAmountCentavos,
      remainingGrams: old.remainingGrams,
      remainingAmountCentavos: old.remainingAmountCentavos,
    );

    final batchIdx = _purchaseBatches.indexWhere((b) => b.id == old.batchId);
    if (batchIdx != -1) {
      _purchaseBatches[batchIdx] = _purchaseBatches[batchIdx].copyWith(
        verificationStatus: VerificationStatus.awaitingVerification,
        clearVerificationNote: true,
      );
    }
    _log(
      action: LogAction.purchaseResubmitted,
      actor: _actorOr(actor, old.submittedByRole, old.branch),
      branch: old.branch,
      recordId: old.batchId,
      recordKind: LogRecordKind.purchaseBatch,
      amountCentavos: capitalAmountCentavos,
      summary: 'Corrected "$description" and sent the purchase back to the Cashier',
      changes: _diffItem(old, _items[idx]),
    );
    notifyListeners();
  }

  /// Cashier action: confirms a whole batch against the physical pieces and
  /// releases the customer's cash in one movement — which is how the counter
  /// actually works, and why the ledger gets a single entry for the batch
  /// rather than one per piece.
  void releaseBatchCash(
    String batchId, {
    AppUserRole recordedByRole = AppUserRole.cashier,
    Uint8List? proofPhoto,
    String? cashEntryId,
    AppUser? actor,
  }) {
    final releaseEntryId = cashEntryId ?? _newId();
    final batchIdx = _purchaseBatches.indexWhere((b) => b.id == batchId);
    if (batchIdx == -1) return;
    final batch = _purchaseBatches[batchIdx];
    final who = _actorOr(actor, recordedByRole, batch.branch);
    if (batch.verificationStatus == VerificationStatus.verified) return;
    if (batch.verificationStatus == VerificationStatus.returnedForCorrection) {
      throw StateError(
        'This purchase was returned for correction — it can be released once it is resubmitted',
      );
    }
    if (proofPhoto == null) {
      throw ArgumentError('A photo of the cash being handed over is required to release it');
    }

    final lines = itemsInBatch(batchId);
    if (lines.isEmpty) return;

    for (final line in lines) {
      final idx = _items.indexWhere((i) => i.id == line.id);
      if (idx == -1) continue;
      _items[idx] = _items[idx].copyWith(
        itemStatus: _postVerificationStatus(_items[idx].type),
        verificationStatus: VerificationStatus.verified,
        clearVerificationNote: true,
      );
    }

    final total = lines.fold<int>(0, (sum, i) => sum + i.capitalAmountCentavos);
    _purchaseBatches[batchIdx] = batch.copyWith(
      verificationStatus: VerificationStatus.verified,
      clearVerificationNote: true,
      releasedAt: DateTime.now(),
      releasedByUserId: who.id,
      releaseProofPhoto: proofPhoto,
    );

    _writeCashEntry(
      branch: batch.branch,
      type: CashEntryType.expense,
      amountCentavos: total,
      note: 'Purchase released - ${batch.customer.name} (${lines.length} item(s))',
      category: 'Purchase',
      date: DateTime.now(),
      recordedByRole: recordedByRole,
      recordedByUserId: who.id,
      sourceType: CashEntrySourceType.purchase,
      linkedRecordId: batch.id,
      id: releaseEntryId,
    );
    _log(
      action: LogAction.cashReleased,
      actor: who,
      branch: batch.branch,
      recordId: batch.id,
      recordKind: LogRecordKind.purchaseBatch,
      amountCentavos: total,
      summary: 'Released ${_peso(total)} to ${batch.customer.name} for ${lines.length} item(s)',
    );
    _queue(
      'POST',
      'purchases/$batchId/release',
      body: {
        'proof_photo': SnapshotCodec.encodePhoto(proofPhoto),
        'cash_entry_id': releaseEntryId,
      },
      summary: 'Release cash · $batchId',
    );
    notifyListeners();
  }

  /// Releases the batch [itemId] belongs to.
  ///
  /// Cash always moves per batch — a customer is paid once for everything
  /// they brought in — so this is a convenience for the single-item
  /// purchases that make up most simple flows, not a second way to pay.
  void releaseCash(
    String itemId, {
    AppUserRole recordedByRole = AppUserRole.cashier,
    Uint8List? proofPhoto,
    AppUser? actor,
  }) {
    final batchId = findItem(itemId)?.batchId;
    if (batchId == null) return;
    releaseBatchCash(batchId, recordedByRole: recordedByRole, proofPhoto: proofPhoto, actor: actor);
  }

  /// Returns the batch [itemId] belongs to — the counterpart to
  /// [releaseCash], and likewise batch-wide.
  void returnForCorrection(String itemId, String note, {AppUser? actor}) {
    final batchId = findItem(itemId)?.batchId;
    if (batchId == null) return;
    returnBatchForCorrection(batchId, note, actor: actor);
  }

  /// Cashier action: sends a whole batch back to the encoder with a note
  /// instead of releasing cash.
  void returnBatchForCorrection(String batchId, String note, {AppUser? actor}) {
    final batchIdx = _purchaseBatches.indexWhere((b) => b.id == batchId);
    if (batchIdx == -1) return;
    final returning = _purchaseBatches[batchIdx];
    _log(
      action: LogAction.purchaseReturned,
      actor: _actorOr(actor, AppUserRole.cashier, returning.branch),
      branch: returning.branch,
      recordId: batchId,
      recordKind: LogRecordKind.purchaseBatch,
      summary: 'Returned the purchase from ${returning.customer.name} for correction: $note',
    );
    _queue('POST', 'purchases/$batchId/return', body: {'note': note}, summary: 'Return purchase · $batchId');
    _purchaseBatches[batchIdx] = _purchaseBatches[batchIdx].copyWith(
      verificationStatus: VerificationStatus.returnedForCorrection,
      verificationNote: note,
    );
    for (final line in itemsInBatch(batchId)) {
      final idx = _items.indexWhere((i) => i.id == line.id);
      if (idx == -1) continue;
      _items[idx] = _items[idx].copyWith(
        verificationStatus: VerificationStatus.returnedForCorrection,
        verificationNote: note,
      );
    }
    notifyListeners();
  }

  /// Carves a smaller item out of [parentId], drawing down both grams and
  /// amount from the parent atomically. Throws [ArgumentError] if the draw
  /// would exceed what remains on the lot — callers should pre-validate in
  /// the UI so this is a defensive backstop, not the primary error path.
  Item createPartition({
    required String parentId,
    required String description,
    required ItemType type,
    required double weightGrams,
    required int amountCentavos,
    Uint8List? photo,
    AppUser? actor,
  }) {
    final parentIdx = _items.indexWhere((i) => i.id == parentId);
    if (parentIdx == -1) {
      throw ArgumentError('Parent lot not found');
    }
    final parent = _items[parentIdx];

    if (type.isSilver != parent.type.isSilver) {
      throw ArgumentError('A partition is the same metal as its lot');
    }
    if (parent.verificationStatus != VerificationStatus.verified) {
      throw StateError('Only a verified lot can be partitioned — release its purchase first');
    }
    if (weightGrams <= 0 || amountCentavos <= 0) {
      throw ArgumentError('A partition must draw a positive weight and amount');
    }
    final remainingGrams = parent.effectiveRemainingGrams;
    final remainingAmount = parent.effectiveRemainingAmountCentavos;
    if (weightGrams > remainingGrams + 1e-9) {
      throw ArgumentError('Cannot draw more grams than remain on the lot');
    }
    if (amountCentavos > remainingAmount) {
      throw ArgumentError('Cannot draw more amount than remains on the lot');
    }

    final child = Item(
      id: _newId(),
      description: description,
      weightGrams: weightGrams,
      karat: parent.karat,
      type: type,
      capitalAmountCentavos: amountCentavos,
      origin: parent.origin,
      branch: parent.branch,
      itemStatus: _postVerificationStatus(type),
      verificationStatus: VerificationStatus.verified,
      purchaseDate: DateTime.now(),
      submittedByRole: parent.submittedByRole,
      encodedByUserId: _actorOr(actor, AppUserRole.assistantAppraiser, parent.branch).id,
      batchId: parent.batchId,
      parentLotId: parent.id,
      photo: photo,
    );

    final newRemainingGrams = remainingGrams - weightGrams;
    final newRemainingAmount = remainingAmount - amountCentavos;
    _items[parentIdx] = parent.copyWith(
      originalGrams: parent.effectiveOriginalGrams,
      originalAmountCentavos: parent.effectiveOriginalAmountCentavos,
      remainingGrams: newRemainingGrams < 0 ? 0 : newRemainingGrams,
      remainingAmountCentavos: newRemainingAmount < 0 ? 0 : newRemainingAmount,
    );

    _items.insert(0, child);
    _log(
      action: LogAction.partitionCreated,
      actor: _actorOr(actor, AppUserRole.assistantAppraiser, parent.branch),
      branch: parent.branch,
      recordId: child.id,
      recordKind: LogRecordKind.item,
      amountCentavos: amountCentavos,
      summary: 'Drew "$description" (${weightGrams.toStringAsFixed(3)}g, ${_peso(amountCentavos)}) '
          'out of lot ${parent.id}',
    );
    _queue(
      'POST',
      'items/$parentId/partitions',
      body: {
        'id': child.id,
        'description': child.description,
        'type': child.type.name,
        'grams': _grams(weightGrams),
        'amount_centavos': amountCentavos,
        'photo': SnapshotCodec.encodePhoto(photo),
      },
      summary: 'Partition ${child.id} from $parentId',
    );
    notifyListeners();
    return child;
  }

  /// Attaches or replaces the photo of a piece. Available to whoever is
  /// handling the item at the counter — the Appraiser encoding a purchase, or
  /// a Sales Rep photographing a piece as it goes out — so the Cashier
  /// verifying the record has something to check it against.
  void setItemPhoto(String itemId, Uint8List photo, {AppUser? actor}) {
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    final item = _items[idx];
    _items[idx] = item.copyWith(photo: photo);
    _log(
      action: LogAction.photoAttached,
      actor: _actorOr(actor, AppUserRole.salesRep, item.branch),
      branch: item.branch,
      recordId: item.id,
      recordKind: LogRecordKind.item,
      summary: '${item.hasPhoto ? 'Replaced' : 'Attached'} the photo of "${item.description}"',
    );
    _queue(
      'PUT',
      'items/$itemId/photo',
      body: {'photo': SnapshotCodec.encodePhoto(photo)},
      summary: 'Item photo · $itemId',
    );
    notifyListeners();
  }

  /// Whether an admin may still correct this item. Once it is sold, disposed
  /// of, or held in an open customer order, its figures are already written
  /// into another record — correct that record instead.
  bool canEditItem(Item item) => !const {
        ItemStatus.sold,
        ItemStatus.disposed,
        ItemStatus.reserved,
      }.contains(item.itemStatus);

  /// Admin correction to an item's recorded details.
  ///
  /// For a lot that has been partitioned, [weightGrams] and
  /// [capitalAmountCentavos] are the lot's *original* figures — what was
  /// actually bought. What has been drawn out stays drawn, so the change
  /// lands on the remainder, and is refused if it would leave the lot owing
  /// more than it holds.
  ///
  /// For a partition, a change in weight or amount is taken from — or handed
  /// back to — its parent lot, since the two share the same original grams.
  /// Its karat is its lot's and can only change there; changing a lot's
  /// karat carries down to every piece drawn out of it.
  ///
  /// Cash is never moved by an edit. If a purchase was already paid and its
  /// amount is corrected, the difference is reported in the log; if money
  /// actually changed hands to settle it, that is a cash entry of its own.
  ///
  /// Returns what changed, which is empty when nothing did.
  List<FieldChange> updateItem(
    String itemId, {
    String? description,
    int? karat,
    ItemType? type,
    double? weightGrams,
    double? grossWeightGrams,
    int? capitalAmountCentavos,
    AppUser? actor,
  }) {
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx == -1) throw ArgumentError('Item not found');
    final old = _items[idx];
    if (!canEditItem(old)) {
      throw StateError('A ${old.itemStatus.label.toLowerCase()} item can no longer be edited');
    }

    final newDescription = (description ?? old.description).trim();
    final newType = type ?? old.type;
    final newKarat = karat ?? old.karat;
    final oldWeight = old.hasPartitions ? old.effectiveOriginalGrams : old.weightGrams;
    final oldAmount = old.hasPartitions ? old.effectiveOriginalAmountCentavos : old.capitalAmountCentavos;
    final newWeight = weightGrams ?? oldWeight;
    final newAmount = capitalAmountCentavos ?? oldAmount;
    // With nothing deducted, gross and net are the same reading, so a
    // corrected net carries the gross with it; once there is a real
    // deduction, the gross stays as weighed unless it is corrected too.
    final nothingDeducted = old.grossWeightGrams != null &&
        (old.grossWeightGrams! - oldWeight).abs() < 1e-9;
    final newGross = grossWeightGrams ??
        (nothingDeducted ? newWeight : old.grossWeightGrams);

    if (newDescription.isEmpty) throw ArgumentError('An item needs a description');
    if (newWeight <= 0 || newAmount <= 0) {
      throw ArgumentError('Weight and amount must both be above zero');
    }
    if (newGross != null && newGross + 1e-9 < newWeight) {
      throw ArgumentError('The original weight cannot be less than the final weight');
    }
    if (old.isPartitioned && newKarat != old.karat) {
      throw ArgumentError('A partition takes its karat from its lot — change it on the lot');
    }
    _checkPurity(newType, newKarat);
    if (old.hasPartitions && newType.isSilver != old.type.isSilver) {
      throw ArgumentError('A lot with partitions cannot change metal — its pieces are already drawn');
    }
    if (newType != old.type && old.itemStatus == ItemStatus.sold) {
      throw StateError('A sold item cannot change type');
    }

    final dGrams = newWeight - oldWeight;
    final dAmount = newAmount - oldAmount;
    final changes = <FieldChange>[];
    final who = _actorOr(actor, AppUserRole.admin, null);

    // Status follows type once the piece is in stock: goods sit on the shelf,
    // scrap sits in the disposal pool.
    var status = old.itemStatus;
    if (newType != old.type && old.verificationStatus == VerificationStatus.verified) {
      status = _postVerificationStatus(newType);
    }

    // --- a partition draws its change from the parent -----------------------
    Item? parentBefore;
    Item? parentAfter;
    if (old.isPartitioned && (dGrams.abs() > 1e-9 || dAmount != 0)) {
      final parentIdx = _items.indexWhere((i) => i.id == old.parentLotId);
      if (parentIdx != -1) {
        parentBefore = _items[parentIdx];
        final remainingGrams = parentBefore.effectiveRemainingGrams - dGrams;
        final remainingAmount = parentBefore.effectiveRemainingAmountCentavos - dAmount;
        if (remainingGrams < -1e-9 || remainingAmount < 0) {
          throw ArgumentError(
            'Lot ${parentBefore.id} only has ${parentBefore.effectiveRemainingGrams.toStringAsFixed(3)}g '
            'and ${_peso(parentBefore.effectiveRemainingAmountCentavos)} left to give',
          );
        }
        parentAfter = parentBefore.copyWith(
          originalGrams: parentBefore.effectiveOriginalGrams,
          originalAmountCentavos: parentBefore.effectiveOriginalAmountCentavos,
          remainingGrams: remainingGrams < 0 ? 0 : remainingGrams,
          remainingAmountCentavos: remainingAmount,
        );
      }
    }

    // --- a partitioned lot keeps what has been drawn out --------------------
    Item updated;
    if (old.hasPartitions) {
      final remainingGrams = old.effectiveRemainingGrams + dGrams;
      final remainingAmount = old.effectiveRemainingAmountCentavos + dAmount;
      if (remainingGrams < -1e-9 || remainingAmount < 0) {
        throw ArgumentError(
          'More than that has already been drawn out of this lot into partitions',
        );
      }
      updated = old.copyWith(
        description: newDescription,
        karat: newKarat,
        type: newType,
        itemStatus: status,
        grossWeightGrams: newGross,
        // Shift every figure by the same correction, which keeps the lot
        // consistent whichever of them its record happens to lead with.
        weightGrams: old.weightGrams + dGrams,
        capitalAmountCentavos: old.capitalAmountCentavos + dAmount,
        originalGrams: newWeight,
        originalAmountCentavos: newAmount,
        remainingGrams: remainingGrams < 0 ? 0 : remainingGrams,
        remainingAmountCentavos: remainingAmount,
      );
    } else {
      updated = old.copyWith(
        description: newDescription,
        karat: newKarat,
        type: newType,
        itemStatus: status,
        grossWeightGrams: newGross,
        weightGrams: newWeight,
        capitalAmountCentavos: newAmount,
      );
    }

    changes.addAll(_diffItem(old, updated, weightBefore: oldWeight, weightAfter: newWeight,
        amountBefore: oldAmount, amountAfter: newAmount));
    if (changes.isEmpty) return const [];

    _items[idx] = updated;

    if (parentBefore != null && parentAfter != null) {
      final parentIdx = _items.indexWhere((i) => i.id == parentBefore!.id);
      _items[parentIdx] = parentAfter;
      changes.add(FieldChange(
        field: 'Lot ${parentBefore.id} remaining',
        before: '${parentBefore.effectiveRemainingGrams.toStringAsFixed(3)}g · '
            '${_peso(parentBefore.effectiveRemainingAmountCentavos)}',
        after: '${parentAfter.effectiveRemainingGrams.toStringAsFixed(3)}g · '
            '${_peso(parentAfter.effectiveRemainingAmountCentavos)}',
      ));
    }

    // A lot's karat is every piece's karat.
    if (old.hasPartitions && newKarat != old.karat) {
      for (var i = 0; i < _items.length; i++) {
        if (_items[i].parentLotId == old.id) {
          _items[i] = _items[i].copyWith(karat: newKarat);
        }
      }
      changes.add(FieldChange(
        field: 'Partitions',
        before: '${old.karat}K',
        after: '${newKarat}K (carried to every piece drawn from this lot)',
      ));
    }

    // Flag, never fabricate, a difference against cash already paid out.
    final batch = old.batchId == null ? null : findBatch(old.batchId!);
    final paid = !old.isPartitioned &&
        batch != null &&
        batch.verificationStatus == VerificationStatus.verified;
    final cashNote = (paid && dAmount != 0)
        ? ' Cash was already released for this purchase; the ${_peso(dAmount.abs())} '
            '${dAmount > 0 ? 'increase' : 'decrease'} was not moved in the ledger.'
        : '';

    _log(
      action: LogAction.itemEdited,
      actor: who,
      branch: old.branch,
      recordId: old.id,
      recordKind: LogRecordKind.item,
      amountCentavos: dAmount == 0 ? null : newAmount,
      summary: 'Corrected "${updated.description}".$cashNote',
      changes: changes,
    );
    _queue(
      'PATCH',
      'items/$itemId',
      body: {
        'description': updated.description,
        'type': updated.type.name,
        'karat': updated.karat,
        'weight_grams': _grams(newWeight),
        'gross_weight_grams': newGross == null ? null : _grams(newGross),
        'amount_centavos': newAmount,
      },
      summary: 'Correct item · $itemId',
    );
    notifyListeners();
    return changes;
  }

  /// Field-by-field differences between two versions of an item, in the
  /// words the edit form uses.
  List<FieldChange> _diffItem(
    Item before,
    Item after, {
    double? weightBefore,
    double? weightAfter,
    int? amountBefore,
    int? amountAfter,
  }) {
    final wB = weightBefore ?? before.weightGrams;
    final wA = weightAfter ?? after.weightGrams;
    final aB = amountBefore ?? before.capitalAmountCentavos;
    final aA = amountAfter ?? after.capitalAmountCentavos;
    return [
      if (before.description != after.description)
        FieldChange(field: 'Description', before: before.description, after: after.description),
      if (before.type != after.type)
        FieldChange(field: 'Type', before: before.type.label, after: after.type.label),
      if (before.karat != after.karat)
        FieldChange(field: 'Karat', before: _karatText(before.karat), after: _karatText(after.karat)),
      if ((wB - wA).abs() > 1e-9)
        FieldChange(
          field: before.hasPartitions ? 'Original final weight' : 'Final weight',
          before: '${wB.toStringAsFixed(3)}g',
          after: '${wA.toStringAsFixed(3)}g',
        ),
      if (((before.grossWeightGrams ?? -1) - (after.grossWeightGrams ?? -1)).abs() > 1e-9)
        FieldChange(
          field: 'Original weight',
          before: before.grossWeightGrams == null ? '—' : '${before.grossWeightGrams!.toStringAsFixed(3)}g',
          after: after.grossWeightGrams == null ? '—' : '${after.grossWeightGrams!.toStringAsFixed(3)}g',
        ),
      if (aB != aA)
        FieldChange(
          field: before.hasPartitions ? 'Original amount' : 'Amount',
          before: _peso(aB),
          after: _peso(aA),
        ),
    ];
  }

  /// Peso text for log lines, without reaching into the widget layer.
  static String _peso(int centavos) => pesoText(centavos);

  /// Admin action: removes a partition and returns its grams and amount to
  /// the lot it was drawn from — the exact inverse of [createPartition], and
  /// like it, this moves no cash: the lot was paid for once, at release, and
  /// redrawing its internal split doesn't change what left the till.
  ///
  /// Throws [ArgumentError] if [partitionId] isn't a partition, or
  /// [StateError] if it has already been sold, reserved into an order, or
  /// disposed — see [Item.canReturnToParent].
  void deletePartition(String partitionId, {AppUser? actor}) {
    final idx = _items.indexWhere((i) => i.id == partitionId);
    if (idx == -1) return;
    final child = _items[idx];
    final parentId = child.parentLotId;
    if (parentId == null) {
      throw ArgumentError('Only a partition can be returned to a parent lot');
    }
    if (!child.canReturnToParent) {
      throw StateError(
        'A ${child.itemStatus.label.toLowerCase()} partition can no longer be returned to its lot',
      );
    }

    final parentIdx = _items.indexWhere((i) => i.id == parentId);
    if (parentIdx != -1) {
      final parent = _items[parentIdx];
      final restoredGrams = parent.effectiveRemainingGrams + child.weightGrams;
      final restoredAmount =
          parent.effectiveRemainingAmountCentavos + child.capitalAmountCentavos;
      final siblingsLeft = _items.any((i) => i.parentLotId == parentId && i.id != partitionId);

      // With the last partition gone the lot could read as never-partitioned
      // again — but only when its own weight and amount already say the same
      // thing as the restored figures. A lot recorded with its post-partition
      // remainder (seed data does exactly that) keeps the original/remaining
      // fields as the sole record of the full lot, and dropping them would
      // quietly lose the grams and pesos just handed back.
      final ownFiguresMatch = (restoredGrams - parent.weightGrams).abs() < 1e-9 &&
          restoredAmount == parent.capitalAmountCentavos;

      if (siblingsLeft || !ownFiguresMatch) {
        _items[parentIdx] = parent.copyWith(
          remainingGrams: restoredGrams,
          remainingAmountCentavos: restoredAmount,
        );
      } else {
        // copyWith can't null a field, so this rebuilds the item without the
        // partition bookkeeping.
        _items[parentIdx] = Item(
          id: parent.id,
          description: parent.description,
          weightGrams: parent.weightGrams,
          karat: parent.karat,
          type: parent.type,
          capitalAmountCentavos: parent.capitalAmountCentavos,
          origin: parent.origin,
          branch: parent.branch,
          itemStatus: parent.itemStatus,
          verificationStatus: parent.verificationStatus,
          purchaseDate: parent.purchaseDate,
          submittedByRole: parent.submittedByRole,
          verificationNote: parent.verificationNote,
          parentLotId: parent.parentLotId,
        );
      }
    }

    _log(
      action: LogAction.partitionReturned,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: child.branch,
      recordId: parentId,
      recordKind: LogRecordKind.item,
      amountCentavos: child.capitalAmountCentavos,
      summary: 'Returned partition ${child.id} "${child.description}" '
          '(${child.weightGrams.toStringAsFixed(3)}g, ${_peso(child.capitalAmountCentavos)}) to lot $parentId',
    );
    _queue('DELETE', 'partitions/$partitionId', summary: 'Delete partition · $partitionId');
    _items.removeAt(idx);
    notifyListeners();
  }

  /// Stock available to sell: verified, listed, and — critically — not
  /// scrap. Gold goods and silver both sell over the counter; scrap never
  /// appears in the Sell tab, it only ever leaves through a disposal batch.
  List<Item> sellableGoods({BranchId? branchId, bool? silver}) {
    return itemsForBranch(branchId)
        .where((i) =>
            i.type != ItemType.scrap &&
            (silver == null || i.type.isSilver == silver) &&
            i.itemStatus == ItemStatus.listed &&
            i.verificationStatus == VerificationStatus.verified)
        .toList();
  }

  /// Holds an item for an in-progress cart so it can't be added to a second
  /// order at the same time. Called by [CartState], not directly by UI.
  void reserveItem(String itemId) {
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    _items[idx] = _items[idx].copyWith(itemStatus: ItemStatus.reserved);
    _queue('POST', 'items/$itemId/reserve', summary: 'Hold item · $itemId');
    notifyListeners();
  }

  /// Releases a cart-held item back into sellable inventory. Called by
  /// [CartState] when a line is removed or the cart is cancelled.
  void releaseReservation(String itemId) {
    final idx = _items.indexWhere((i) => i.id == itemId);
    if (idx == -1) return;
    _items[idx] = _items[idx].copyWith(itemStatus: ItemStatus.listed);
    _queue('POST', 'items/$itemId/release-reservation', summary: 'Release hold · $itemId');
    notifyListeners();
  }

  // --- Sales -----------------------------------------------------------
  List<Sale> get sales => List.unmodifiable(_sales);

  List<Sale> salesForBranch(BranchId? branchId) {
    if (branchId == null) return List.of(_sales);
    return _sales.where((s) => s.branch == branchId).toList();
  }

  List<Sale> salesAwaitingPayment({BranchId? branchId}) {
    return salesForBranch(branchId)
        .where((s) => s.verificationStatus == VerificationStatus.awaitingVerification)
        .toList();
  }

  List<Sale> salesAwaitingVerificationFor(AppUserRole role, {BranchId? branchId}) {
    return salesForBranch(branchId)
        .where((s) =>
            s.submittedByRole == role &&
            s.verificationStatus == VerificationStatus.awaitingVerification)
        .toList();
  }

  /// Sales a Cashier sent back to this [role] — surfaced on the Sell tab so
  /// the rep knows to fix and resubmit them.
  List<Sale> salesReturnedForCorrectionFor(AppUserRole role, {BranchId? branchId}) {
    return salesForBranch(branchId)
        .where((s) =>
            s.submittedByRole == role &&
            s.verificationStatus == VerificationStatus.returnedForCorrection)
        .toList();
  }

  Sale? findSale(String id) {
    for (final s in _sales) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Hands a completed order to the Cashier's queue. Items in [lineItems]
  /// are expected to already be `reserved` (via [CartState]) — cash/bank
  /// balances are untouched until [completeSale].
  Sale checkoutSale({
    required List<SaleLineItem> lineItems,
    required CustomerDetails customer,
    String? note,
    required SalePayment payment,
    required BranchId branch,
    required AppUserRole submittedByRole,
    AppUser? actor,
  }) {
    final who = _actorOr(actor, submittedByRole, branch);
    final saved = upsertCustomer(customer);
    final sale = Sale(
      id: _newId(),
      lineItems: lineItems,
      customer: customer.withId(saved.id),
      note: note,
      payment: payment,
      verificationStatus: VerificationStatus.awaitingVerification,
      branch: branch,
      date: DateTime.now(),
      submittedByRole: submittedByRole,
      submittedByUserId: who.id,
    );
    _sales.insert(0, sale);
    _log(
      action: LogAction.saleSubmitted,
      actor: who,
      branch: branch,
      recordId: sale.id,
      recordKind: LogRecordKind.sale,
      amountCentavos: sale.totalAmountCentavos,
      summary: 'Sent an order of ${lineItems.length} item(s) for ${customer.name} '
          '(${_peso(sale.totalAmountCentavos)}) to the Cashier',
    );
    _queue(
      'POST',
      'sales',
      body: {
        'id': sale.id,
        'branch': branch.name,
        'customer': _customerBody(sale.customer),
        'note': note,
        'lines': [
          for (final line in lineItems)
            {
              'item_id': line.item.id,
              'negotiated_price_centavos': line.negotiatedPriceCentavos,
              'final_grams': _grams(line.effectiveFinalGrams),
            },
        ],
        'payment': {
          'cash_centavos': payment.cashCentavos,
          'bank_centavos': payment.bankCentavos,
        },
      },
      summary: 'Sale ${sale.id} · ${sale.customerName}',
    );
    notifyListeners();
    return sale;
  }

  /// Re-submits a `returnedForCorrection` sale with a fixed set of line
  /// items and puts it back in the Cashier's queue.
  void resubmitSale(
    String saleId, {
    required List<SaleLineItem> lineItems,
    required CustomerDetails customer,
    String? note,
    required SalePayment payment,
    AppUser? actor,
  }) {
    final idx = _sales.indexWhere((s) => s.id == saleId);
    if (idx == -1) return;
    final saved = upsertCustomer(customer);
    final resubmitting = _sales[idx];
    _sales[idx] = _sales[idx].copyWith(
      lineItems: lineItems,
      customer: customer.withId(saved.id),
      note: note,
      payment: payment,
      verificationStatus: VerificationStatus.awaitingVerification,
      clearVerificationNote: true,
    );
    _log(
      action: LogAction.saleResubmitted,
      actor: _actorOr(actor, resubmitting.submittedByRole, resubmitting.branch),
      branch: resubmitting.branch,
      recordId: saleId,
      recordKind: LogRecordKind.sale,
      amountCentavos: _sales[idx].totalAmountCentavos,
      summary: 'Corrected the order for ${customer.name} and sent it back to the Cashier',
    );
    _queue(
      'POST',
      'sales/$saleId/resubmit',
      body: {
        'customer': _customerBody(customer),
        'note': note,
        'lines': [
          for (final line in lineItems)
            {
              'item_id': line.item.id,
              'negotiated_price_centavos': line.negotiatedPriceCentavos,
              'final_grams': _grams(line.effectiveFinalGrams),
            },
        ],
        'payment': {'cash_centavos': payment.cashCentavos, 'bank_centavos': payment.bankCentavos},
      },
      summary: 'Resubmit order · $saleId',
    );
    notifyListeners();
  }

  /// Cashier action: confirms the pieces being handed over match the order,
  /// receives payment, marks every line item `sold`, and credits each half of
  /// [payment] where it actually landed — the cash portion as a linked ledger
  /// entry, the transferred portion straight to the bank balance, which the
  /// cash ledger deliberately does not track.
  void completeSale(
    String saleId, {
    required SalePayment payment,
    AppUserRole recordedByRole = AppUserRole.cashier,
    String? cashEntryId,
    String? bankEntryId,
    AppUser? actor,
  }) {
    final idx = _sales.indexWhere((s) => s.id == saleId);
    if (idx == -1) return;
    final sale = _sales[idx];
    if (sale.verificationStatus == VerificationStatus.verified) {
      throw StateError('Payment for this order was already received');
    }
    if (payment.cashCentavos < 0 || payment.bankCentavos < 0) {
      throw ArgumentError('A payment cannot be negative');
    }
    if (payment.totalCentavos != sale.totalAmountCentavos) {
      throw ArgumentError(
        'Payment of ${_peso(payment.totalCentavos)} does not match the order total '
        'of ${_peso(sale.totalAmountCentavos)}',
      );
    }
    // Named up front so the phone's ledger rows and the server's share ids.
    final saleCashEntryId = cashEntryId ?? _newId();
    final saleBankEntryId = bankEntryId ?? _newId();
    final who = _actorOr(actor, recordedByRole, sale.branch);
    _sales[idx] = sale.copyWith(
      verificationStatus: VerificationStatus.verified,
      payment: payment,
      receivedByUserId: who.id,
    );

    for (final line in sale.lineItems) {
      final itemIdx = _items.indexWhere((i) => i.id == line.item.id);
      if (itemIdx != -1) {
        _items[itemIdx] = _items[itemIdx].copyWith(itemStatus: ItemStatus.sold);
      }
    }

    // Each half of the payment lands where it physically went: the cash
    // portion in Sales Cash, the transferred portion in the bank. A split
    // sale touches both. Neither goes into the purchase float.
    if (payment.cashCentavos > 0) {
      _writeCashEntry(
        branch: sale.branch,
        type: CashEntryType.cashIn,
        account: CashAccount.sales,
        id: saleCashEntryId,
        amountCentavos: payment.cashCentavos,
        note: 'Payment received - ${sale.customerName}'
            '${payment.isSplit ? ' (cash portion)' : ''}',
        date: DateTime.now(),
        recordedByRole: recordedByRole,
        recordedByUserId: who.id,
        sourceType: CashEntrySourceType.sale,
        linkedRecordId: sale.id,
      );
    }
    if (payment.bankCentavos > 0) {
      _writeCashEntry(
        branch: sale.branch,
        type: CashEntryType.cashIn,
        account: CashAccount.bank,
        id: saleBankEntryId,
        amountCentavos: payment.bankCentavos,
        note: 'Bank payment received - ${sale.customerName}'
            '${payment.isSplit ? ' (bank portion)' : ''}',
        date: DateTime.now(),
        recordedByRole: recordedByRole,
        recordedByUserId: who.id,
        sourceType: CashEntrySourceType.sale,
        linkedRecordId: sale.id,
      );
    }
    _log(
      action: LogAction.paymentReceived,
      actor: who,
      branch: sale.branch,
      recordId: sale.id,
      recordKind: LogRecordKind.sale,
      amountCentavos: payment.totalCentavos,
      summary: 'Received ${_peso(payment.totalCentavos)} from ${sale.customerName}'
          '${payment.isSplit ? ' (${_peso(payment.cashCentavos)} cash, ${_peso(payment.bankCentavos)} bank)' : ' by ${payment.label.toLowerCase()}'}',
    );
    _queue(
      'POST',
      'sales/$saleId/complete',
      body: {
        'cash_centavos': payment.cashCentavos,
        'bank_centavos': payment.bankCentavos,
        'cash_entry_id': saleCashEntryId,
        'bank_entry_id': saleBankEntryId,
      },
      summary: 'Payment received · $saleId',
    );
    notifyListeners();
  }

  /// Cashier action: sends the order back to the rep with a note instead of
  /// receiving payment. Line items stay `reserved` — still held for this
  /// order — until the rep fixes and resubmits it.
  void returnSaleForCorrection(String saleId, String note, {AppUser? actor}) {
    final idx = _sales.indexWhere((s) => s.id == saleId);
    if (idx == -1) return;
    final returning = _sales[idx];
    _log(
      action: LogAction.saleReturned,
      actor: _actorOr(actor, AppUserRole.cashier, returning.branch),
      branch: returning.branch,
      recordId: saleId,
      recordKind: LogRecordKind.sale,
      summary: 'Returned the order for ${returning.customerName} to the rep: $note',
    );
    _sales[idx] = _sales[idx].copyWith(
      verificationStatus: VerificationStatus.returnedForCorrection,
      verificationNote: note,
    );
    _queue('POST', 'sales/$saleId/return', body: {'note': note}, summary: 'Return order · $saleId');
    notifyListeners();
  }

  // --- Commitments -------------------------------------------------------
  List<Commitment> get commitments => List.unmodifiable(_commitments);

  /// Branch-specific commitments for [branchId], plus every company-wide
  /// one (`branch == null`) — those apply everywhere, the same way a
  /// company-wide obligation would show up regardless of which branch
  /// you're standing in. Viewing the combined ("all branches") mode
  /// returns everything.
  List<Commitment> commitmentsForBranch(BranchId? branchId) {
    if (branchId == null) return List.of(_commitments);
    return _commitments.where((c) => c.branch == null || c.branch == branchId).toList();
  }

  Commitment? findCommitment(String id) {
    for (final c in _commitments) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// Builds the computed ledger for one commitment: every disposal batch
  /// applied against it, and the balance/status/progress derived from
  /// them. This is the single place that formula lives.
  CommitmentLedger ledgerFor(String commitmentId) {
    final commitment = findCommitment(commitmentId);
    if (commitment == null) {
      throw ArgumentError('Commitment not found: $commitmentId');
    }
    final applied = _disposalBatches.where((d) => d.commitmentRef == commitmentId).toList()
      ..sort((a, b) => a.date.compareTo(b.date));
    return CommitmentLedger(commitment: commitment, appliedBatches: applied);
  }

  List<CommitmentLedger> commitmentLedgers({BranchId? branchId}) {
    return commitmentsForBranch(branchId).map((c) => ledgerFor(c.id)).toList();
  }

  /// Adds a new commitment — always starts `loanPending`; there's no
  /// status field to set because it's derived (see [CommitmentLedger]).
  Commitment addCommitment({
    required String lender,
    required int amountCentavos,
    required int ratePerGramCentavos,
    required DateTime dateApproved,
    required BranchId? branch,
    AppUser? actor,
  }) {
    final commitment = Commitment(
      id: _newId(),
      lender: lender,
      amountCentavos: amountCentavos,
      ratePerGramCentavos: ratePerGramCentavos,
      branch: branch,
      dateApproved: dateApproved,
    );
    _commitments.insert(0, commitment);
    _log(
      action: LogAction.commitmentAdded,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: branch,
      recordId: commitment.id,
      recordKind: LogRecordKind.commitment,
      amountCentavos: amountCentavos,
      summary: 'Added a ${_peso(amountCentavos)} commitment with $lender',
    );
    _queue(
      'POST',
      'commitments',
      body: {
        'id': commitment.id,
        'lender': lender,
        'amount_centavos': amountCentavos,
        'rate_per_gram_centavos': ratePerGramCentavos,
        'branch': branch?.name,
        'date_approved': dateApproved.toIso8601String(),
      },
      summary: 'Loan · $lender',
      at: dateApproved,
    );
    notifyListeners();
    return commitment;
  }

  /// Advances a commitment from `loanPending` to `loanReceived`: records
  /// when cash came in and writes a linked cash-in entry to the branch's
  /// ledger. Company-wide commitments have no single branch ledger to
  /// credit in this prototype, so only the receipt date is recorded for
  /// those.
  void receiveCommitmentCash(
    String commitmentId, {
    AppUserRole recordedByRole = AppUserRole.admin,
    Uint8List? proofPhoto,
    String? cashEntryId,
    AppUser? actor,
  }) {
    final loanCashEntryId = cashEntryId ?? _newId();
    final idx = _commitments.indexWhere((c) => c.id == commitmentId);
    if (idx == -1) return;
    final commitment = _commitments[idx];
    if (commitment.dateReceived != null) return;
    if (proofPhoto == null) {
      throw ArgumentError("A photo of the cash received (or the lender's slip) is required");
    }

    _commitments[idx] = commitment.copyWith(dateReceived: DateTime.now(), receivedProofPhoto: proofPhoto);
    final who = _actorOr(actor, recordedByRole, commitment.branch);

    if (commitment.branch != null) {
      _writeCashEntry(
        branch: commitment.branch!,
        type: CashEntryType.cashIn,
        id: loanCashEntryId,
        amountCentavos: commitment.amountCentavos,
        note: 'Loan proceeds received — ${commitment.lender}',
        date: DateTime.now(),
        recordedByRole: recordedByRole,
        recordedByUserId: who.id,
        sourceType: CashEntrySourceType.commitment,
        linkedRecordId: commitment.id,
      );
    }
    _log(
      action: LogAction.commitmentReceived,
      actor: who,
      branch: commitment.branch,
      recordId: commitment.id,
      recordKind: LogRecordKind.commitment,
      amountCentavos: commitment.amountCentavos,
      summary: 'Recorded ${_peso(commitment.amountCentavos)} received from ${commitment.lender}',
    );
    _queue(
      'POST',
      'commitments/$commitmentId/receive',
      body: {
        'proof_photo': SnapshotCodec.encodePhoto(proofPhoto),
        'cash_entry_id': loanCashEntryId,
      },
      summary: 'Loan cash received · ${commitment.lender}',
    );
    notifyListeners();
  }

  // --- Disposal history ----------------------------------------------------
  List<DisposalBatch> get disposalBatches => List.unmodifiable(_disposalBatches);

  List<DisposalBatch> disposalBatchesForBranch(BranchId? branchId) {
    if (branchId == null) return List.of(_disposalBatches);
    return _disposalBatches.where((d) => d.branch == branchId).toList();
  }

  /// The individual pieces a disposal batch contained, in the order they were
  /// selected. Items are never deleted, so a disposed batch can always be
  /// broken back down into what actually went to the refiner.
  List<Item> itemsInDisposal(String batchId) {
    final batch = findDisposalBatch(batchId);
    if (batch == null) return const [];
    return [
      for (final id in batch.itemIds)
        if (findItem(id) != null) findItem(id)!,
    ];
  }

  /// What a disposal batch actually contained, graded by karat: total grams
  /// per karat, highest karat first.
  ///
  /// Gold is bought, melted, and settled by karat, so "93g" alone doesn't say
  /// what was handed over — 93g of 21K and 93g of 10K are different
  /// deliveries. Derived from the items each time rather than stored, so it
  /// can never disagree with the batch it describes.
  List<MapEntry<int, double>> karatBreakdown(String batchId) {
    final batch = findDisposalBatch(batchId);
    if (batch == null) return const [];

    final grams = <int, double>{};
    for (final id in batch.itemIds) {
      final item = findItem(id);
      if (item == null) continue;
      // Disposal takes the whole remaining lot, which is what was weighed in.
      grams[item.karat] = (grams[item.karat] ?? 0) + item.effectiveRemainingGrams;
    }

    final entries = grams.entries.toList()
      ..sort((a, b) => b.key.compareTo(a.key));
    return entries;
  }

  DisposalBatch? findDisposalBatch(String id) {
    for (final b in _disposalBatches) {
      if (b.id == id) return b;
    }
    return null;
  }

  /// Records a bulk scrap disposal batch. [grossGrams] and
  /// [grossAmountCentavos] are always entered by hand at settlement — never
  /// computed from a gold rate. When [commitmentRef] is set, the batch's
  /// gross amount immediately counts toward that commitment's balance
  /// (see [ledgerFor]) since the balance is derived, not stored.
  DisposalBatch recordDisposalBatch({
    required BranchId branch,
    required List<String> itemIds,
    required int capitalCentavos,
    required double grossGrams,
    required int grossAmountCentavos,
    required DateTime date,
    required String commitmentRef,
    Uint8List? photo,
  }) {
    // A disposal only exists to pay down a loan, so there has to be a loan
    // with cash in hand and something still owing on it.
    final ledger = ledgerFor(commitmentRef);
    if (ledger.status != CommitmentStatus.loanReceived) {
      throw StateError(
        'Only a received loan with a balance left to pay can take a disposal batch',
      );
    }
    final batch = DisposalBatch(
      id: _newId(),
      branch: branch,
      itemIds: itemIds,
      capitalCentavos: capitalCentavos,
      grossGrams: grossGrams,
      grossAmountCentavos: grossAmountCentavos,
      date: date,
      commitmentRef: commitmentRef,
      photo: photo,
    );
    _disposalBatches.insert(0, batch);
    notifyListeners();
    return batch;
  }

  /// The full Scrap-tab disposal action: records the batch (see
  /// [recordDisposalBatch]) and marks every selected item `disposed` in
  /// one step. If [commitmentRef] is set, that commitment's balance and
  /// status (including the automatic flip to `loanPaid`) update on the
  /// very next read — there's nothing else to apply, since [ledgerFor]
  /// derives them from disposal batches rather than a stored total.
  ///
  /// This does NOT touch any branch cash/bank balance — disposal proceeds
  /// pay down a commitment, they aren't cash received into the till.
  DisposalBatch completeDisposal({
    required BranchId branch,
    required List<String> itemIds,
    required int capitalCentavos,
    required double grossGrams,
    required int grossAmountCentavos,
    required DateTime date,
    required String commitmentRef,
    Uint8List? photo,
    AppUser? actor,
  }) {
    final batch = recordDisposalBatch(
      branch: branch,
      itemIds: itemIds,
      capitalCentavos: capitalCentavos,
      grossGrams: grossGrams,
      grossAmountCentavos: grossAmountCentavos,
      date: date,
      commitmentRef: commitmentRef,
      photo: photo,
    );

    for (final id in itemIds) {
      final idx = _items.indexWhere((i) => i.id == id);
      if (idx != -1) {
        _items[idx] = _items[idx].copyWith(itemStatus: ItemStatus.disposed);
      }
    }
    final lender = findCommitment(commitmentRef)?.lender ?? commitmentRef;
    _log(
      action: LogAction.disposalCompleted,
      actor: _actorOr(actor, AppUserRole.admin, null),
      branch: branch,
      recordId: batch.id,
      recordKind: LogRecordKind.disposal,
      amountCentavos: grossAmountCentavos,
      summary: 'Disposed ${itemIds.length} item(s), ${grossGrams.toStringAsFixed(3)}g, '
          'for ${_peso(grossAmountCentavos)} applied to $lender',
    );
    _queue(
      'POST',
      'disposal',
      body: {
        'id': batch.id,
        'branch': branch.name,
        'item_ids': itemIds,
        'capital_centavos': capitalCentavos,
        'gross_grams': _grams(grossGrams),
        'gross_amount_centavos': grossAmountCentavos,
        'commitment_id': commitmentRef,
        'date': date.toIso8601String(),
        'photo': SnapshotCodec.encodePhoto(photo),
      },
      summary: 'Disposal ${batch.id} · ${itemIds.length} item(s)',
      at: date,
    );
    notifyListeners();
    return batch;
  }

  // --- Today's activity ------------------------------------------------
  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  List<Item> purchasesToday({BranchId? branchId}) {
    return itemsForBranch(branchId).where((i) => _isToday(i.purchaseDate)).toList();
  }

  List<Sale> salesToday({BranchId? branchId}) {
    return salesForBranch(branchId).where((s) => _isToday(s.date)).toList();
  }

  int todaysNetCentavos({BranchId? branchId}) {
    final purchasesTotal = purchasesToday(branchId: branchId)
        .fold<int>(0, (sum, i) => sum + i.capitalAmountCentavos);
    final salesTotal = salesToday(branchId: branchId)
        .fold<int>(0, (sum, s) => sum + s.totalAmountCentavos);
    return salesTotal - purchasesTotal;
  }
}
