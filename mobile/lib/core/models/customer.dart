import 'dart:typed_data';

/// Someone the shop deals with, kept as a record in their own right rather
/// than as text copied onto each transaction.
///
/// A gold shop's customers come back — the same person sells scrap in March
/// and buys a ring in December — so their contact details belong in one place
/// that both sides of the counter can reach, and their history has to be
/// answerable from the person rather than from the pile of transactions.
class Customer {
  final String id;
  final String name;
  final String? contactNumber;
  final String? address;

  /// When this customer was first recorded — their history starts here.
  final DateTime firstSeen;

  /// A photo of the person, so staff can recognise a regular at the counter
  /// and match a face to a name before handing over cash for their gold.
  final Uint8List? photo;

  const Customer({
    required this.id,
    required this.name,
    this.contactNumber,
    this.address,
    required this.firstSeen,
    this.photo,
  });

  bool get hasPhoto => photo != null;

  /// Matching key for "is this the same person?". Names get typed with
  /// inconsistent spacing and casing at a counter, and treating those as
  /// different people is how one customer becomes five database rows.
  static String matchKey(String name) =>
      name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  String get key => matchKey(name);

  Customer copyWith({
    String? name,
    String? contactNumber,
    String? address,
    Uint8List? photo,
  }) {
    return Customer(
      id: id,
      name: name ?? this.name,
      contactNumber: contactNumber ?? this.contactNumber,
      address: address ?? this.address,
      firstSeen: firstSeen,
      photo: photo ?? this.photo,
    );
  }
}

/// The customer as written onto one transaction.
///
/// Deliberately a copy, not a pointer: a receipt has to keep saying what it
/// said the day it was issued, even if the customer later corrects their
/// address. [customerId] links back to the live record for history.
class CustomerDetails {
  final String name;
  final String? contactNumber;
  final String? address;

  /// The [Customer] this was recorded against, when there is one.
  final String? customerId;

  /// A newly taken photo, carried from the form to the customer record.
  ///
  /// Unlike the name and contact, a photo is not frozen onto the transaction:
  /// it identifies the person, so screens always show the record's current
  /// photo rather than whatever was on file the day of the sale.
  final Uint8List? photo;

  const CustomerDetails({
    required this.name,
    this.contactNumber,
    this.address,
    this.customerId,
    this.photo,
  });

  /// Linked to the saved record. The photo is dropped here on purpose — once
  /// filed on the [Customer], it is read from there.
  CustomerDetails withId(String id) => CustomerDetails(
        name: name,
        contactNumber: contactNumber,
        address: address,
        customerId: id,
      );
}
