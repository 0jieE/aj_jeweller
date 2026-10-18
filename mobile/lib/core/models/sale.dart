import 'branch.dart';
import 'customer.dart';
import 'item.dart';
import 'item_status.dart';
import 'user_role.dart';

/// How a sale was settled.
///
/// Split by construction rather than a single choice: customers routinely pay
/// part in cash and transfer the rest, and forcing that into one bucket puts
/// money in the wrong place — the cash drawer and the bank account are
/// reconciled separately, against different physical things.
class SalePayment {
  final int cashCentavos;
  final int bankCentavos;

  const SalePayment({this.cashCentavos = 0, this.bankCentavos = 0});

  const SalePayment.cash(int amount) : cashCentavos = amount, bankCentavos = 0;
  const SalePayment.bank(int amount) : cashCentavos = 0, bankCentavos = amount;

  int get totalCentavos => cashCentavos + bankCentavos;

  bool get isSplit => cashCentavos > 0 && bankCentavos > 0;
  bool get isCashOnly => cashCentavos > 0 && bankCentavos == 0;
  bool get isBankOnly => bankCentavos > 0 && cashCentavos == 0;

  /// True once the payment adds up to what the order is worth. A sale that
  /// does not is not a completed sale.
  bool covers(int saleTotalCentavos) => totalCentavos == saleTotalCentavos;

  String get label {
    if (isSplit) return 'Cash + Bank';
    if (isBankOnly) return 'Bank Transfer';
    return 'Cash';
  }

  SalePayment copyWith({int? cashCentavos, int? bankCentavos}) => SalePayment(
        cashCentavos: cashCentavos ?? this.cashCentavos,
        bankCentavos: bankCentavos ?? this.bankCentavos,
      );
}

/// One item within a sale, at the price actually negotiated with the
/// customer (which may differ from the item's listed value).
///
/// [finalGrams] is the weight the piece is actually sold at — re-weighed at
/// the counter, since a piece can lose weight to repair or polishing between
/// purchase and sale. [pricePerGramCentavos] and [negotiatedPriceCentavos]
/// are two views of the same deal: the rep can quote a per-gram rate or a
/// total, and the other follows. The total is what the customer pays and
/// what the ledger records, so it stays the stored figure.
class SaleLineItem {
  final Item item;
  final int negotiatedPriceCentavos;

  /// Weight sold at; falls back to the item's own net weight when the piece
  /// wasn't re-weighed.
  final double? finalGrams;

  const SaleLineItem({
    required this.item,
    required this.negotiatedPriceCentavos,
    this.finalGrams,
  });

  double get effectiveFinalGrams => finalGrams ?? item.weightGrams;

  /// Derived, never stored — the total divided by the weight it was struck
  /// at, so it can't drift away from what the customer actually pays.
  int get pricePerGramCentavos {
    final grams = effectiveFinalGrams;
    if (grams <= 0) return 0;
    return (negotiatedPriceCentavos / grams).round();
  }
}

/// A customer order. [paymentMethod] is the customer's stated intent,
/// captured by the Sales Rep at checkout — the Cashier confirms (or
/// corrects) it when payment is actually received.
class Sale {
  final String id;
  final List<SaleLineItem> lineItems;
  /// The customer as written onto this sale — a copy, so the record keeps
  /// saying what it said when it was issued.
  final CustomerDetails customer;

  final String? note;
  final SalePayment payment;
  final VerificationStatus verificationStatus;

  /// Set by a Cashier's "return to rep" — cleared on resubmission.
  final String? verificationNote;

  final BranchId branch;
  final DateTime date;
  final AppUserRole submittedByRole;

  /// The Sales Rep who built the order.
  final String? submittedByUserId;

  /// The Cashier who received payment; null until then.
  final String? receivedByUserId;

  const Sale({
    required this.id,
    required this.lineItems,
    required this.customer,
    this.note,
    required this.payment,
    required this.verificationStatus,
    this.verificationNote,
    required this.branch,
    required this.date,
    required this.submittedByRole,
    this.submittedByUserId,
    this.receivedByUserId,
  });

  String get customerName => customer.name;

  /// Derived — never entered directly.
  int get totalAmountCentavos =>
      lineItems.fold(0, (sum, line) => sum + line.negotiatedPriceCentavos);

  Sale copyWith({
    List<SaleLineItem>? lineItems,
    CustomerDetails? customer,
    String? note,
    SalePayment? payment,
    VerificationStatus? verificationStatus,
    String? verificationNote,
    bool clearVerificationNote = false,
    String? receivedByUserId,
  }) {
    return Sale(
      id: id,
      lineItems: lineItems ?? this.lineItems,
      customer: customer ?? this.customer,
      note: note ?? this.note,
      payment: payment ?? this.payment,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      verificationNote: clearVerificationNote ? null : (verificationNote ?? this.verificationNote),
      branch: branch,
      date: date,
      submittedByRole: submittedByRole,
      submittedByUserId: submittedByUserId,
      receivedByUserId: receivedByUserId ?? this.receivedByUserId,
    );
  }
}
