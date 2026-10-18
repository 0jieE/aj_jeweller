import 'package:flutter/foundation.dart';

import '../data/app_repository.dart';
import '../models/app_user.dart';
import '../models/branch.dart';
import '../models/customer.dart';
import '../models/purchase_batch.dart';

/// The purchase being built at the counter: who is selling, and every piece
/// they have handed over so far.
///
/// The purchase-side counterpart to [CartState]. It differs in one important
/// way: nothing here touches the repository until the whole batch is
/// submitted. A sale reserves inventory as lines are added because the items
/// already exist and two reps could grab the same piece; a purchase is
/// creating records that don't exist yet, so a half-entered batch should
/// leave no trace if the customer changes their mind.
class PurchaseBasketState extends ChangeNotifier {
  final AppRepository _repo;

  PurchaseBasketState(this._repo);

  final List<PurchaseDraftLine> _lines = [];

  CustomerDetails _customer = const CustomerDetails(name: '');
  BranchId? _branch;
  DateTime _date = DateTime.now();

  List<PurchaseDraftLine> get lines => List.unmodifiable(_lines);
  bool get isEmpty => _lines.isEmpty;
  int get lineCount => _lines.length;

  CustomerDetails get customer => _customer;
  String get customerName => _customer.name;
  BranchId? get branch => _branch;
  DateTime get date => _date;

  /// Total the customer is owed for everything staged so far.
  int get totalCentavos =>
      _lines.fold<int>(0, (sum, l) => sum + l.capitalAmountCentavos);

  double get totalNetGrams => _lines.fold<double>(0, (sum, l) => sum + l.weightGrams);

  /// A name is the one detail a purchase can't be recorded without — there is
  /// no counterparty on the receipt otherwise.
  bool get canSubmit =>
      _lines.isNotEmpty && _customer.name.trim().isNotEmpty && _branch != null;

  void setCustomer(CustomerDetails value) {
    _customer = value;
    notifyListeners();
  }

  void setBranch(BranchId? value) {
    _branch = value;
    notifyListeners();
  }

  void setDate(DateTime value) {
    _date = value;
    notifyListeners();
  }

  void addLine(PurchaseDraftLine line) {
    _lines.add(line);
    notifyListeners();
  }

  void replaceLine(int index, PurchaseDraftLine line) {
    if (index < 0 || index >= _lines.length) return;
    _lines[index] = line;
    notifyListeners();
  }

  void removeLine(int index) {
    if (index < 0 || index >= _lines.length) return;
    _lines.removeAt(index);
    notifyListeners();
  }

  /// Writes the whole basket as one purchase and empties it.
  PurchaseBatch submit({required AppUser actor}) {
    if (!canSubmit) {
      throw StateError('A purchase needs a customer name, a branch, and at least one item');
    }
    final batch = _repo.recordPurchaseBatch(
      customer: CustomerDetails(
        name: _customer.name.trim(),
        contactNumber: _customer.contactNumber,
        address: _customer.address,
        customerId: _customer.customerId,
        photo: _customer.photo,
      ),
      lines: List.of(_lines),
      branch: _branch!,
      purchaseDate: _date,
      submittedByRole: actor.role,
      actor: actor,
    );
    clear();
    return batch;
  }

  void clear() {
    _lines.clear();
    _customer = const CustomerDetails(name: '');
    _date = DateTime.now();
    notifyListeners();
  }
}
