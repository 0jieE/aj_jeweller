import 'package:flutter/foundation.dart';

import '../data/app_repository.dart';
import '../models/branch.dart';
import '../models/item.dart';
import '../models/sale.dart';

/// One line in the working order — an item plus the price actually
/// negotiated with the customer for it.
class CartLine {
  final Item item;
  final int priceCentavos;

  /// The weight the piece is actually being sold at — re-weighed at the
  /// counter, since repair and polishing lose grams after purchase. Null
  /// means it was not re-weighed and the recorded weight stands.
  final double? finalGrams;

  const CartLine({required this.item, required this.priceCentavos, this.finalGrams});

  double get effectiveFinalGrams => finalGrams ?? item.weightGrams;

  /// Derived from the weight the deal was struck at, never stored, so it
  /// cannot drift from the price the customer pays.
  int get pricePerGramCentavos {
    final grams = effectiveFinalGrams;
    if (grams <= 0) return 0;
    return (priceCentavos / grams).round();
  }

  CartLine copyWith({int? priceCentavos, double? finalGrams}) => CartLine(
        item: item,
        priceCentavos: priceCentavos ?? this.priceCentavos,
        finalGrams: finalGrams ?? this.finalGrams,
      );
}

/// The Sales Rep's working order — held here, at app level, specifically so
/// it survives leaving the Sell tab and coming back. A cart that resets on
/// widget rebuild is useless at a counter mid-conversation with a customer.
///
/// Adding a line reserves the item in the repository (`listed` ->
/// `reserved`) so it can't be double-sold from another browse session;
/// removing a line or cancelling the cart releases it back. Checking out
/// does NOT release the reservation — the item stays held until the
/// Cashier either completes or returns the sale.
class CartState extends ChangeNotifier {
  final AppRepository _repo;

  CartState(this._repo);

  final List<CartLine> _lines = [];
  String _customerName = '';
  String _note = '';

  /// Non-null while fixing a Cashier-returned sale — checkout will update
  /// that sale in place instead of creating a new one.
  String? editingSaleId;
  String? editingSaleNote;

  List<CartLine> get lines => List.unmodifiable(_lines);
  String get customerName => _customerName;
  String get note => _note;
  bool get isEmpty => _lines.isEmpty;
  int get itemCount => _lines.length;
  int get totalCentavos => _lines.fold(0, (sum, l) => sum + l.priceCentavos);

  /// All lines in an active cart must belong to one branch — a sale can't
  /// span two physical locations. Null when the cart is empty.
  BranchId? get branch => _lines.isEmpty ? null : _lines.first.item.branch;

  bool canAdd(Item item) => branch == null || branch == item.branch;

  bool contains(String itemId) => _lines.any((l) => l.item.id == itemId);

  /// Throws [StateError] if [item] belongs to a different branch than what's
  /// already in the cart — callers should check [canAdd] first to show a
  /// proper in-context message instead of relying on this.
  void addLine(Item item, int priceCentavos, {double? finalGrams}) {
    if (!canAdd(item)) {
      throw StateError('Cart already has items from ${branch!.label}');
    }
    _repo.reserveItem(item.id);
    _lines.add(CartLine(item: item, priceCentavos: priceCentavos, finalGrams: finalGrams));
    notifyListeners();
  }

  void removeLine(String itemId) {
    final idx = _lines.indexWhere((l) => l.item.id == itemId);
    if (idx == -1) return;
    _repo.releaseReservation(_lines[idx].item.id);
    _lines.removeAt(idx);
    notifyListeners();
  }

  void updatePrice(String itemId, int newPriceCentavos) {
    final idx = _lines.indexWhere((l) => l.item.id == itemId);
    if (idx == -1) return;
    _lines[idx] = _lines[idx].copyWith(priceCentavos: newPriceCentavos);
    notifyListeners();
  }

  void setCustomerName(String value) {
    if (value == _customerName) return;
    _customerName = value;
    notifyListeners();
  }

  void setNote(String value) {
    if (value == _note) return;
    _note = value;
    notifyListeners();
  }

  /// Loads a Cashier-returned sale back into the cart for editing. The
  /// sale's items are already `reserved` (untouched by the return), so this
  /// does not re-reserve anything.
  void startEditingSale(Sale sale) {
    _lines
      ..clear()
      ..addAll([
        for (final line in sale.lineItems) CartLine(item: line.item, priceCentavos: line.negotiatedPriceCentavos),
      ]);
    _customerName = sale.customerName;
    _note = sale.note ?? '';
    editingSaleId = sale.id;
    editingSaleNote = sale.verificationNote;
    notifyListeners();
  }

  /// Abandons the cart entirely, releasing every held item back to
  /// `listed`. Use for an explicit "clear order" action.
  void cancelCart() {
    for (final line in _lines) {
      _repo.releaseReservation(line.item.id);
    }
    _reset();
  }

  /// Called after a successful checkout — the items stay reserved (now
  /// legitimately tied to the created/updated sale), only the working cart
  /// state is wiped.
  void clearAfterCheckout() => _reset();

  /// Wipes the cart without touching the repository — used only when the
  /// repository itself has just been reset (demo data reset), so the old
  /// item references in the cart are already stale.
  void hardReset() => _reset();

  void _reset() {
    _lines.clear();
    _customerName = '';
    _note = '';
    editingSaleId = null;
    editingSaleNote = null;
    notifyListeners();
  }
}
