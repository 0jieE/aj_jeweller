import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../core/data/app_repository.dart';
import '../../core/models/customer.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_text_styles.dart';
import '../../core/widgets/customer_avatar.dart';
import '../../core/widgets/empty_state.dart';
import '../../core/widgets/formatters.dart';
import '../../core/widgets/search_field.dart';
import 'customer_detail_screen.dart';
import '../../core/navigation/layout.dart';

/// The customer book: everyone the shop has dealt with, on either side of the
/// counter.
///
/// Deliberately not branch-filtered — a customer belongs to the business, not
/// to the branch that happened to serve them first, and the whole point of
/// keeping them as records is answering "what have we done with this person?"
/// wherever it was done.
class CustomersScreen extends StatefulWidget {
  const CustomersScreen({super.key});

  @override
  State<CustomersScreen> createState() => _CustomersScreenState();
}

class _CustomersScreenState extends State<CustomersScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<AppRepository>();

    final q = _query.trim();
    final customers = q.isEmpty
        ? repo.customers
        : repo.searchCustomers(q, limit: 100);

    return Scaffold(
      appBar: AppBar(title: const Text('Customers')),
      body: ReadableWidth(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: SearchField(
                hintText: 'Search customers by name or number',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            Expanded(
              child: customers.isEmpty
                  ? EmptyState(
                      icon: Icons.people_outline_rounded,
                      title: q.isEmpty ? 'No customers yet' : 'No customers match this search',
                      message: q.isEmpty
                          ? 'Anyone recorded on a purchase or a sale is filed here automatically.'
                          : null,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                      itemCount: customers.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) {
                        final customer = customers[i];
                        return _CustomerTile(
                          customer: customer,
                          purchaseCount: repo.purchasesByCustomer(customer.id).length,
                          saleCount: repo.salesByCustomer(customer.id).length,
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomerTile extends StatelessWidget {
  final Customer customer;
  final int purchaseCount;
  final int saleCount;

  const _CustomerTile({
    required this.customer,
    required this.purchaseCount,
    required this.saleCount,
  });

  @override
  Widget build(BuildContext context) {
    final total = purchaseCount + saleCount;
    final subtitle = [
      if (customer.contactNumber != null) customer.contactNumber!,
      if (customer.address != null) customer.address!,
    ].join(' · ');

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => CustomerDetailScreen(customerId: customer.id),
        ),
      ),
      leading: CustomerAvatar(name: customer.name, photo: customer.photo, radius: 22),
      title: Text(
        customer.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyLarge.copyWith(fontWeight: FontWeight.w600),
      ),
      subtitle: Text(
        subtitle.isEmpty ? 'Since ${AppFormat.dateShort(customer.firstSeen)}' : subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: AppTextStyles.bodyMedium.copyWith(color: AppColors.textSecondary),
      ),
      trailing: Text(
        '$total txn',
        style: AppTextStyles.numericSmall.copyWith(color: AppColors.textSecondary),
      ),
    );
  }
}
