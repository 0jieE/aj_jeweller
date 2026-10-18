import 'package:flutter/material.dart';

import '../../features/dashboard/dashboard_screen.dart';
import '../../features/more/more_screen.dart';
import '../../features/purchase/purchase_screen.dart';
import '../../features/scrap/scrap_screen.dart';
import '../../features/sell/sell_screen.dart';
import 'layout.dart';
import 'session_switchers.dart';

/// The four counter workflows plus "More", all reachable from the bottom
/// navigation bar. Commitments live on the More page instead — they are an
/// Admin's weekly concern, not something touched between customers.
///
/// There is deliberately no drawer: every destination is either a tab or a
/// tile on the More page, and the role/branch switchers sit in the app bar —
/// so nothing in this app is behind an edge swipe.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  static const _tabs = [
    _TabDefinition('Dashboard', Icons.space_dashboard_outlined, Icons.space_dashboard_rounded),
    _TabDefinition('Purchase', Icons.add_shopping_cart_outlined, Icons.add_shopping_cart_rounded),
    _TabDefinition('Sell', Icons.storefront_outlined, Icons.storefront_rounded),
    _TabDefinition('Dispose', Icons.delete_sweep_outlined, Icons.delete_sweep_rounded),
    _TabDefinition('More', Icons.grid_view_outlined, Icons.grid_view_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final screens = [
      DashboardScreen(onNavigateToTab: (i) => setState(() => _index = i)),
      const PurchaseScreen(),
      const SellScreen(),
      const ScrapScreen(),
      const MoreScreen(),
    ];

    // A phone carries its navigation along the bottom, where a thumb is. A
    // desktop window has height to spare and a pointer, so it goes down the
    // side and the labels stay visible.
    final size = WindowSize.of(context);
    final body = IndexedStack(index: _index, children: screens);

    return Scaffold(
      appBar: AppBar(
        // The title gives way to the switchers on a narrow phone; the bottom
        // bar already says which tab is open, so the label is the redundant
        // half of this row.
        title: Text(_tabs[_index].label, overflow: TextOverflow.ellipsis),
        titleSpacing: 16,
        actions: const [SessionSwitchers()],
      ),
      body: size.usesBottomBar
          ? body
          : Row(
              children: [
                _SideNavigation(
                  tabs: _tabs,
                  index: _index,
                  extended: size == WindowSize.expanded,
                  onSelected: (i) => setState(() => _index = i),
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: body),
              ],
            ),
      bottomNavigationBar: size.usesBottomBar
          ? NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              destinations: [
                for (final tab in _tabs)
                  NavigationDestination(
                    icon: Icon(tab.icon),
                    selectedIcon: Icon(tab.selectedIcon),
                    label: tab.label,
                  ),
              ],
            )
          : null,
    );
  }
}

/// The desktop's navigation: down the left, labelled, and wide enough to read
/// at a glance from across a desk.
class _SideNavigation extends StatelessWidget {
  final List<_TabDefinition> tabs;
  final int index;
  final bool extended;
  final ValueChanged<int> onSelected;

  const _SideNavigation({
    required this.tabs,
    required this.index,
    required this.extended,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return NavigationRail(
      selectedIndex: index,
      onDestinationSelected: onSelected,
      extended: extended,
      minExtendedWidth: 184,
      labelType: extended ? null : NavigationRailLabelType.all,
      destinations: [
        for (final tab in tabs)
          NavigationRailDestination(
            icon: Icon(tab.icon),
            selectedIcon: Icon(tab.selectedIcon),
            label: Text(tab.label),
          ),
      ],
    );
  }
}

class _TabDefinition {
  final String label;
  final IconData icon;
  final IconData selectedIcon;

  const _TabDefinition(this.label, this.icon, this.selectedIcon);
}
