import 'dart:typed_data';

import 'branch.dart';

/// A bulk scrap disposal run: a set of scrap items sold off together to a
/// refiner/buyer. [grossGrams] and [grossAmountCentavos] are entered by
/// staff at settlement time; [capitalCentavos] and [netCentavos] are
/// derived.
///
/// [commitmentRef] is required: scrap only ever leaves this shop to pay
/// down a commitment, so a batch with nowhere to apply its gross is not a
/// disposal anyone can account for.
class DisposalBatch {
  final String id;
  final BranchId branch;
  final List<String> itemIds;
  final int capitalCentavos;
  final double grossGrams;
  final int grossAmountCentavos;
  final String commitmentRef;
  final DateTime date;

  /// Photo taken at settlement — the scrap on the refiner's scale, or the
  /// settlement slip.
  final Uint8List? photo;

  const DisposalBatch({
    required this.id,
    required this.branch,
    required this.itemIds,
    required this.capitalCentavos,
    required this.grossGrams,
    required this.grossAmountCentavos,
    required this.date,
    required this.commitmentRef,
    this.photo,
  });

  /// Derived — profit/loss on the batch.
  int get netCentavos => grossAmountCentavos - capitalCentavos;
}
