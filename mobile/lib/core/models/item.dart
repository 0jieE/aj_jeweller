import 'dart:typed_data';

import 'branch.dart';
import 'item_status.dart';
import 'user_role.dart';

/// What an item is for. Goods are resold as they are; scrap only ever leaves
/// through a bulk disposal batch.
enum ItemType {
  goods,
  scrap,
  silver;

  String get label {
    switch (this) {
      case ItemType.goods:
        return 'Goods';
      case ItemType.scrap:
        return 'Scrap';
      case ItemType.silver:
        return 'Silver';
    }
  }

  /// Silver is a different metal, not just a different route out of the
  /// shop: it is graded by fineness rather than karat and priced from its
  /// own rate. Like goods, it is resold over the counter.
  bool get isSilver => this == ItemType.silver;
}

/// A single piece of gold (or other precious metal) inventory.
///
/// [weightGrams] is always the **net** gold weight — what the shop actually
/// paid for and what every valuation, partition, and disposal figure works
/// from. [grossWeightGrams] records what the scale read with stones, clasps
/// and dirt still on the piece, kept only so the deduction stays visible
/// after the fact.
///
/// Items can be partitioned out of a larger purchased lot — e.g. a bulk
/// scrap purchase later split into smaller listed pieces. When partitioned,
/// [parentLotId] points at the originating [Item], and the `original*`
/// fields freeze what that lot looked like before any partitioning, while
/// `remaining*` tracks what's left of it. Both stay `null` until the lot's
/// first partition is drawn — use the `effective*` getters, which fall back
/// to the item's own weight/amount, rather than reading the raw fields.
class Item {
  final String id;
  final String description;

  /// Net gold weight — the basis for every figure in the app.
  final double weightGrams;

  /// As-presented weight before deductions. Null for partitions, which are
  /// drawn from an already-netted lot.
  final double? grossWeightGrams;

  final int karat;
  final ItemType type;
  final int capitalAmountCentavos;
  final String origin;
  final BranchId branch;
  final ItemStatus itemStatus;
  final VerificationStatus verificationStatus;
  final DateTime purchaseDate;
  final AppUserRole submittedByRole;

  /// A photo of the physical piece, taken by whoever encoded it.
  ///
  /// This is the counter's proof of what was actually handed over: the
  /// Cashier verifying a purchase is looking at a record for goods they may
  /// never see, so the photo is what they check the description and weight
  /// against before releasing cash. Held as raw bytes because this prototype
  /// has no file store behind it.
  final Uint8List? photo;

  bool get hasPhoto => photo != null;

  /// The staff member who encoded this piece — the Appraiser at purchase, or
  /// whoever drew a partition out of a lot.
  final String? encodedByUserId;

  /// The purchase this item was bought in. Partitions inherit their parent
  /// lot's batch, since that's the transaction they ultimately came from.
  final String? batchId;

  /// Set by a Cashier's "return for correction" — cleared on resubmission.
  final String? verificationNote;

  // Partitioning (lots split into smaller items).
  final String? parentLotId;
  final double? originalGrams;
  final int? originalAmountCentavos;
  final double? remainingGrams;
  final int? remainingAmountCentavos;

  const Item({
    required this.id,
    required this.description,
    required this.weightGrams,
    this.grossWeightGrams,
    required this.karat,
    required this.type,
    required this.capitalAmountCentavos,
    required this.origin,
    required this.branch,
    required this.itemStatus,
    required this.verificationStatus,
    required this.purchaseDate,
    required this.submittedByRole,
    this.photo,
    this.encodedByUserId,
    this.batchId,
    this.verificationNote,
    this.parentLotId,
    this.originalGrams,
    this.originalAmountCentavos,
    this.remainingGrams,
    this.remainingAmountCentavos,
  });

  bool get isPartitioned => parentLotId != null;
  bool get hasPartitions => originalGrams != null;

  /// What the scale read before deductions; falls back to the net weight for
  /// records where nothing was deducted.
  double get effectiveGrossWeightGrams => grossWeightGrams ?? weightGrams;

  /// Grams taken off between gross and net — stones, clasps, dirt.
  double get deductedGrams => effectiveGrossWeightGrams - weightGrams;

  double get effectiveOriginalGrams => originalGrams ?? weightGrams;
  int get effectiveOriginalAmountCentavos => originalAmountCentavos ?? capitalAmountCentavos;
  double get effectiveRemainingGrams => remainingGrams ?? weightGrams;
  int get effectiveRemainingAmountCentavos => remainingAmountCentavos ?? capitalAmountCentavos;

  /// True once every gram and every centavo of this lot has been drawn into
  /// partitions — a fully-drawn lot renders as closed, not just "low".
  bool get isExhausted => hasPartitions && effectiveRemainingGrams <= 0 && effectiveRemainingAmountCentavos <= 0;

  /// True while this partition can still be handed back to the lot it came
  /// from. Once it has been sold, held for a customer order, or disposed of,
  /// unwinding the draw would contradict a record that already happened — the
  /// correction belongs on that record instead.
  bool get canReturnToParent =>
      isPartitioned &&
      (itemStatus == ItemStatus.pending ||
          itemStatus == ItemStatus.listed ||
          itemStatus == ItemStatus.forDisposal);

  Item copyWith({
    String? description,
    double? weightGrams,
    double? grossWeightGrams,
    int? karat,
    ItemType? type,
    int? capitalAmountCentavos,
    ItemStatus? itemStatus,
    Uint8List? photo,
    String? encodedByUserId,
    VerificationStatus? verificationStatus,
    double? remainingGrams,
    int? remainingAmountCentavos,
    double? originalGrams,
    int? originalAmountCentavos,
    String? verificationNote,
    bool clearVerificationNote = false,
  }) {
    return Item(
      id: id,
      description: description ?? this.description,
      weightGrams: weightGrams ?? this.weightGrams,
      grossWeightGrams: grossWeightGrams ?? this.grossWeightGrams,
      karat: karat ?? this.karat,
      type: type ?? this.type,
      capitalAmountCentavos: capitalAmountCentavos ?? this.capitalAmountCentavos,
      origin: origin,
      branch: branch,
      itemStatus: itemStatus ?? this.itemStatus,
      verificationStatus: verificationStatus ?? this.verificationStatus,
      purchaseDate: purchaseDate,
      submittedByRole: submittedByRole,
      photo: photo ?? this.photo,
      encodedByUserId: encodedByUserId ?? this.encodedByUserId,
      batchId: batchId,
      verificationNote: clearVerificationNote ? null : (verificationNote ?? this.verificationNote),
      parentLotId: parentLotId,
      originalGrams: originalGrams ?? this.originalGrams,
      originalAmountCentavos: originalAmountCentavos ?? this.originalAmountCentavos,
      remainingGrams: remainingGrams ?? this.remainingGrams,
      remainingAmountCentavos:
          remainingAmountCentavos ?? this.remainingAmountCentavos,
    );
  }
}
