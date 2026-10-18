import 'dart:typed_data';

/// Stand-in for the photo a Cashier takes of the cash changing hands. The
/// repository refuses a release or a loan receipt without one, exactly as the
/// server does, so tests that only care about the money pass this.
final Uint8List proofPhoto = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);
