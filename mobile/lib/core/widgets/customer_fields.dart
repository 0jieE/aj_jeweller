import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/app_repository.dart';
import '../models/customer.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';
import 'customer_avatar.dart';

/// Name, contact, and address for whoever is on the other side of a
/// transaction, with the customer book behind the name field.
///
/// Typing a name offers the people already on file and fills in the rest on
/// selection — regulars are the common case in this shop, and re-keying a
/// number every visit is both slow and the main way one person ends up as
/// three records.
class CustomerFields extends StatefulWidget {
  final CustomerDetails initial;
  final ValueChanged<CustomerDetails> onChanged;

  /// Shown under the name field; the rest are always optional.
  final String nameHint;

  const CustomerFields({
    super.key,
    required this.initial,
    required this.onChanged,
    this.nameHint = 'Required',
  });

  @override
  State<CustomerFields> createState() => _CustomerFieldsState();
}

class _CustomerFieldsState extends State<CustomerFields> {
  late final TextEditingController _name;
  late final TextEditingController _contact;
  late final TextEditingController _address;
  final _nameFocus = FocusNode();

  /// Set once a suggestion is taken, so the transaction links to that record
  /// rather than matching loosely on the name later.
  String? _customerId;

  /// Suppresses the dropdown right after a pick, which would otherwise
  /// reappear because filling the field counts as typing.
  bool _justPicked = false;

  /// A photo taken during this transaction. The one already on file for a
  /// linked customer is read from their record, not copied here — only a
  /// new photo travels with the form.
  Uint8List? _newPhoto;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.initial.name);
    _contact = TextEditingController(text: widget.initial.contactNumber ?? '');
    _address = TextEditingController(text: widget.initial.address ?? '');
    _customerId = widget.initial.customerId;
    _newPhoto = widget.initial.photo;
    _nameFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _contact.dispose();
    _address.dispose();
    _nameFocus.dispose();
    super.dispose();
  }

  void _emit() {
    widget.onChanged(CustomerDetails(
      name: _name.text,
      contactNumber: _contact.text.trim().isEmpty ? null : _contact.text.trim(),
      address: _address.text.trim().isEmpty ? null : _address.text.trim(),
      customerId: _customerId,
      photo: _newPhoto,
    ));
  }

  void _pick(Customer customer) {
    setState(() {
      _justPicked = true;
      _customerId = customer.id;
      _name.text = customer.name;
      _contact.text = customer.contactNumber ?? '';
      _address.text = customer.address ?? '';
    });
    _nameFocus.unfocus();
    _emit();
  }

  Future<void> _takePhoto() async {
    final photo = await pickCustomerPhoto(context);
    if (photo == null || !mounted) return;
    setState(() => _newPhoto = photo);
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();
    final matches = (_justPicked || !_nameFocus.hasFocus)
        ? const <Customer>[]
        : repo.searchCustomers(_name.text);
    final filedPhoto = _customerId == null ? null : repo.findCustomer(_customerId!)?.photo;
    final shownPhoto = _newPhoto ?? filedPhoto;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PhotoRow(
          name: _name.text,
          photo: shownPhoto,
          caption: _newPhoto != null
              ? (filedPhoto != null
                  ? 'New photo — replaces the one on file when saved.'
                  : 'New photo — filed with the customer when saved.')
              : filedPhoto != null
                  ? 'Photo on file for this customer.'
                  : 'No photo yet. Optional, but it helps staff recognise regulars.',
          actionLabel: shownPhoto == null ? 'Take photo' : 'Change photo',
          onTake: _takePhoto,
          onRemove: _newPhoto == null
              ? null
              : () {
                  setState(() => _newPhoto = null);
                  _emit();
                },
        ),
        const SizedBox(height: AppSpacing.md),
        TextField(
          controller: _name,
          focusNode: _nameFocus,
          decoration: InputDecoration(
            labelText: 'Name',
            hintText: widget.nameHint,
            prefixIcon: const Icon(Icons.person_outline_rounded),
          ),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) {
            // Editing the name after picking means this may be someone else,
            // so the link is dropped until a suggestion is taken again.
            _justPicked = false;
            _customerId = null;
            setState(() {});
            _emit();
          },
        ),
        if (matches.isNotEmpty)
          Container(
            margin: const EdgeInsets.only(top: 2),
            decoration: BoxDecoration(
              color: AppColors.cardSurface,
              borderRadius: BorderRadius.circular(AppSpacing.inputRadius),
              border: Border.all(color: AppColors.outline),
            ),
            child: Column(
              children: [
                for (final customer in matches)
                  ListTile(
                    dense: true,
                    leading: CustomerAvatar(
                      name: customer.name,
                      photo: customer.photo,
                      radius: 16,
                      enlargeOnTap: false,
                    ),
                    title: Text(
                      customer.name,
                      style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      [customer.contactNumber, customer.address]
                              .whereType<String>()
                              .join(' · ')
                              .trim()
                              .isEmpty
                          ? 'On file'
                          : [customer.contactNumber, customer.address]
                              .whereType<String>()
                              .join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
                    ),
                    onTap: () => _pick(customer),
                  ),
              ],
            ),
          ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _contact,
          decoration: const InputDecoration(
            labelText: 'Contact number',
            hintText: 'Optional',
            prefixIcon: Icon(Icons.phone_outlined),
          ),
          keyboardType: TextInputType.phone,
          onChanged: (_) => _emit(),
        ),
        const SizedBox(height: AppSpacing.sm),
        TextField(
          controller: _address,
          decoration: const InputDecoration(
            labelText: 'Address',
            hintText: 'Optional',
            prefixIcon: Icon(Icons.home_outlined),
          ),
          textCapitalization: TextCapitalization.words,
          onChanged: (_) => _emit(),
        ),
        if (_customerId != null) ...[
          const SizedBox(height: AppSpacing.xs),
          Row(
            children: [
              Icon(Icons.link_rounded, size: 14, color: context.semanticColors.success),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  'Linked to an existing customer — this transaction joins their history.',
                  style: AppTextStyles.caption.copyWith(color: context.semanticColors.success),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _PhotoRow extends StatelessWidget {
  final String name;
  final Uint8List? photo;
  final String caption;
  final String actionLabel;
  final VoidCallback onTake;
  final VoidCallback? onRemove;

  const _PhotoRow({
    required this.name,
    required this.photo,
    required this.caption,
    required this.actionLabel,
    required this.onTake,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CustomerAvatar(name: name, photo: photo, radius: 32),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Customer photo',
                style: AppTextStyles.labelSmall.copyWith(color: AppColors.textSecondary),
              ),
              const SizedBox(height: 2),
              Text(
                caption,
                style: AppTextStyles.caption.copyWith(color: AppColors.textSecondary),
              ),
              Wrap(
                spacing: AppSpacing.xs,
                children: [
                  TextButton.icon(
                    onPressed: onTake,
                    icon: const Icon(Icons.photo_camera_outlined, size: 16),
                    label: Text(actionLabel),
                  ),
                  if (onRemove != null)
                    TextButton.icon(
                      onPressed: onRemove,
                      style: TextButton.styleFrom(foregroundColor: AppColors.danger),
                      icon: const Icon(Icons.close_rounded, size: 16),
                      label: const Text('Discard'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
