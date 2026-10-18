import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_repository.dart';
import '../models/customer.dart';
import '../services/item_photo_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// A customer's face where there is one, their initials where there isn't.
///
/// Tapping a photo opens it full-size — a 40px circle is enough to jog a
/// memory, not enough to be sure it's the same person handing over the gold.
class CustomerAvatar extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final double radius;
  final bool enlargeOnTap;

  const CustomerAvatar({
    super.key,
    required this.name,
    this.photo,
    this.radius = 20,
    this.enlargeOnTap = true,
  });

  @override
  Widget build(BuildContext context) {
    final avatar = CircleAvatar(
      radius: radius,
      backgroundColor: AppColors.primaryBlue.withValues(alpha: 0.12),
      backgroundImage: photo == null ? null : MemoryImage(photo!),
      child: photo != null
          ? null
          : Text(
              initials(name),
              style: AppTextStyles.labelSmall.copyWith(
                color: AppColors.primaryBlue,
                fontWeight: FontWeight.w700,
                fontSize: (radius * 0.62).clamp(10, 28).toDouble(),
              ),
            ),
    );
    if (photo == null || !enlargeOnTap) return avatar;
    return GestureDetector(
      onTap: () => showCustomerPhoto(context, name: name, photo: photo!),
      child: avatar,
    );
  }

  static String initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.characters.first.toUpperCase();
    return (parts.first.characters.first + parts.last.characters.first).toUpperCase();
  }
}

/// The avatar for the customer written on a transaction.
///
/// The photo is read from the live customer record rather than the
/// transaction's copy, so a photo taken on a later visit shows on every
/// earlier record of the same person too.
class TransactionCustomerAvatar extends StatelessWidget {
  final CustomerDetails customer;
  final double radius;

  const TransactionCustomerAvatar({super.key, required this.customer, this.radius = 20});

  @override
  Widget build(BuildContext context) {
    final record = context.watch<AppRepository>().customerFor(customer);
    return CustomerAvatar(name: customer.name, photo: record?.photo, radius: radius);
  }
}

Future<void> showCustomerPhoto(
  BuildContext context, {
  required String name,
  required Uint8List photo,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      insetPadding: const EdgeInsets.all(AppSpacing.md),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Text(name, style: AppTextStyles.titleMedium),
          ),
          Flexible(child: InteractiveViewer(child: Image.memory(photo))),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    ),
  );
}

/// Asks where the customer's photo should come from and returns it, or null
/// if the person backed out. Failures are reported, not thrown — a camera
/// problem must never block the transaction the photo is attached to.
Future<Uint8List?> pickCustomerPhoto(BuildContext context) async {
  final source = await showModalBottomSheet<bool>(
    context: context,
    builder: (sheetContext) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.photo_camera_outlined),
            title: const Text('Take photo'),
            onTap: () => Navigator.of(sheetContext).pop(false),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Choose from gallery'),
            onTap: () => Navigator.of(sheetContext).pop(true),
          ),
        ],
      ),
    ),
  );
  if (source == null || !context.mounted) return null;

  final messenger = ScaffoldMessenger.of(context);
  try {
    return source ? await ItemPhotoService.pickFromGallery() : await ItemPhotoService.capture();
  } catch (error) {
    messenger.showSnackBar(SnackBar(content: Text('Could not get a photo: $error')));
    return null;
  }
}
