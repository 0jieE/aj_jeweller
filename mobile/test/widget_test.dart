// Smoke test: the app boots into the shell with all five bottom tabs, the
// Dashboard visible by default, and the role/branch switchers in the app bar.

import 'package:flutter_test/flutter_test.dart';

import 'package:davao_aj_jewellers/main.dart';

void main() {
  testWidgets('App boots to Dashboard with five bottom tabs', (WidgetTester tester) async {
    await tester.pumpWidget(const AjJewelerApp());
    await tester.pumpAndSettle();

    expect(find.text('Dashboard'), findsWidgets);
    expect(find.text('Purchase'), findsOneWidget);
    expect(find.text('Sell'), findsOneWidget);
    expect(find.text('Dispose'), findsOneWidget);
    expect(find.text('More'), findsOneWidget);

    // Role and branch switched from the app bar, not a drawer. The branch
    // name also labels the Dashboard's position card, hence findsWidgets.
    expect(find.text('Admin'), findsOneWidget);
    expect(find.text('Kidapawan'), findsWidgets);

    // Sell lists gold and silver separately, then Sold, with the Cashier's
    // Verify queue role-gated on.
    await tester.tap(find.text('Sell'));
    await tester.pumpAndSettle();
    expect(find.text('Gold'), findsOneWidget);
    expect(find.text('Silver'), findsWidgets);
    expect(find.text('Sold'), findsOneWidget);

    // The Dispose tab: gold scrap, silver, and past batches.
    await tester.tap(find.text('Dispose'));
    await tester.pumpAndSettle();
    expect(find.text('Gold'), findsOneWidget);
    expect(find.text('History'), findsOneWidget);

    // The More page replaces the old drawer — same destinations, as a grid.
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(find.text('Cash'), findsOneWidget);
    // Commitments moved off the bottom bar onto this page.
    expect(find.text('Commitments'), findsOneWidget);
    // Reference and demo-data tiles sit below the fold at the default test
    // viewport; what they actually do is covered by the repository tests.
  });
}
