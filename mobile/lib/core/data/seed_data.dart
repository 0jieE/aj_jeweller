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
import '../models/transaction_log.dart';
import '../models/user_role.dart';
import 'money_text.dart';
import 'staff_directory.dart';

/// Realistic Philippine gold-shop seed data so every screen looks alive
/// from a fresh install. Generated relative to [DateTime.now] so "today"
/// always lines up with the dashboard's "today's activity" section.
class SeedData {
  SeedData._();

  // Starting balances are chosen so that, once [cashEntries] backfills every
  // seed purchase release / cash sale / commitment receipt below, each
  // branch's derived AppRepository.cashBalance lands on the exact figure
  // this prototype has always shown (₱1,037,903.00 Kidapawan, ₱694,169.00
  // Davao) — the cash ledger refactor must not move the Dashboard's numbers.
  static List<Branch> branches() => const [
        Branch(
          id: BranchId.kidapawan,
          // Sale takings now land in Sales Cash, not the purchase float, so
          // the float opens ₱115,000 higher to keep its balance unchanged.
          // ...and ₱1,800 higher again for the released silver ring set below.
          startingCashBalanceCentavos: 159840300, // ₱1,598,403.00
          bankBalanceCentavos: 25850000, // ₱258,500.00
        ),
        Branch(
          id: BranchId.davao,
          // Includes ₱4,600 for the released silver coins below.
          startingCashBalanceCentavos: 128776900, // ₱1,287,769.00
          bankBalanceCentavos: 18420000, // ₱184,200.00
          silverValueCentavos: 14926100, // ₱149,261.00
        ),
      ];

  static List<GoldRate> goldRates() {
    final now = DateTime.now().subtract(const Duration(hours: 2));
    const pricesPerGram = {
      24: 615000, // ₱6,150.00
      22: 563800, // ₱5,638.00
      21: 538100, // ₱5,381.00
      20: 512500, // ₱5,125.00
      18: 461300, // ₱4,613.00
      14: 358800, // ₱3,588.00
      10: 256300, // ₱2,563.00
      // Silver, by fineness.
      999: 7500, // ₱75.00
      925: 6500, // ₱65.00
    };
    return pricesPerGram.entries
        .map((e) => GoldRate(
              karat: e.key,
              pricePerGramCentavos: e.value,
              updatedAt: now,
            ))
        .toList();
  }

  /// A short run of past prices behind each seeded rate, ending on the rate
  /// as it stands, so the history screen opens on something real: first set
  /// a month ago, nudged two weeks ago, and today's figure a couple of hours
  /// back. Set by the owner, who is the one who manages rates.
  static List<RateChange> rateHistory(List<GoldRate> rates) {
    final admin = StaffDirectory.forRole(AppUserRole.admin);
    final now = DateTime.now();
    int wholePesos(double centavos) => (centavos / 100).round() * 100;

    final history = <RateChange>[];
    for (final rate in rates) {
      final current = rate.pricePerGramCentavos;
      final first = wholePesos(current * 0.96);
      final second = wholePesos(current * 0.98);
      history
        ..add(RateChange(
          karat: rate.karat,
          afterCentavos: first,
          at: now.subtract(const Duration(days: 30)),
          userId: admin.id,
          userName: admin.name,
        ))
        ..add(RateChange(
          karat: rate.karat,
          beforeCentavos: first,
          afterCentavos: second,
          at: now.subtract(const Duration(days: 14)),
          userId: admin.id,
          userName: admin.name,
        ))
        ..add(RateChange(
          karat: rate.karat,
          beforeCentavos: second,
          afterCentavos: current,
          at: rate.updatedAt,
          userId: admin.id,
          userName: admin.name,
        ));
    }
    return history;
  }

  static List<Item> items() {
    final now = DateTime.now();
    DateTime daysAgo(int d) => now.subtract(Duration(days: d));

    return _attributeItems([
      // --- Kidapawan ---------------------------------------------------
      Item(
        id: '7H3M2Q',
        batchId: 'A7K2M9',
        description: '22K gold necklace, rope chain',
        weightGrams: 15.750,
        grossWeightGrams: 16.400,
        karat: 22,
        type: ItemType.goods,
        capitalAmountCentavos: 8200000,
        origin: 'Maria Santos',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(5),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'B4T9KD',
        batchId: 'A3T8QD',
        description: '18K gold ring w/ diamond chip',
        weightGrams: 3.200,
        grossWeightGrams: 3.850,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1350000,
        origin: 'Rico Dela Cruz',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.awaitingVerification,
        purchaseDate: now,
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      // Parent lot — partially partitioned out into M9Q4RT below.
      Item(
        id: 'X2P7LN',
        batchId: 'A9P4XN',
        description: 'Bulk scrap lot – broken chains',
        weightGrams: 27.500,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 10500000,
        origin: 'Bulk buy – pawnshop consignment',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.forDisposal,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(10),
        submittedByRole: AppUserRole.assistantAppraiser,
        originalGrams: 42.500,
        originalAmountCentavos: 16500000,
        remainingGrams: 27.500,
        remainingAmountCentavos: 10500000,
      ),
      Item(
        id: 'M9Q4RT',
        batchId: 'A9P4XN',
        description: 'Partitioned – 18K fine filings, listed for resale',
        weightGrams: 15.000,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 6000000,
        origin: 'Bulk buy – pawnshop consignment',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(9),
        submittedByRole: AppUserRole.assistantAppraiser,
        parentLotId: 'X2P7LN',
      ),
      Item(
        id: 'K7D3WZ',
        batchId: 'A7K2M9',
        description: 'Mixed small jewelry',
        weightGrams: 8.900,
        grossWeightGrams: 9.400,
        karat: 14,
        type: ItemType.goods,
        capitalAmountCentavos: 2470000,
        origin: 'Maria Santos',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(3),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      // Released silver — on hand, so it shows under Sell → Silver and
      // Dispose → Silver until one or the other takes it.
      Item(
        id: 'S2L9VQ',
        batchId: 'A4S7VN',
        description: '925 silver ring set (3 pcs)',
        weightGrams: 30.000,
        karat: 925,
        type: ItemType.silver,
        capitalAmountCentavos: 180000,
        origin: 'Joy Villareal',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(4),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'S5K8VD',
        batchId: 'B6S3VD',
        description: '999 silver coins, assorted',
        weightGrams: 62.200,
        karat: 999,
        type: ItemType.silver,
        capitalAmountCentavos: 460000,
        origin: 'Mario Tan',
        branch: BranchId.davao,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(6),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'S7V2RB',
        batchId: 'A5S9VR',
        description: '925 silver bracelet, curb link',
        weightGrams: 24.500,
        grossWeightGrams: 25.000,
        karat: 925,
        type: ItemType.silver,
        capitalAmountCentavos: 150000,
        origin: 'Lorna Diaz',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.awaitingVerification,
        purchaseDate: now,
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'S8B3VN',
        batchId: 'A5S9VR',
        description: '999 silver bar, 50g',
        weightGrams: 50.000,
        karat: 999,
        type: ItemType.silver,
        capitalAmountCentavos: 360000,
        origin: 'Lorna Diaz',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.awaitingVerification,
        purchaseDate: now,
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'V5N8JH',
        batchId: 'A3T8QD',
        description: '24K gold bar clipping',
        weightGrams: 2.100,
        karat: 24,
        type: ItemType.goods,
        capitalAmountCentavos: 1260000,
        origin: 'Rico Dela Cruz',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.awaitingVerification,
        purchaseDate: now,
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'T3R6PC',
        batchId: 'A8R3PC',
        description: '21K gold bangle',
        weightGrams: 20.300,
        karat: 21,
        type: ItemType.goods,
        capitalAmountCentavos: 9800000,
        origin: 'Eloisa Gomez',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.sold,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(12),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'G8L2XF',
        batchId: 'A4L9XF',
        description: 'Scrap batch – prior disposal lot',
        weightGrams: 38.200,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 14000000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.disposed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(25),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'W4K7MB',
        batchId: 'A6K4MB',
        description: '18K gold ring, plain band',
        weightGrams: 4.000,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1700000,
        origin: 'Grace Palma',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.sold,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(1),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'J4W8PT',
        batchId: 'A9W7PT',
        description: 'Scrap lot – mixed 18K oddments',
        weightGrams: 21.400,
        grossWeightGrams: 22.900,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 9200000,
        origin: 'Bulk buy – estate clearance',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.disposed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(19),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'Q6Y3DN',
        batchId: 'A7Y2DN',
        description: 'Scrap batch – loan payoff lot',
        weightGrams: 93.000,
        karat: 21,
        type: ItemType.scrap,
        capitalAmountCentavos: 44000000,
        origin: 'Bulk buy',
        branch: BranchId.kidapawan,
        itemStatus: ItemStatus.disposed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(18),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),

      // --- Davao ---------------------------------------------------------
      Item(
        id: 'Z9C4HT',
        batchId: 'B9C3HT',
        description: '22K gold earrings, hoop pair',
        weightGrams: 6.400,
        karat: 22,
        type: ItemType.goods,
        capitalAmountCentavos: 3420000,
        origin: 'Ana Villanueva',
        branch: BranchId.davao,
        itemStatus: ItemStatus.listed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(6),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'L2M8XK',
        batchId: 'B2M7XK',
        description: '18K gold pendant, cross',
        weightGrams: 4.100,
        karat: 18,
        type: ItemType.goods,
        capitalAmountCentavos: 1680000,
        origin: 'Jun Alba',
        branch: BranchId.davao,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.awaitingVerification,
        purchaseDate: now,
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'N7V3BQ',
        batchId: 'B7V4BQ',
        description: 'Scrap – assorted broken pieces',
        weightGrams: 65.800,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 25500000,
        origin: 'Bulk buy – estate lot',
        branch: BranchId.davao,
        itemStatus: ItemStatus.forDisposal,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(8),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'R4J9WD',
        batchId: 'B4J8WD',
        description: '21K gold ring, solitaire setting',
        weightGrams: 5.500,
        karat: 21,
        type: ItemType.goods,
        capitalAmountCentavos: 2830000,
        origin: 'Carmela Reyes',
        branch: BranchId.davao,
        itemStatus: ItemStatus.reserved,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(2),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'C8F2TM',
        batchId: 'B8F3TM',
        description: '24K gold ingot piece',
        weightGrams: 10.000,
        karat: 24,
        type: ItemType.goods,
        capitalAmountCentavos: 6150000,
        origin: 'Danny Uy',
        branch: BranchId.davao,
        itemStatus: ItemStatus.sold,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(9),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'H5P7LZ',
        batchId: 'B5P6LZ',
        description: 'Broken earrings mix',
        weightGrams: 12.300,
        grossWeightGrams: 13.100,
        karat: 14,
        type: ItemType.scrap,
        capitalAmountCentavos: 3410000,
        origin: 'Perla Cruz',
        branch: BranchId.davao,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.returnedForCorrection,
        purchaseDate: daysAgo(1),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'S4N6VK',
        batchId: 'B5S2VK',
        description: '925 silver necklace, box chain',
        weightGrams: 18.500,
        karat: 925,
        type: ItemType.silver,
        capitalAmountCentavos: 111000,
        origin: 'Tess Navarro',
        branch: BranchId.davao,
        itemStatus: ItemStatus.pending,
        verificationStatus: VerificationStatus.awaitingVerification,
        purchaseDate: now,
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
      Item(
        id: 'D3X6KN',
        batchId: 'B3X7KN',
        description: 'Scrap batch – prior disposal lot',
        weightGrams: 55.000,
        karat: 18,
        type: ItemType.scrap,
        capitalAmountCentavos: 21000000,
        origin: 'Bulk buy',
        branch: BranchId.davao,
        itemStatus: ItemStatus.disposed,
        verificationStatus: VerificationStatus.verified,
        purchaseDate: daysAgo(18),
        submittedByRole: AppUserRole.assistantAppraiser,
      ),
    ]);
  }

  /// Each seeded piece was encoded by its branch's Appraiser.
  static List<Item> _attributeItems(List<Item> items) => [
        for (final item in items)
          item.copyWith(
            encodedByUserId: StaffDirectory.forRole(
              AppUserRole.assistantAppraiser,
              branch: item.branch,
            ).id,
          ),
      ];

  static List<Sale> sales(List<Item> items) {
    final now = DateTime.now();
    Item find(String id) => items.firstWhere((i) => i.id == id);

    return [
      Sale(
        id: 'S4M2HQ',
        lineItems: [
          SaleLineItem(
            item: find('T3R6PC'),
            negotiatedPriceCentavos: 11500000,
            finalGrams: 20.100,
          ),
        ],
        customer: const CustomerDetails(
          name: 'Teresa Lim',
          contactNumber: '0916 774 2098',
          address: 'Poblacion, Kidapawan City',
        ),
        payment: const SalePayment.cash(11500000),
        verificationStatus: VerificationStatus.verified,
        branch: BranchId.kidapawan,
        date: now.subtract(const Duration(days: 2)),
        submittedByRole: AppUserRole.salesRep,
        submittedByUserId: 'USR-K-REP',
        receivedByUserId: 'USR-K-CSH',
      ),
      Sale(
        id: 'S8K7TD',
        lineItems: [
          SaleLineItem(
            item: find('C8F2TM'),
            negotiatedPriceCentavos: 7200000,
            finalGrams: 10.000,
          ),
        ],
        customer: const CustomerDetails(
          name: 'Michael Ong',
          contactNumber: '0933 512 8841',
        ),
        payment: const SalePayment(cashCentavos: 2200000, bankCentavos: 5000000),
        verificationStatus: VerificationStatus.awaitingVerification,
        branch: BranchId.davao,
        date: now,
        submittedByRole: AppUserRole.salesRep,
        submittedByUserId: 'USR-D-REP',
      ),
      Sale(
        id: 'S3W9NL',
        lineItems: [
          SaleLineItem(
            item: find('W4K7MB'),
            negotiatedPriceCentavos: 2200000,
            finalGrams: 3.950,
          ),
        ],
        customer: const CustomerDetails(name: 'Grace Palma'),
        payment: const SalePayment.cash(2200000),
        verificationStatus: VerificationStatus.awaitingVerification,
        branch: BranchId.kidapawan,
        date: now,
        submittedByRole: AppUserRole.salesRep,
        submittedByUserId: 'USR-K-REP',
      ),
    ];
  }

  static List<Commitment> commitments() {
    final now = DateTime.now();
    DateTime daysAgo(int d) => now.subtract(Duration(days: d));

    return [
      // Fully repaid — DSP-003 below applies exactly ₱500,000 in gross
      // against it, so its ledger computes to loanPaid automatically.
      Commitment(
        id: 'P7B4QX',
        lender: 'Metro Pawnshop Corp',
        amountCentavos: 50000000,
        ratePerGramCentavos: 538100,
        branch: BranchId.kidapawan,
        dateApproved: daysAgo(30),
        dateReceived: daysAgo(28),
      ),
      // Company-wide — not tied to one branch. Partially repaid by DSP-002.
      Commitment(
        id: 'P2N9KM',
        lender: 'Golden Circle Lending',
        amountCentavos: 75000000,
        ratePerGramCentavos: 563800,
        branch: null,
        dateApproved: daysAgo(15),
        dateReceived: daysAgo(10),
      ),
      // Still pending — approved, cash not yet received, no repayment
      // history at all.
      Commitment(
        id: 'P5T3HD',
        lender: 'Kidapawan Credit Union',
        amountCentavos: 30000000,
        ratePerGramCentavos: 461300,
        branch: BranchId.kidapawan,
        dateApproved: daysAgo(5),
      ),
    ];
  }

  static List<DisposalBatch> disposalBatches() {
    final now = DateTime.now();
    return [
      DisposalBatch(
        id: 'F9R2MW',
        branch: BranchId.kidapawan,
        itemIds: const ['G8L2XF'],
        capitalCentavos: 14000000,
        grossGrams: 38.200,
        grossAmountCentavos: 15280000,
        date: now.subtract(const Duration(days: 20)),
        commitmentRef: 'P7B4QX',
      ),
      DisposalBatch(
        id: 'F4K8QT',
        branch: BranchId.davao,
        itemIds: const ['D3X6KN'],
        capitalCentavos: 21000000,
        grossGrams: 55.000,
        grossAmountCentavos: 20450000,
        date: now.subtract(const Duration(days: 15)),
        commitmentRef: 'P2N9KM',
      ),
      DisposalBatch(
        id: 'F6H3ZN',
        branch: BranchId.kidapawan,
        itemIds: const ['Q6Y3DN', 'J4W8PT'],
        capitalCentavos: 53200000,
        grossGrams: 114.400,
        grossAmountCentavos: 50000000,
        date: now.subtract(const Duration(days: 15)),
        commitmentRef: 'P7B4QX',
      ),
    ];
  }

  /// The purchase transactions behind [items], rebuilt from the items
  /// themselves so a batch can never disagree with the pieces it contains.
  /// One batch per customer visit; its status is the status of the pieces.
  static List<PurchaseBatch> purchaseBatches(List<Item> items) {
    // A couple of reachable customers so the receipt has something to print.
    const contacts = {
      'A7K2M9': '0917 555 0142',
      'A3T8QD': '0918 231 7744',
      'A8R3PC': '0905 887 3310',
      'A6K4MB': '0936 221 9087',
      'B9C3HT': '0922 604 1180',
      'B4J8WD': '0947 118 2265',
    };
    const addresses = {
      'A7K2M9': 'Poblacion, Kidapawan City',
      'A3T8QD': 'Amas, Kidapawan City',
      'A8R3PC': 'Lanao, Kidapawan City',
      'B9C3HT': 'Matina, Davao City',
      'B4J8WD': 'Buhangin, Davao City',
    };

    final grouped = <String, List<Item>>{};
    for (final item in items) {
      final id = item.batchId;
      if (id == null) continue;
      grouped.putIfAbsent(id, () => []).add(item);
    }

    final batches = <PurchaseBatch>[];
    grouped.forEach((id, group) {
      // The lot the customer actually handed over, not a partition drawn from
      // it later — that piece carries the transaction's real details.
      final lead = group.firstWhere(
        (i) => !i.isPartitioned,
        orElse: () => group.first,
      );
      batches.add(PurchaseBatch(
        id: id,
        customer: CustomerDetails(
          name: lead.origin,
          contactNumber: contacts[id],
          address: addresses[id],
        ),
        branch: lead.branch,
        date: lead.purchaseDate,
        submittedByRole: lead.submittedByRole,
        verificationStatus: lead.verificationStatus,
        verificationNote: lead.verificationNote,
        // Released a little after it was encoded — the customer waits while
        // the Cashier checks the pieces.
        releasedAt: lead.verificationStatus == VerificationStatus.verified
            ? lead.purchaseDate.add(const Duration(minutes: 20))
            : null,
        submittedByUserId: lead.encodedByUserId,
        releasedByUserId: lead.verificationStatus == VerificationStatus.verified
            ? StaffDirectory.forRole(AppUserRole.cashier, branch: lead.branch).id
            : null,
      ));
    });

    batches.sort((a, b) => b.date.compareTo(a.date));
    return batches;
  }

  /// The customer book, derived from the transactions rather than listed
  /// separately — a customer exists because the shop dealt with them, and
  /// building the book this way means the two can never disagree.
  static List<Customer> customers(List<PurchaseBatch> batches, List<Sale> sales) {
    final byKey = <String, Customer>{};
    var seq = 0;

    void record(CustomerDetails details, DateTime seenAt) {
      final key = Customer.matchKey(details.name);
      if (key.isEmpty) return;
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = Customer(
          id: 'CUS${(++seq).toString().padLeft(3, '0')}',
          name: details.name.trim(),
          contactNumber: details.contactNumber,
          address: details.address,
          firstSeen: seenAt,
        );
        return;
      }
      // Fill gaps from whichever transaction happened to carry the detail,
      // and keep the earliest sighting.
      byKey[key] = Customer(
        id: existing.id,
        name: existing.name,
        contactNumber: existing.contactNumber ?? details.contactNumber,
        address: existing.address ?? details.address,
        firstSeen: seenAt.isBefore(existing.firstSeen) ? seenAt : existing.firstSeen,
      );
    }

    for (final batch in batches) {
      record(batch.customer, batch.date);
    }
    for (final sale in sales) {
      record(sale.customer, sale.date);
    }
    return byKey.values.toList();
  }

  /// Backfilled ledger entries for every seed purchase/sale/commitment that
  /// had already moved cash before the app opens — the cash ledger's only
  /// job is to be the complete history behind [branches]'s starting
  /// balances, so every one of those past movements needs a matching entry
  /// here rather than being silently baked into a stored "current balance".
  static List<CashEntry> cashEntries(
    List<Item> items,
    List<Sale> sales,
    List<Commitment> commitments,
    List<PurchaseBatch> batches,
  ) {
    final entries = <CashEntry>[];
    var seq = 0;
    String nextId() => 'CSH${(++seq).toString().padLeft(3, '0')}';

    // One entry per released batch — cash leaves the till once per customer,
    // for the whole lot they brought in.
    //
    // The amount is each lot's *original* figure, not what remains of it: a
    // lot that was later partitioned was paid for in full at release, and the
    // split happened afterwards without moving any more cash.
    for (final batch in batches) {
      if (batch.verificationStatus != VerificationStatus.verified) continue;
      final lines = items
          .where((i) => i.batchId == batch.id && !i.isPartitioned)
          .toList();
      if (lines.isEmpty) continue;
      final total = lines.fold<int>(
        0,
        (sum, i) => sum + i.effectiveOriginalAmountCentavos,
      );
      entries.add(CashEntry(
        id: nextId(),
        branch: batch.branch,
        type: CashEntryType.expense,
        amountCentavos: total,
        note: 'Purchase released - ${batch.customer.name} (${lines.length} item(s))',
        category: 'Purchase',
        date: batch.releasedAt ?? batch.date,
        recordedByRole: AppUserRole.cashier,
        recordedByUserId: batch.releasedByUserId,
        sourceType: CashEntrySourceType.purchase,
        linkedRecordId: batch.id,
      ));
    }

    // Cash sales already completed (verified) — non-cash sales settle into
    // the bank balance, which the cash ledger doesn't track.
    for (final sale in sales) {
      if (sale.verificationStatus == VerificationStatus.verified &&
          sale.payment.cashCentavos > 0) {
        entries.add(CashEntry(
          id: nextId(),
          branch: sale.branch,
          type: CashEntryType.cashIn,
          account: CashAccount.sales,
          amountCentavos: sale.payment.cashCentavos,
          note: 'Payment received - ${sale.customerName}',
          date: sale.date,
          recordedByRole: AppUserRole.cashier,
          recordedByUserId: sale.receivedByUserId,
          sourceType: CashEntrySourceType.sale,
          linkedRecordId: sale.id,
        ));
      }
    }

    for (final sale in sales) {
      if (sale.verificationStatus == VerificationStatus.verified &&
          sale.payment.bankCentavos > 0) {
        entries.add(CashEntry(
          id: nextId(),
          branch: sale.branch,
          type: CashEntryType.cashIn,
          account: CashAccount.bank,
          amountCentavos: sale.payment.bankCentavos,
          note: 'Bank payment received - ${sale.customerName}',
          date: sale.date,
          recordedByRole: AppUserRole.cashier,
          recordedByUserId: sale.receivedByUserId,
          sourceType: CashEntrySourceType.sale,
          linkedRecordId: sale.id,
        ));
      }
    }

    // Branch-specific commitments already received — company-wide ones
    // have no single branch balance to credit, same as the live app.
    for (final c in commitments) {
      if (c.branch != null && c.dateReceived != null) {
        entries.add(CashEntry(
          id: nextId(),
          branch: c.branch!,
          type: CashEntryType.cashIn,
          amountCentavos: c.amountCentavos,
          note: 'Loan proceeds received - ${c.lender}',
          date: c.dateReceived!,
          recordedByRole: AppUserRole.admin,
          recordedByUserId: StaffDirectory.admin.id,
          sourceType: CashEntrySourceType.commitment,
          linkedRecordId: c.id,
        ));
      }
    }

    return entries;
  }

  /// The log history behind the seeded records, so the Transaction Logs page
  /// opens on the shop's actual past rather than on nothing. Built from the
  /// records themselves, so every entry corresponds to something that exists.
  static List<TransactionLog> transactionLogs({
    required List<Item> items,
    required List<PurchaseBatch> batches,
    required List<Sale> sales,
    required List<DisposalBatch> disposals,
    required List<Commitment> commitments,
    List<RateChange> rateHistory = const [],
  }) {
    final logs = <TransactionLog>[];
    var seq = 0;
    final admin = StaffDirectory.admin;

    void add({
      required DateTime at,
      required LogAction action,
      required String? userId,
      required AppUserRole fallbackRole,
      required BranchId? branch,
      required String summary,
      String? recordId,
      LogRecordKind? recordKind,
      int? amountCentavos,
      List<FieldChange> changes = const [],
    }) {
      final user = StaffDirectory.byId(userId) ??
          StaffDirectory.forRole(fallbackRole, branch: branch);
      logs.add(TransactionLog(
        id: 'LOG${(++seq).toString().padLeft(3, '0')}',
        at: at,
        action: action,
        userId: user.id,
        userName: user.name,
        role: user.role,
        branch: branch,
        recordId: recordId,
        recordKind: recordKind,
        amountCentavos: amountCentavos,
        summary: summary,
        changes: changes,
      ));
    }

    for (final batch in batches) {
      final lines = items.where((i) => i.batchId == batch.id && !i.isPartitioned).toList();
      final total = lines.fold<int>(0, (sum, i) => sum + i.effectiveOriginalAmountCentavos);
      add(
        at: batch.date,
        action: LogAction.purchaseRecorded,
        userId: batch.submittedByUserId,
        fallbackRole: AppUserRole.assistantAppraiser,
        branch: batch.branch,
        recordId: batch.id,
        recordKind: LogRecordKind.purchaseBatch,
        amountCentavos: total,
        summary: 'Recorded ${lines.length} item(s) from ${batch.customer.name} for ${pesoText(total)}',
      );
      if (batch.releasedAt != null) {
        add(
          at: batch.releasedAt!,
          action: LogAction.cashReleased,
          userId: batch.releasedByUserId,
          fallbackRole: AppUserRole.cashier,
          branch: batch.branch,
          recordId: batch.id,
          recordKind: LogRecordKind.purchaseBatch,
          amountCentavos: total,
          summary: 'Released ${pesoText(total)} to ${batch.customer.name} for ${lines.length} item(s)',
        );
      }
      if (batch.verificationStatus == VerificationStatus.returnedForCorrection) {
        add(
          at: batch.date.add(const Duration(minutes: 15)),
          action: LogAction.purchaseReturned,
          userId: null,
          fallbackRole: AppUserRole.cashier,
          branch: batch.branch,
          recordId: batch.id,
          recordKind: LogRecordKind.purchaseBatch,
          summary: 'Returned the purchase from ${batch.customer.name} for correction'
              '${batch.verificationNote == null ? '' : ': ${batch.verificationNote}'}',
        );
      }
    }

    for (final piece in items.where((i) => i.isPartitioned)) {
      add(
        at: piece.purchaseDate,
        action: LogAction.partitionCreated,
        userId: piece.encodedByUserId,
        fallbackRole: AppUserRole.assistantAppraiser,
        branch: piece.branch,
        recordId: piece.id,
        recordKind: LogRecordKind.item,
        amountCentavos: piece.capitalAmountCentavos,
        summary: 'Drew "${piece.description}" (${piece.weightGrams.toStringAsFixed(3)}g, '
            '${pesoText(piece.capitalAmountCentavos)}) out of lot ${piece.parentLotId}',
      );
    }

    for (final sale in sales) {
      add(
        at: sale.date,
        action: LogAction.saleSubmitted,
        userId: sale.submittedByUserId,
        fallbackRole: AppUserRole.salesRep,
        branch: sale.branch,
        recordId: sale.id,
        recordKind: LogRecordKind.sale,
        amountCentavos: sale.totalAmountCentavos,
        summary: 'Sent an order of ${sale.lineItems.length} item(s) for ${sale.customerName} '
            '(${pesoText(sale.totalAmountCentavos)}) to the Cashier',
      );
      if (sale.verificationStatus == VerificationStatus.verified) {
        add(
          at: sale.date.add(const Duration(minutes: 10)),
          action: LogAction.paymentReceived,
          userId: sale.receivedByUserId,
          fallbackRole: AppUserRole.cashier,
          branch: sale.branch,
          recordId: sale.id,
          recordKind: LogRecordKind.sale,
          amountCentavos: sale.payment.totalCentavos,
          summary: 'Received ${pesoText(sale.payment.totalCentavos)} from ${sale.customerName} '
              'by ${sale.payment.label.toLowerCase()}',
        );
      }
    }

    for (final c in commitments) {
      add(
        at: c.dateApproved,
        action: LogAction.commitmentAdded,
        userId: admin.id,
        fallbackRole: AppUserRole.admin,
        branch: c.branch,
        recordId: c.id,
        recordKind: LogRecordKind.commitment,
        amountCentavos: c.amountCentavos,
        summary: 'Added a ${pesoText(c.amountCentavos)} commitment with ${c.lender}',
      );
      if (c.dateReceived != null) {
        add(
          at: c.dateReceived!,
          action: LogAction.commitmentReceived,
          userId: admin.id,
          fallbackRole: AppUserRole.admin,
          branch: c.branch,
          recordId: c.id,
          recordKind: LogRecordKind.commitment,
          amountCentavos: c.amountCentavos,
          summary: 'Recorded ${pesoText(c.amountCentavos)} received from ${c.lender}',
        );
      }
    }

    for (final d in disposals) {
      final lender = commitments
          .where((c) => c.id == d.commitmentRef)
          .map((c) => c.lender)
          .firstOrNull ?? d.commitmentRef;
      add(
        at: d.date,
        action: LogAction.disposalCompleted,
        userId: admin.id,
        fallbackRole: AppUserRole.admin,
        branch: d.branch,
        recordId: d.id,
        recordKind: LogRecordKind.disposal,
        amountCentavos: d.grossAmountCentavos,
        summary: 'Disposed ${d.itemIds.length} item(s), ${d.grossGrams.toStringAsFixed(3)}g, '
            'for ${pesoText(d.grossAmountCentavos)} applied to $lender',
      );
    }

    // Rate setting, from the same seeded history the rates page shows, so the
    // two never disagree about who priced 18K and when.
    String purity(int k) => k >= 100 ? '$k silver' : '${k}K';
    for (final change in rateHistory) {
      final name = purity(change.karat);
      if (change.isInitial) {
        add(
          at: change.at,
          action: LogAction.goldRateAdded,
          userId: change.userId,
          fallbackRole: AppUserRole.admin,
          branch: null,
          summary: 'Added a $name rate at ${pesoText(change.afterCentavos)} per gram',
          changes: [
            FieldChange(field: '$name per gram', before: '—', after: pesoText(change.afterCentavos)),
          ],
        );
      } else {
        add(
          at: change.at,
          action: LogAction.goldRateUpdated,
          userId: change.userId,
          fallbackRole: AppUserRole.admin,
          branch: null,
          summary: '$name rate changed from ${pesoText(change.beforeCentavos!)} '
              'to ${pesoText(change.afterCentavos)} per gram',
          changes: [
            FieldChange(
              field: '$name per gram',
              before: pesoText(change.beforeCentavos!),
              after: pesoText(change.afterCentavos),
            ),
          ],
        );
      }
    }

    logs.sort((a, b) => a.at.compareTo(b.at));
    return logs;
  }
}
