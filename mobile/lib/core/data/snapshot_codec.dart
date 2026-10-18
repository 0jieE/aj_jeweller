import 'dart:convert';
import 'dart:typed_data';

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

/// Converts every stored record to and from plain JSON, so the shop's data
/// can be written to the device and read back on the next launch.
///
/// Enums are stored by name and dates as ISO strings, so the saved file stays
/// readable and survives reordering an enum. Photos and receipt PDFs are
/// base64. Kept outside the models on purpose: the models describe the shop,
/// this describes a file format.
class SnapshotCodec {
  SnapshotCodec._();

  // --- primitives -------------------------------------------------------------

  static String? _date(DateTime? d) => d?.toIso8601String();
  /// The phone writes plain local times, which parse back as local. The
  /// server stamps everything `+08:00`, which parses as UTC — so every date
  /// read here is pulled back to the phone's clock before anything asks it
  /// what day it is. A local time is already local, and [DateTime.toLocal]
  /// hands it straight back.
  static DateTime _parseDate(Object? v) => DateTime.parse(v as String).toLocal();
  static DateTime? _parseDateOrNull(Object? v) =>
      v == null ? null : DateTime.parse(v as String).toLocal();
  static String? _bytes(Uint8List? b) => b == null ? null : base64Encode(b);

  /// A photo as the server's JSON endpoints take it (base64, or absent).
  static String? encodePhoto(Uint8List? bytes) => _bytes(bytes);
  static Uint8List? _parseBytes(Object? v) => v == null ? null : base64Decode(v as String);
  static double _double(Object? v) => (v as num).toDouble();
  static double? _doubleOrNull(Object? v) => v == null ? null : (v as num).toDouble();
  static T _enum<T extends Enum>(List<T> values, Object? name) => values.byName(name as String);
  static T? _enumOrNull<T extends Enum>(List<T> values, Object? name) =>
      name == null ? null : values.byName(name as String);

  // --- staff ------------------------------------------------------------------

  static Map<String, dynamic> user(AppUser u) => {
        'id': u.id,
        'name': u.name,
        'role': u.role.name,
        'homeBranch': u.homeBranch?.name,
        'contact': u.contactNumber,
        'active': u.active,
      };

  static AppUser parseUser(Map<String, dynamic> j) => AppUser(
        id: j['id'] as String,
        name: j['name'] as String,
        role: AppUserRole.parse(j['role'] as String?),
        homeBranch: _enumOrNull(BranchId.values, j['homeBranch']),
        contactNumber: j['contact'] as String?,
        active: (j['active'] as bool?) ?? true,
      );

  // --- branch / rates ---------------------------------------------------------

  static Map<String, dynamic> branch(Branch b) => {
        'id': b.id.name,
        'startingCash': b.startingCashBalanceCentavos,
        'startingSalesCash': b.startingSalesCashCentavos,
        'startingBank': b.bankBalanceCentavos,
        'silverValue': b.silverValueCentavos,
      };

  static Branch parseBranch(Map<String, dynamic> j) => Branch(
        id: _enum(BranchId.values, j['id']),
        startingCashBalanceCentavos: j['startingCash'] as int,
        startingSalesCashCentavos: (j['startingSalesCash'] as int?) ?? 0,
        bankBalanceCentavos: (j['startingBank'] as int?) ?? 0,
        silverValueCentavos: (j['silverValue'] as int?) ?? 0,
      );

  static Map<String, dynamic> goldRate(GoldRate r) => {
        'karat': r.karat,
        'price': r.pricePerGramCentavos,
        'updatedAt': _date(r.updatedAt),
      };

  static GoldRate parseGoldRate(Map<String, dynamic> j) => GoldRate(
        karat: j['karat'] as int,
        pricePerGramCentavos: j['price'] as int,
        updatedAt: _parseDate(j['updatedAt']),
      );

  static Map<String, dynamic> rateChange(RateChange c) => {
        'karat': c.karat,
        'before': c.beforeCentavos,
        'after': c.afterCentavos,
        'at': _date(c.at),
        'userId': c.userId,
        'userName': c.userName,
        'restoredFrom': _date(c.restoredFrom),
      };

  static RateChange parseRateChange(Map<String, dynamic> j) => RateChange(
        karat: j['karat'] as int,
        beforeCentavos: j['before'] as int?,
        afterCentavos: j['after'] as int,
        at: _parseDate(j['at']),
        userId: j['userId'] as String,
        userName: j['userName'] as String,
        restoredFrom: _parseDateOrNull(j['restoredFrom']),
      );

  // --- items ------------------------------------------------------------------

  static Map<String, dynamic> item(Item i) => {
        'id': i.id,
        'description': i.description,
        'weight': i.weightGrams,
        'gross': i.grossWeightGrams,
        'karat': i.karat,
        'type': i.type.name,
        'capital': i.capitalAmountCentavos,
        'origin': i.origin,
        'branch': i.branch.name,
        'status': i.itemStatus.name,
        'verification': i.verificationStatus.name,
        'purchaseDate': _date(i.purchaseDate),
        'submittedByRole': i.submittedByRole.name,
        'photo': _bytes(i.photo),
        'encodedBy': i.encodedByUserId,
        'batchId': i.batchId,
        'verificationNote': i.verificationNote,
        'parentLotId': i.parentLotId,
        'originalGrams': i.originalGrams,
        'originalAmount': i.originalAmountCentavos,
        'remainingGrams': i.remainingGrams,
        'remainingAmount': i.remainingAmountCentavos,
      };

  static Item parseItem(Map<String, dynamic> j) => Item(
        id: j['id'] as String,
        description: j['description'] as String,
        weightGrams: _double(j['weight']),
        grossWeightGrams: _doubleOrNull(j['gross']),
        karat: j['karat'] as int,
        type: _enum(ItemType.values, j['type']),
        capitalAmountCentavos: j['capital'] as int,
        origin: j['origin'] as String,
        branch: _enum(BranchId.values, j['branch']),
        itemStatus: _enum(ItemStatus.values, j['status']),
        verificationStatus: _enum(VerificationStatus.values, j['verification']),
        purchaseDate: _parseDate(j['purchaseDate']),
        submittedByRole: AppUserRole.parse(j['submittedByRole'] as String?),
        photo: _parseBytes(j['photo']),
        encodedByUserId: j['encodedBy'] as String?,
        batchId: j['batchId'] as String?,
        verificationNote: j['verificationNote'] as String?,
        parentLotId: j['parentLotId'] as String?,
        originalGrams: _doubleOrNull(j['originalGrams']),
        originalAmountCentavos: j['originalAmount'] as int?,
        remainingGrams: _doubleOrNull(j['remainingGrams']),
        remainingAmountCentavos: j['remainingAmount'] as int?,
      );

  // --- customers --------------------------------------------------------------

  static Map<String, dynamic> customerDetails(CustomerDetails c) => {
        'name': c.name,
        'contact': c.contactNumber,
        'address': c.address,
        'customerId': c.customerId,
      };

  static CustomerDetails parseCustomerDetails(Map<String, dynamic> j) => CustomerDetails(
        name: j['name'] as String,
        contactNumber: j['contact'] as String?,
        address: j['address'] as String?,
        customerId: j['customerId'] as String?,
      );

  static Map<String, dynamic> customer(Customer c) => {
        'id': c.id,
        'name': c.name,
        'contact': c.contactNumber,
        'address': c.address,
        'firstSeen': _date(c.firstSeen),
        'photo': _bytes(c.photo),
      };

  static Customer parseCustomer(Map<String, dynamic> j) => Customer(
        id: j['id'] as String,
        name: j['name'] as String,
        contactNumber: j['contact'] as String?,
        address: j['address'] as String?,
        firstSeen: _parseDate(j['firstSeen']),
        photo: _parseBytes(j['photo']),
      );

  // --- purchases / sales ------------------------------------------------------

  static Map<String, dynamic> purchaseBatch(PurchaseBatch b) => {
        'id': b.id,
        'customer': customerDetails(b.customer),
        'branch': b.branch.name,
        'date': _date(b.date),
        'submittedByRole': b.submittedByRole.name,
        'verification': b.verificationStatus.name,
        'verificationNote': b.verificationNote,
        'releasedAt': _date(b.releasedAt),
        'submittedBy': b.submittedByUserId,
        'releasedBy': b.releasedByUserId,
        'releaseProofPhoto': _bytes(b.releaseProofPhoto),
      };

  static PurchaseBatch parsePurchaseBatch(Map<String, dynamic> j) => PurchaseBatch(
        id: j['id'] as String,
        customer: parseCustomerDetails((j['customer'] as Map).cast<String, dynamic>()),
        branch: _enum(BranchId.values, j['branch']),
        date: _parseDate(j['date']),
        submittedByRole: AppUserRole.parse(j['submittedByRole'] as String?),
        verificationStatus: _enum(VerificationStatus.values, j['verification']),
        verificationNote: j['verificationNote'] as String?,
        releasedAt: _parseDateOrNull(j['releasedAt']),
        submittedByUserId: j['submittedBy'] as String?,
        releasedByUserId: j['releasedBy'] as String?,
        releaseProofPhoto: _parseBytes(j['releaseProofPhoto']),
      );

  static Map<String, dynamic> sale(Sale s) => {
        'id': s.id,
        'lines': [
          for (final l in s.lineItems)
            {
              'item': item(l.item),
              'price': l.negotiatedPriceCentavos,
              'finalGrams': l.finalGrams,
            },
        ],
        'customer': customerDetails(s.customer),
        'note': s.note,
        'cash': s.payment.cashCentavos,
        'bank': s.payment.bankCentavos,
        'verification': s.verificationStatus.name,
        'verificationNote': s.verificationNote,
        'branch': s.branch.name,
        'date': _date(s.date),
        'submittedByRole': s.submittedByRole.name,
        'submittedBy': s.submittedByUserId,
        'receivedBy': s.receivedByUserId,
      };

  static Sale parseSale(Map<String, dynamic> j) => Sale(
        id: j['id'] as String,
        lineItems: [
          for (final raw in j['lines'] as List)
            SaleLineItem(
              item: parseItem(((raw as Map)['item'] as Map).cast<String, dynamic>()),
              negotiatedPriceCentavos: raw['price'] as int,
              finalGrams: _doubleOrNull(raw['finalGrams']),
            ),
        ],
        customer: parseCustomerDetails((j['customer'] as Map).cast<String, dynamic>()),
        note: j['note'] as String?,
        payment: SalePayment(cashCentavos: j['cash'] as int, bankCentavos: j['bank'] as int),
        verificationStatus: _enum(VerificationStatus.values, j['verification']),
        verificationNote: j['verificationNote'] as String?,
        branch: _enum(BranchId.values, j['branch']),
        date: _parseDate(j['date']),
        submittedByRole: AppUserRole.parse(j['submittedByRole'] as String?),
        submittedByUserId: j['submittedBy'] as String?,
        receivedByUserId: j['receivedBy'] as String?,
      );

  // --- commitments / disposals ------------------------------------------------

  static Map<String, dynamic> commitment(Commitment c) => {
        'id': c.id,
        'lender': c.lender,
        'amount': c.amountCentavos,
        'rate': c.ratePerGramCentavos,
        'branch': c.branch?.name,
        'approved': _date(c.dateApproved),
        'received': _date(c.dateReceived),
        'proofPhoto': _bytes(c.receivedProofPhoto),
      };

  static Commitment parseCommitment(Map<String, dynamic> j) => Commitment(
        id: j['id'] as String,
        lender: j['lender'] as String,
        amountCentavos: j['amount'] as int,
        ratePerGramCentavos: j['rate'] as int,
        branch: _enumOrNull(BranchId.values, j['branch']),
        dateApproved: _parseDate(j['approved']),
        dateReceived: _parseDateOrNull(j['received']),
        receivedProofPhoto: _parseBytes(j['proofPhoto']),
      );

  static Map<String, dynamic> disposalBatch(DisposalBatch d) => {
        'id': d.id,
        'branch': d.branch.name,
        'itemIds': d.itemIds,
        'capital': d.capitalCentavos,
        'grossGrams': d.grossGrams,
        'grossAmount': d.grossAmountCentavos,
        'commitmentRef': d.commitmentRef,
        'date': _date(d.date),
        'photo': _bytes(d.photo),
      };

  static DisposalBatch parseDisposalBatch(Map<String, dynamic> j) => DisposalBatch(
        id: j['id'] as String,
        branch: _enum(BranchId.values, j['branch']),
        itemIds: (j['itemIds'] as List).cast<String>(),
        capitalCentavos: j['capital'] as int,
        grossGrams: _double(j['grossGrams']),
        grossAmountCentavos: j['grossAmount'] as int,
        commitmentRef: j['commitmentRef'] as String,
        date: _parseDate(j['date']),
        photo: _parseBytes(j['photo']),
      );

  // --- cash / receipts / logs -------------------------------------------------

  static Map<String, dynamic> cashEntry(CashEntry e) => {
        'id': e.id,
        'branch': e.branch.name,
        'type': e.type.name,
        'account': e.account.name,
        'amount': e.amountCentavos,
        'note': e.note,
        'category': e.category,
        'date': _date(e.date),
        'recordedByRole': e.recordedByRole.name,
        'recordedBy': e.recordedByUserId,
        'source': e.sourceType.name,
        'linkedRecordId': e.linkedRecordId,
        'transferPairId': e.transferPairId,
      };

  static CashEntry parseCashEntry(Map<String, dynamic> j) => CashEntry(
        id: j['id'] as String,
        branch: _enum(BranchId.values, j['branch']),
        type: _enum(CashEntryType.values, j['type']),
        account: _enumOrNull(CashAccount.values, j['account']) ?? CashAccount.purchase,
        amountCentavos: j['amount'] as int,
        note: j['note'] as String,
        category: j['category'] as String?,
        date: _parseDate(j['date']),
        recordedByRole: AppUserRole.parse(j['recordedByRole'] as String?),
        recordedByUserId: j['recordedBy'] as String?,
        sourceType: _enum(CashEntrySourceType.values, j['source']),
        linkedRecordId: j['linkedRecordId'] as String?,
        transferPairId: j['transferPairId'] as String?,
      );

  static Map<String, dynamic> receipt(StoredReceipt r) => {
        'id': r.id,
        'recordId': r.recordId,
        'kind': r.kind.name,
        'branch': r.branch.name,
        'counterparty': r.counterparty,
        'total': r.totalCentavos,
        'issuedAt': _date(r.issuedAt),
        'bytes': _bytes(r.bytes),
        'text': r.text,
      };

  static StoredReceipt parseReceipt(Map<String, dynamic> j) => StoredReceipt(
        id: j['id'] as String,
        recordId: j['recordId'] as String,
        kind: _enum(ReceiptKind.values, j['kind']),
        branch: _enum(BranchId.values, j['branch']),
        counterparty: j['counterparty'] as String,
        totalCentavos: j['total'] as int,
        issuedAt: _parseDate(j['issuedAt']),
        bytes: _parseBytes(j['bytes'])!,
        text: (j['text'] as String?) ?? '',
      );

  static Map<String, dynamic> log(TransactionLog l) => {
        'id': l.id,
        'at': _date(l.at),
        'action': l.action.name,
        'userId': l.userId,
        'userName': l.userName,
        'role': l.role.name,
        'summary': l.summary,
        'branch': l.branch?.name,
        'recordId': l.recordId,
        'recordKind': l.recordKind?.name,
        'amount': l.amountCentavos,
        'changes': [
          for (final c in l.changes) {'field': c.field, 'before': c.before, 'after': c.after},
        ],
      };

  static TransactionLog parseLog(Map<String, dynamic> j) => TransactionLog(
        id: j['id'] as String,
        at: _parseDate(j['at']),
        action: _enum(LogAction.values, j['action']),
        userId: j['userId'] as String?,
        userName: j['userName'] as String,
        role: AppUserRole.parse(j['role'] as String?),
        summary: j['summary'] as String,
        branch: _enumOrNull(BranchId.values, j['branch']),
        recordId: j['recordId'] as String?,
        recordKind: _enumOrNull(LogRecordKind.values, j['recordKind']),
        amountCentavos: j['amount'] as int?,
        changes: [
          for (final raw in (j['changes'] as List? ?? const []))
            FieldChange(
              field: (raw as Map)['field'] as String,
              before: raw['before'] as String,
              after: raw['after'] as String,
            ),
        ],
      );
}
