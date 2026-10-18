import 'dart:typed_data';

import 'package:image_picker/image_picker.dart';

/// Takes the photo of a physical piece that gets filed with its record.
///
/// Whoever is holding the item photographs it — an Appraiser encoding a
/// purchase, a Sales Rep sending a piece out — and the Cashier who later
/// verifies that record checks the description and weight against the photo
/// rather than against nothing.
class ItemPhotoService {
  ItemPhotoService._();

  static final ImagePicker _picker = ImagePicker();

  /// Opens the camera. Returns null if the user backs out.
  static Future<Uint8List?> capture() => _pick(ImageSource.camera);

  /// Falls back to the gallery — a counter tablet without a usable camera, or
  /// a photo already taken on a phone, still has to be able to file one.
  static Future<Uint8List?> pickFromGallery() => _pick(ImageSource.gallery);

  static Future<Uint8List?> _pick(ImageSource source) async {
    final file = await _picker.pickImage(
      source: source,
      // Downscaled hard: these are held in memory in this prototype, and a
      // full-resolution phone photo per item would be untenable. Still far
      // more than enough to check a piece against its description.
      maxWidth: 1280,
      maxHeight: 1280,
      imageQuality: 70,
    );
    if (file == null) return null;
    return file.readAsBytes();
  }
}
