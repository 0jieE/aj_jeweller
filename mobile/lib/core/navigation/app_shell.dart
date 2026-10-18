import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../features/dashboard/dashboard_screen.dart';
import '../../features/more/more_screen.dart';
import '../../features/purchase/purchase_screen.dart';
import '../../features/scrap/scrap_screen.dart';
import '../../features/sell/sell_screen.dart';
import '../theme/app_colors.dart';
import 'layout.dart';
import 'session_switchers.dart';

/// The four counter workflows plus "More".
///
/// On a phone each tab is the whole window and opening a record covers it,
/// which is right for one hand and one thing at a time.
///
/// On a desktop the frame stays put: the title bar, the branch, who is signed
/// in and the sync state never move, and a record opens *inside* the content
/// pane rather than replacing the window. Each tab keeps its own history, so
/// leaving Purchase half-way through a lot and coming back finds it where it
/// was — the way a desk works, not the way a phone does.
///
/// There is deliberately no drawer: every destination is either a tab or a
/// tile on the More page, so nothing is behind an edge swipe.
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  /// Opens [screen] in the pane the person is looking at, rather than over
  /// the whole window — used when something outside the shell, a tapped
  /// notification, wants to show a record.
  static void openDetail(BuildContext context, Widget screen) {
    final shell = context.findAncestorStateOfType<_AppShellState>() ?? _current;
    final navigator = shell?._navigatorFor(shell._index)?.currentState;
    if (navigator != null) {
      navigator.push(MaterialPageRoute(builder: (_) => screen));
      return;
    }
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (_) => screen));
  }

  static _AppShellState? _current;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;

  /// One history per tab, so each remembers where it was left.
  final _navigators = List.generate(5, (_) => GlobalKey<NavigatorState>());

  GlobalKey<NavigatorState>? _navigatorFor(int index) =>
      index >= 0 && index < _navigators.length ? _navigators[index] : null;

  static const _tabs = [
    _TabDefinition(
      'Dashboard',
      Icons.space_dashboard_outlined,
      Icons.space_dashboard_rounded,
    ),
    _TabDefinition(
      'Purchase',
      Icons.add_shopping_cart_outlined,
      Icons.add_shopping_cart_rounded,
    ),
    _TabDefinition('Sell', Icons.storefront_outlined, Icons.storefront_rounded),
    _TabDefinition(
      'Dispose',
      Icons.delete_sweep_outlined,
      Icons.delete_sweep_rounded,
    ),
    _TabDefinition('More', Icons.grid_view_outlined, Icons.grid_view_rounded),
  ];

  @override
  void initState() {
    super.initState();
    AppShell._current = this;
  }

  @override
  void dispose() {
    if (AppShell._current == this) AppShell._current = null;
    super.dispose();
  }

  void _select(int index) {
    // Tapping the tab you are already on goes back to the top of it, the way
    // every tabbed app behaves.
    if (index == _index) {
      _navigatorFor(index)?.currentState?.popUntil((route) => route.isFirst);
      return;
    }
    setState(() => _index = index);
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      DashboardScreen(onNavigateToTab: _select),
      const PurchaseScreen(),
      const SellScreen(),
      const ScrapScreen(),
      const MoreScreen(),
    ];

    // A phone carries its navigation along the bottom, where a thumb is. A
    // desktop window has height to spare and a pointer, so it goes down the
    // side and the labels stay visible.
    final size = WindowSize.of(context);
    final keepsFrame = !size.usesBottomBar;

    final body = IndexedStack(
      index: _index,
      children: [
        for (var i = 0; i < screens.length; i++)
          keepsFrame
              ? _TabPane(navigatorKey: _navigators[i], child: screens[i])
              : screens[i],
      ],
    );

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
                  onSelected: _select,
                ),
                const VerticalDivider(width: 1, thickness: 1),
                Expanded(child: body),
              ],
            ),
      bottomNavigationBar: size.usesBottomBar
          ? NavigationBar(
              selectedIndex: _index,
              onDestinationSelected: _select,
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

/// One tab's content, with its own history inside the pane.
///
/// Every `Navigator.of(context).push` from a screen in here lands on this
/// navigator rather than the window's, which is the whole point: the frame
/// around it does not flicker, and the person does not lose the branch they
/// were looking at. Nothing at the call sites had to change.
class _TabPane extends StatelessWidget {
  final GlobalKey<NavigatorState> navigatorKey;
  final Widget child;

  const _TabPane({required this.navigatorKey, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Around the Navigator, not inside a route: every screen opened in this
    // pane inherits it, including the ones pushed from inside those screens.
    // A screen in here keeps its own toolbar — the title, the back arrow,
    // its actions — but wears it lightly, because one heavy blue bar at the
    // top of the window is a frame and two is a mistake.
    return Theme(
      data: theme.copyWith(
        appBarTheme: theme.appBarTheme.copyWith(
          backgroundColor: AppColors.cardSurface,
          foregroundColor: AppColors.textPrimary,
          surfaceTintColor: Colors.transparent,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: const Border(bottom: BorderSide(color: AppColors.outline)),
          titleTextStyle: theme.textTheme.titleLarge?.copyWith(
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w700,
          ),
          iconTheme: const IconThemeData(color: AppColors.textPrimary),
          actionsIconTheme: const IconThemeData(color: AppColors.textSecondary),
        ),
        tabBarTheme: theme.tabBarTheme.copyWith(
          labelColor: AppColors.primaryBlue,
          unselectedLabelColor: AppColors.textSecondary,
          indicatorColor: AppColors.primaryBlue,
        ),
      ),
      // Escape goes back, the way it does in every desktop window. On a
      // phone the system's own back gesture does this and there is no key
      // to press.
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              navigatorKey.currentState?.maybePop(),
        },
        child: Focus(
          autofocus: true,
          canRequestFocus: false,
          skipTraversal: true,
          child: NavigatorPopHandler(
            onPopWithResult: (_) => navigatorKey.currentState?.maybePop(),
            child: Navigator(
              key: navigatorKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                settings: settings,
                builder: (_) => child,
              ),
            ),
          ),
        ),
      ),
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
