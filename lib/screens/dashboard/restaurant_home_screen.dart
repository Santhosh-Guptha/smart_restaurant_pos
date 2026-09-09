import '../../providers/dashboard_layout_provider.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import '../../core/classic_theme.dart';
import '../../core/license_guard.dart';
import '../../providers/auth_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/restaurant_sheets_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../widgets/google_sheets_setup_gate_dialog.dart';

import '../counter_billing/fast_qsr_billing_screen.dart';
import '../restaurant/table_management_screen.dart';
import '../kitchen/kitchen_display_screen.dart';
import '../restaurant/restaurant_menu_management_screen.dart';
import '../restaurant/branch_management_screen.dart';
import '../settings/staff_management_screen.dart';
import '../restaurant/store_configuration_screen.dart';
import '../settings/settings_sidebar_dialog.dart';
import '../analytics/restaurant_analytics_screen.dart';
import '../orders/restaurant_order_history_screen.dart';
import '../../core/rbac_permissions.dart';

class RestaurantHomeScreen extends ConsumerStatefulWidget {
  const RestaurantHomeScreen({super.key});

  @override
  ConsumerState<RestaurantHomeScreen> createState() => _RestaurantHomeScreenState();
}

class _RestaurantHomeScreenState extends ConsumerState<RestaurantHomeScreen> {
  bool _isCheckingSheets = false;
  bool? _sheetAccessVerified;
  String _sheetCheckMessage = '';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await GoogleSheetsSetupGateDialog.showIfRequired(context, ref);
      if (mounted) {
        _checkGoogleSheetsAccess();
      }
    });
  }

  Future<void> _checkGoogleSheetsAccess() async {
    final saasSession = ref.read(saasSessionProvider);
    final user = saasSession.currentUser;
    final org = saasSession.currentOrganization;
    final orgId = user?.organizationId ?? org?.id ?? 'ORG_DEFAULT';

    // Owners have implicit access once Google Sign-In is active
    final role = user?.role.toUpperCase() ?? 'OWNER';
    if (role == 'OWNER' || role == 'MASTER_ADMIN') {
      setState(() {
        _sheetAccessVerified = true;
        _sheetCheckMessage = 'Owner Master Database Active';
      });
      return;
    }

    // For staff users: verify sheet access via Google Drive API
    setState(() {
      _isCheckingSheets = true;
      _sheetCheckMessage = 'Verifying store sheet access...';
    });

    try {
      final authNotifier = ref.read(restaurantAuthProvider.notifier);
      // Attempt silent sign-in first if needed
      await authNotifier.signInSilently();
      final http.Client? client = authNotifier.authenticatedHttpClient ??
          await ClientLedgerCloudRouterService.getAuthenticatedClientIfAvailable();

      final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      String? sheetId = box?.get('restaurant_sheet_id_$orgId') ?? box?.get('google_sheet_id');

      if (sheetId == null || sheetId.isEmpty) {
        // Fetch from Firestore
        final doc = await FirebaseFirestore.instance.collection('organizations').doc(orgId).get();
        sheetId = doc.data()?['googleSheetId']?.toString() ?? doc.data()?['spreadsheetId']?.toString();
      }

      if (client != null && sheetId != null && sheetId.isNotEmpty) {
        final result = await RestaurantSheetsService.verifyUserSheetAccess(
          authenticatedClient: client,
          spreadsheetId: sheetId,
        );

        if (mounted) {
          setState(() {
            _isCheckingSheets = false;
            _sheetAccessVerified = result || (sheetId != null && sheetId.isNotEmpty);
            _sheetCheckMessage = result
                ? 'Google Sheet Access Verified'
                : 'Google Sheet Connected (Cloud Webhook Active)';
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _isCheckingSheets = false;
            _sheetAccessVerified = client != null || (sheetId != null && sheetId.isNotEmpty);
            _sheetCheckMessage = client != null
                ? 'Google Account Connected'
                : (sheetId != null && sheetId.isNotEmpty
                    ? 'Google Sheet Connected (Cloud Synced)'
                    : '1-Time Google Authorization Required');
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingSheets = false;
          _sheetAccessVerified = false;
          _sheetCheckMessage = 'Sheet verification: $e';
        });
      }
    }
  }

  Future<void> _authorizeGoogleAccount() async {
    await showDialog(
      context: context,
      builder: (ctx) => const GoogleSheetsSetupGateDialog(),
    );
    await _checkGoogleSheetsAccess();
  }

  void _confirmLogout() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 22),
            const SizedBox(width: 10),
            Text(
              'Confirm Logout',
              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          'Are you sure you want to log out of your workstation? You will need your email & password to log in again.',
          style: TextStyle(color: context.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () async {
              Navigator.pop(ctx);
              await ref.read(restaurantAuthProvider.notifier).signOutGoogle();
              await ref.read(authProvider.notifier).signOut();
            },
            child: const Text('Logout', style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final restaurantAuth = ref.watch(restaurantAuthProvider);
    final activeStaff = restaurantAuth.activeStaff;
    final saasSession = ref.watch(saasSessionProvider);
    final user = saasSession.currentUser;
    final org = saasSession.currentOrganization;

    // Fail-closed role resolution: prefer authenticated activeStaff, fallback to SaaS user, else unassigned
    final StaffRole effectiveRole = activeStaff?.role ??
        (user != null ? StaffRoleExtension.fromKey(user.role) : StaffRole.unassigned);
    final String roleStr = effectiveRole.key;
    final storeName = org?.name ?? org?.appName ?? 'SmartDine Restaurant';

    // Determine role permissions (fail-closed)
    final bool isOwner = effectiveRole == StaffRole.owner;
    final bool isManager = effectiveRole == StaffRole.manager;
    final bool isBilling = effectiveRole == StaffRole.billing;
    final bool isKitchen = effectiveRole == StaffRole.kitchen;
    final bool isWaiter = effectiveRole == StaffRole.waiter;

    // Feature enablement from license plan (backward compatible: defaults to true if empty/legacy)
    final bool featBilling = LicenseGuard.hasFeature(ref, 'qsrBilling', defaultValue: true);
    final bool featTables = LicenseGuard.hasFeature(ref, 'tableManagement', defaultValue: true);
    final bool featKds = LicenseGuard.hasFeature(ref, 'kdsEnabled', defaultValue: true);
    final bool featMenu = LicenseGuard.hasFeature(ref, 'menuManagement', defaultValue: true);
    final bool featOutlets = LicenseGuard.hasFeature(ref, 'multiOutlet', defaultValue: false);
    final bool featStaff = LicenseGuard.hasFeature(ref, 'staffManagement', defaultValue: true);
    final bool featStoreConfig = LicenseGuard.hasFeature(ref, 'storeConfiguration', defaultValue: true);
    final bool featAnalytics = LicenseGuard.hasFeature(ref, 'dayEndReports', defaultValue: true);

    // Permission flags for each card: Role requirement AND License Feature
    final bool canBilling = (isOwner || isManager || isBilling) && featBilling;
    final bool canTables = (isOwner || isManager || isBilling || isWaiter) && featTables;
    final bool canKds = (isOwner || isManager || isKitchen) && featKds;
    final bool canMenu = (isOwner || isManager) && featMenu;
    final bool canOutlets = isOwner && featOutlets;
    final bool canStaff = (isOwner || isManager) && featStaff;
    final bool canStoreConfig = (isOwner || isManager) && featStoreConfig;
    final bool canAnalytics = (isOwner || isManager) && featAnalytics;
    final bool canOrders = isOwner || isManager || isBilling;

    final String roleDisplayName = activeStaff != null
        ? '${activeStaff.name} (${activeStaff.role.displayName})'
        : isOwner
            ? 'Restaurant Owner (Master Admin)'
            : isManager
                ? 'Store Manager'
                : isBilling
                    ? 'Billing & Cashier'
                    : isKitchen
                        ? 'Kitchen Chef (KDS)'
                        : isWaiter
                            ? 'Floor Captain / Waiter'
                            : 'Unassigned Staff';

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        elevation: 0,
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.restaurant_rounded, color: Colors.amber, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    storeName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isOwner ? Colors.amber.withValues(alpha: 0.15) : Colors.cyan.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          roleDisplayName,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isOwner ? Colors.amber.shade900 : Colors.cyan.shade900,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        _sheetAccessVerified == true ? Icons.cloud_done_rounded : Icons.cloud_sync_rounded,
                        size: 13,
                        color: _sheetAccessVerified == true ? const Color(0xFF10B981) : Colors.orangeAccent,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (restaurantAuth.staffList.isNotEmpty)
            IconButton(
              tooltip: 'Lock Terminal / Switch Staff',
              icon: const Icon(Icons.lock_outline_rounded, color: Colors.amber, size: 22),
              onPressed: () {
                ref.read(restaurantAuthProvider.notifier).lockTerminal();
              },
            ),
          IconButton(
            tooltip: 'Store & Hardware Settings',
            icon: Icon(Icons.settings_outlined, color: context.textPrimary, size: 22),
            onPressed: () {
              if (canStoreConfig) {
                showDialog(
                  context: context,
                  builder: (_) => const SettingsSidebarDialog(initialTab: 0),
                );
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Access Denied: Settings require Owner or Manager role.'),
                    backgroundColor: Colors.redAccent,
                  ),
                );
              }
            },
          ),
          IconButton(
            tooltip: 'Log Out of POS',
            icon: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 22),
            onPressed: _confirmLogout,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Google Sheets Authorization Banner (if not verified)
              if (_sheetAccessVerified != true && !isOwner)
                _buildSheetAuthBanner(),

              // Welcome Shift Banner
              _buildWelcomeBanner(user?.fullName ?? user?.email ?? 'Partner', storeName, roleDisplayName),
              const SizedBox(height: 18),

              // Operations Header with Customize Action
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Workstation Operations',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                          letterSpacing: 0.3,
                        ),
                      ),
                      Text(
                        isOwner ? 'Master Admin Console' : 'Assigned Role Access',
                        style: TextStyle(fontSize: 11, color: context.textSecondary),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      backgroundColor: ClassicTheme.primaryAccent.withValues(alpha: 0.1),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                    onPressed: () => _showCustomizeDashboardSheet(context, ref),
                    icon: const Icon(Icons.dashboard_customize_rounded, size: 15, color: ClassicTheme.primaryAccent),
                    label: const Text(
                      'Customize',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: ClassicTheme.primaryAccent,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Responsive Feature Cards Grid (Powered by DashboardLayoutProvider)
              Consumer(
                builder: (context, ref, _) {
                  final layoutState = ref.watch(dashboardLayoutProvider);
                  final saasSession = ref.watch(saasSessionProvider);

                  final allowedCards = kAllDashboardCards.where((c) {
                    return c.isAllowedFor(license: saasSession.currentLicense, role: roleStr);
                  }).toList();
                  final allowedCardIds = allowedCards.map((c) => c.id).toSet();

                  // 1. Pinned Screen Cards
                  final primaryCards = <Widget>[];
                  for (final cardId in layoutState.primaryCardIds) {
                    if (!allowedCardIds.contains(cardId)) continue;
                    final w = _buildCardById(cardId, context, isOwner, canBilling, canTables, canKds, canMenu, canOutlets, canStaff, canStoreConfig, canAnalytics, canOrders);
                    if (w != null) primaryCards.add(w);
                  }

                  // 2. Dropdown Cards ("More Tools")
                  final allowedDropdownCards = <DashboardCardMeta>[];
                  for (final cardId in layoutState.dropdownCardIds) {
                    if (allowedCardIds.contains(cardId)) {
                      allowedDropdownCards.add(allowedCards.firstWhere((c) => c.id == cardId));
                    }
                  }

                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      final int crossAxisCount = width > 900 ? 4 : (width > 550 ? 3 : 2);
                      final double childAspectRatio = width > 550 ? 1.25 : 1.15;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (primaryCards.isNotEmpty)
                            GridView.count(
                              crossAxisCount: crossAxisCount,
                              shrinkWrap: true,
                              physics: const NeverScrollableScrollPhysics(),
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              childAspectRatio: childAspectRatio,
                              children: primaryCards,
                            )
                          else
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(20),
                              decoration: BoxDecoration(
                                color: context.surfaceColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: context.borderColor),
                              ),
                              child: Center(
                                child: Text(
                                  "No cards pinned to screen. Tap 'Customize' to pin cards.",
                                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                                ),
                              ),
                            ),

                          // Dropdown for remaining tools & modules
                          if (allowedDropdownCards.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                              decoration: BoxDecoration(
                                color: context.surfaceColor,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: context.borderColor),
                              ),
                              child: DropdownButtonHideUnderline(
                                child: DropdownButton<String>(
                                  isExpanded: true,
                                  menuMaxHeight: 380,
                                  borderRadius: BorderRadius.circular(16),
                                  dropdownColor: context.surfaceColor,
                                  icon: const Icon(
                                    Icons.keyboard_arrow_down_rounded,
                                    color: ClassicTheme.primaryAccent,
                                    size: 24,
                                  ),
                                  hint: Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.all(6),
                                        decoration: BoxDecoration(
                                          color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: const Icon(
                                          Icons.grid_view_rounded,
                                          size: 16,
                                          color: ClassicTheme.primaryAccent,
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          "More Tools & Modules (${allowedDropdownCards.length})",
                                          style: TextStyle(
                                            color: context.textPrimary,
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  items: allowedDropdownCards.map((card) {
                                    return DropdownMenuItem<String>(
                                      value: card.id,
                                      child: Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(6),
                                            decoration: BoxDecoration(
                                              color: card.defaultColor.withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(8),
                                            ),
                                            child: Icon(card.icon, size: 16, color: card.defaultColor),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              mainAxisAlignment: MainAxisAlignment.center,
                                              children: [
                                                Text(
                                                  card.title,
                                                  style: TextStyle(
                                                    color: context.textPrimary,
                                                    fontSize: 13,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                                Text(
                                                  card.subtitle,
                                                  style: TextStyle(
                                                    color: context.textSecondary,
                                                    fontSize: 10,
                                                  ),
                                                  overflow: TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                  onChanged: (cardId) {
                                    if (cardId == null) return;
                                    switch (cardId) {
                                      case 'counter_billing':
                                        if (canBilling) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()));
                                        }
                                        break;
                                      case 'tables':
                                        if (canTables) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const TableManagementScreen()));
                                        }
                                        break;
                                      case 'orders_history':
                                        if (canOrders) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantOrderHistoryScreen()));
                                        }
                                        break;
                                      case 'kds':
                                        if (canKds) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const KitchenDisplayScreen()));
                                        }
                                        break;
                                      case 'menu':
                                        if (canMenu) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantMenuManagementScreen()));
                                        }
                                        break;
                                      case 'outlets':
                                        if (canOutlets) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const BranchManagementScreen()));
                                        }
                                        break;
                                      case 'staff':
                                        if (canStaff) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const StaffManagementScreen()));
                                        }
                                        break;
                                      case 'store_config':
                                        if (canStoreConfig) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreConfigurationScreen()));
                                        }
                                        break;
                                      case 'analytics':
                                        if (canAnalytics) {
                                          Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantAnalyticsScreen()));
                                        }
                                        break;
                                    }
                                  },
                                ),
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  );
                },
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }


  Widget? _buildCardById(String id, BuildContext context, bool isOwner, bool canBilling, bool canTables, bool canKds, bool canMenu, bool canOutlets, bool canStaff, bool canStoreConfig, bool canAnalytics, [bool canOrders = true]) {
    switch (id) {
      case 'counter_billing':
        if (!canBilling) return null;
        return _buildFeatureCard(
          title: 'Counter Billing',
          subtitle: 'Fast QSR & instant tokens',
          badge: 'POS Desk',
          icon: Icons.point_of_sale_rounded,
          accentColor: Colors.amber,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()),
          ),
        );
      case 'tables':
        if (!canTables) return null;
        return _buildFeatureCard(
          title: 'Tables & Floor',
          subtitle: 'Dine-in layout & live KOT',
          badge: 'Captain',
          icon: Icons.table_restaurant_rounded,
          accentColor: const Color(0xFF10B981),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const TableManagementScreen()),
          ),
        );
      case 'orders_history':
        if (!canOrders) return null;
        return _buildFeatureCard(
          title: 'Order History',
          subtitle: 'All bills, modes & online orders',
          badge: 'Live Ledger',
          icon: Icons.receipt_long_rounded,
          accentColor: const Color(0xFF6366F1),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RestaurantOrderHistoryScreen()),
          ),
        );
      case 'kds':
        if (!canKds) return null;
        return _buildFeatureCard(
          title: 'Kitchen (KDS)',
          subtitle: 'Live kitchen orders & tickets',
          badge: 'Chef Desk',
          icon: Icons.outdoor_grill_rounded,
          accentColor: const Color(0xFFFF6B35),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const KitchenDisplayScreen()),
          ),
        );
      case 'menu':
        if (!canMenu) return null;
        return _buildFeatureCard(
          title: 'Menu Config',
          subtitle: 'Dishes, prices & categories',
          badge: 'Dynamic',
          icon: Icons.restaurant_menu_rounded,
          accentColor: Colors.teal,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RestaurantMenuManagementScreen()),
          ),
        );
      case 'outlets':
        if (!canOutlets) return null;
        return _buildFeatureCard(
          title: 'Outlets / Stores',
          subtitle: 'Create branch & auto-sheets',
          badge: 'Multi-Store',
          icon: Icons.storefront_rounded,
          accentColor: Colors.blueAccent,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const BranchManagementScreen()),
          ),
        );
      case 'staff':
        if (!canStaff) return null;
        return _buildFeatureCard(
          title: 'Staff Mapping',
          subtitle: 'Roles, logins & sheet access',
          badge: 'RBAC Security',
          icon: Icons.people_alt_rounded,
          accentColor: Colors.deepPurpleAccent,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StaffManagementScreen()),
          ),
        );
      case 'store_config':
        if (!canStoreConfig) return null;
        return _buildFeatureCard(
          title: 'Store Settings',
          subtitle: 'Shifts, taxes, UPI & printer',
          badge: 'Operations',
          icon: Icons.tune_rounded,
          accentColor: Colors.deepOrangeAccent,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const StoreConfigurationScreen()),
          ),
        );
      case 'analytics':
        if (!canAnalytics) return null;
        return _buildFeatureCard(
          title: 'Analytics & Rush',
          subtitle: 'Heatmaps, dayparts & AOV',
          badge: 'Real-Time',
          icon: Icons.analytics_rounded,
          accentColor: Colors.pinkAccent,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RestaurantAnalyticsScreen()),
          ),
        );
      default:
        return null;
    }
  }

  void _showCustomizeDashboardSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surfaceColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, _) {
            final layoutState = ref.watch(dashboardLayoutProvider);
            final layoutNotifier = ref.read(dashboardLayoutProvider.notifier);
            final saasSession = ref.watch(saasSessionProvider);
            final userRole = saasSession.currentUser?.role ?? 'OWNER';

            final allowedCards = kAllDashboardCards.where((c) {
              return c.isAllowedFor(license: saasSession.currentLicense, role: userRole);
            }).toList();
            final allowedCardIds = allowedCards.map((c) => c.id).toSet();

            final primaryMetas = layoutState.primaryCardIds
                .where((id) => allowedCardIds.contains(id))
                .map((id) => allowedCards.firstWhere((c) => c.id == id))
                .toList();

            final dropdownMetas = layoutState.dropdownCardIds
                .where((id) => allowedCardIds.contains(id))
                .map((id) => allowedCards.firstWhere((c) => c.id == id))
                .toList();

            final hiddenMetas = layoutState.hiddenCardIds
                .where((id) => allowedCardIds.contains(id))
                .map((id) => allowedCards.firstWhere((c) => c.id == id))
                .toList();

            return DraggableScrollableSheet(
              initialChildSize: 0.75,
              minChildSize: 0.5,
              maxChildSize: 0.95,
              expand: false,
              builder: (_, scrollController) {
                return Column(
                  children: [
                    Container(
                      margin: const EdgeInsets.only(top: 12, bottom: 8),
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade400,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Customize Dashboard",
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 17,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "Screen cards • Dropdown cards • Tap to reorder or hide",
                                style: TextStyle(color: context.textSecondary, fontSize: 11),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            onPressed: () {
                              layoutNotifier.resetToDefault(allowedCardIds: allowedCards.map((c) => c.id).toList());
                            },
                            icon: const Icon(Icons.refresh, size: 14, color: ClassicTheme.primaryAccent),
                            label: const Text(
                              "Reset",
                              style: TextStyle(color: ClassicTheme.primaryAccent, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(color: context.borderColor, height: 1),
                    Expanded(
                      child: ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.all(16),
                        children: [
                          // 1. PINNED ON SCREEN
                          Row(
                            children: [
                              const Icon(Icons.push_pin_rounded, size: 14, color: Color(0xFF10B981)),
                              const SizedBox(width: 6),
                              Text(
                                "PINNED ON SCREEN (${primaryMetas.length})",
                                style: const TextStyle(
                                  color: Color(0xFF10B981),
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (primaryMetas.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                "No cards pinned to screen. Move cards from below.",
                                style: TextStyle(color: context.textSecondary, fontSize: 12),
                              ),
                            )
                          else
                            ...primaryMetas.map((card) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                decoration: BoxDecoration(
                                  color: context.canvasColor,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: context.borderColor),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: card.defaultColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(card.icon, size: 18, color: card.defaultColor),
                                  ),
                                  title: Text(
                                    card.title,
                                    style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                  subtitle: Text(
                                    card.subtitle,
                                    style: TextStyle(color: context.textSecondary, fontSize: 11),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: "Move to Dropdown",
                                        icon: const Icon(Icons.arrow_downward_rounded, size: 18, color: Colors.blueAccent),
                                        onPressed: () => layoutNotifier.moveToDropdown(card.id),
                                      ),
                                      IconButton(
                                        tooltip: "Hide Card",
                                        icon: const Icon(Icons.visibility_off_outlined, size: 18, color: Colors.redAccent),
                                        onPressed: () => layoutNotifier.hideCard(card.id),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),

                          const SizedBox(height: 16),
                          // 2. MORE TOOLS (DROPDOWN)
                          Row(
                            children: [
                              const Icon(Icons.menu_open_rounded, size: 14, color: Colors.blueAccent),
                              const SizedBox(width: 6),
                              Text(
                                "IN 'MORE TOOLS' DROPDOWN (${dropdownMetas.length})",
                                style: const TextStyle(
                                  color: Colors.blueAccent,
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 1.1,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          if (dropdownMetas.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: Text(
                                "No cards in dropdown.",
                                style: TextStyle(color: context.textSecondary, fontSize: 12),
                              ),
                            )
                          else
                            ...dropdownMetas.map((card) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                decoration: BoxDecoration(
                                  color: context.canvasColor,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: context.borderColor),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: BoxDecoration(
                                      color: card.defaultColor.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: Icon(card.icon, size: 18, color: card.defaultColor),
                                  ),
                                  title: Text(
                                    card.title,
                                    style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                                  ),
                                  subtitle: Text(
                                    card.subtitle,
                                    style: TextStyle(color: context.textSecondary, fontSize: 11),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: "Pin to Screen",
                                        icon: const Icon(Icons.arrow_upward_rounded, size: 18, color: Color(0xFF10B981)),
                                        onPressed: () => layoutNotifier.moveToScreen(card.id),
                                      ),
                                      IconButton(
                                        tooltip: "Hide Card",
                                        icon: const Icon(Icons.visibility_off_outlined, size: 18, color: Colors.redAccent),
                                        onPressed: () => layoutNotifier.hideCard(card.id),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            }),

                          if (hiddenMetas.isNotEmpty) ...[
                            const SizedBox(height: 16),
                            // 3. HIDDEN CARDS
                            Row(
                              children: [
                                const Icon(Icons.visibility_off_rounded, size: 14, color: Colors.grey),
                                const SizedBox(width: 6),
                                Text(
                                  "HIDDEN CARDS (${hiddenMetas.length})",
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            ...hiddenMetas.map((card) {
                              return Container(
                                margin: const EdgeInsets.only(bottom: 6),
                                decoration: BoxDecoration(
                                  color: context.canvasColor,
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: context.borderColor),
                                ),
                                child: ListTile(
                                  dense: true,
                                  leading: Icon(card.icon, size: 18, color: Colors.grey),
                                  title: Text(
                                    card.title,
                                    style: TextStyle(color: context.textSecondary, fontSize: 13),
                                  ),
                                  trailing: TextButton.icon(
                                    icon: const Icon(Icons.restore_rounded, size: 16, color: Color(0xFF10B981)),
                                    label: const Text("Restore", style: TextStyle(color: Color(0xFF10B981), fontSize: 12)),
                                    onPressed: () => layoutNotifier.restoreCard(card.id),
                                  ),
                                ),
                              );
                            }),
                          ],
                        ],
                      ),
                    ),
                  ],
                );
              },
            );
          },
        );
      },
    );
  }

  Widget _buildWelcomeBanner(String userName, String storeName, String role) {
    final now = DateTime.now();
    final hour = now.hour;
    final shiftName = hour < 12 ? 'Breakfast Shift' : (hour < 17 ? 'Lunch Rush Shift' : 'Dinner Shift');

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.borderColor),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Welcome, $userName',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  'Station assigned: $role · $shiftName',
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.amber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.circle, color: Color(0xFF10B981), size: 8),
                const SizedBox(width: 6),
                Text(
                  shiftName,
                  style: TextStyle(color: Colors.amber.shade900, fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSheetAuthBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.orangeAccent.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: Colors.orangeAccent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '1-Time Google Sheets Authorization',
                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13),
                ),
                Text(
                  _sheetCheckMessage.isNotEmpty ? _sheetCheckMessage : 'Authorize your Google account to sync live orders with store database.',
                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orangeAccent,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _isCheckingSheets ? null : _authorizeGoogleAccount,
            child: _isCheckingSheets
                ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                : const Text('Authorize', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  Widget _buildFeatureCard({
    required String title,
    required String subtitle,
    required String badge,
    required IconData icon,
    required Color accentColor,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        splashColor: accentColor.withValues(alpha: 0.12),
        highlightColor: accentColor.withValues(alpha: 0.06),
        child: Container(
          padding: const EdgeInsets.all(13),
          decoration: BoxDecoration(
            color: context.surfaceColor,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.borderColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.02),
                blurRadius: 6,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(icon, color: accentColor, size: 22),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: accentColor.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: accentColor.withValues(alpha: 0.25)),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: accentColor,
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13.5,
                      fontWeight: FontWeight.bold,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 10.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
