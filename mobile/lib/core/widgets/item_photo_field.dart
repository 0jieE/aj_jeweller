import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../services/item_photo_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

/// Capture control for a piece's photo: take one, retake it, or drop it.
///
/// Optional by design — a counter queue shouldn't stall because a camera is
/// being slow — but prominent, because a record the Cashier can't see the
/// goods for is the one they have to take on trust.
class ItemPhotoField extends StatelessWidget {
  final Uint8List? photo;
  final ValueChanged<Uint8List?> onChanged;
  final String label;

  /// Shown beside a taken photo — says who will look at it and why.
  final String caption;

  const ItemPhotoField({
    super.key,
    required this.photo,
    required this.onChanged,
    this.label = 'Item photo',
    this.caption = 'Filed with this item — the Cashier sees it when verifying.',
  });

  Future<void> _capture(BuildContext context, {required bool fromGallery}) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final bytes = fromGallery
          ? await ItemPhotoService.pickFromGallery()
          : await ItemPhotoService.capture();
      if (bytes != null) onChanged(bytes);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not get a photo: $error')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
        ),
        const SizedBox(height: 6),
        if (photo == null)
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _capture(context, fromGallery: false),
                  icon: const Icon(Icons.photo_camera_outlined, size: 18),
                  label: const Text('Take photo'),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              IconButton(
                onPressed: () => _capture(context, fromGallery: true),
                icon: const Icon(Icons.photo_library_outlined),
                tooltip: 'Choose an existing photo',
              ),
            ],
          )
        else
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
                child: Image.memory(
                  photo!,
                  width: 96,
                  height: 96,
                  fit: BoxFit.cover,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      caption,
                      style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Wrap(
                      spacing: AppSpacing.sm,
                      children: [
                        TextButton.icon(
                          onPressed: () => _capture(context, fromGallery: false),
                          icon: const Icon(Icons.refresh_rounded, size: 16),
                          label: const Text('Retake'),
                        ),
                        TextButton.icon(
                          onPressed: () => onChanged(null),
                          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                          icon: const Icon(Icons.close_rounded, size: 16),
                          label: const Text('Remove'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

/// The filed photo as the Cashier sees it while verifying — a thumbnail that
/// opens full-screen, since judging a piece from a 56px square is no check at
/// all.
class ItemPhotoThumbnail extends StatelessWidget {
  final Uint8List photo;
  final String label;
  final double size;

  const ItemPhotoThumbnail({
    super.key,
    required this.photo,
    required this.label,
    this.size = 56,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (dialogContext) => Dialog(
          insetPadding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Text(label, style: AppTextStyles.titleMedium),
              ),
              Flexible(child: InteractiveViewer(child: Image.memory(photo))),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppSpacing.badgeRadius),
        child: Image.memory(photo, width: size, height: size, fit: BoxFit.cover),
      ),
    );
  }
}
