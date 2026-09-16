import '../../providers/dashboard_layout_provider.dart';
import '../../providers/entitlements_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;

import 'package:flutter/services.dart';
import '../../core/classic_theme.dart';
import '../../providers/auth_provider.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/restaurant_sheets_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../../widgets/google_sheets_setup_gate_dialog.dart';
import '../../widgets/feature_gated_widget.dart';

import '../counter_billing/fast_qsr_billing_screen.dart';
import '../restaurant/table_management_screen.dart';
import '../kitchen/kitchen_display_screen.dart';
import '../restaurant/restaurant_menu_management_screen.dart';
import '../restaurant/branch_management_screen.dart';
import '../settings/staff_management_screen.dart';
import '../restaurant/store_configuration_screen.dart';
import '../settings/settings_sidebar_dialog.dart';
import '../settings/plan_request_sheet.dart';
import '../analytics/restaurant_analytics_screen.dart';
import '../orders/restaurant_order_history_screen.dart';
import '../expenses/expenses_screen.dart';
import '../waiter/waiter_table_picker_screen.dart';
import '../../core/rbac_permissions.dart';
import '../../core/entitlements.dart';
import '../../core/saas_models.dart';
import '../../utils/ui_feedback.dart';
import '../../core/cloud_gate.dart';

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
      // The resolver (storage mode → legacy flag → profile) decides whether this
      // tenant is offline; the licence flag alone is no longer the authority.
      final isPureOffline = ref.read(entitlementsProvider).isPureOffline;
      if (!isPureOffline) {
        await GoogleSheetsSetupGateDialog.showIfRequired(context, ref);
      }
      if (mounted) {
        _checkGoogleSheetsAccess();
      }
    });
  }

  Future<void> _checkGoogleSheetsAccess() async {
    final saasSession = ref.read(saasSessionProvider);
    if (ref.read(entitlementsProvider).isPureOffline) {
      if (mounted) {
        setState(() {
          _sheetAccessVerified = true;
          _sheetCheckMessage = 'Offline Station · Direct Local POS';
        });
      }
      return;
    }
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
        // Fetch from Firestore (through the cloud gate)
        final doc = await CloudGate.run(() => FirebaseFirestore.instance.collection('organizations').doc(orgId).get());
        sheetId = doc?.data()?['googleSheetId']?.toString() ?? doc?.data()?['spreadsheetId']?.toString();
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

  Future<void> _handleRefresh() async {
    HapticFeedback.lightImpact();
    await _checkGoogleSheetsAccess();
    try {
      final saasSession = ref.read(saasSessionProvider);
      final user = saasSession.currentUser;
      final org = saasSession.currentOrganization;
      final orgId = user?.organizationId ?? org?.id ?? 'ORG_DEFAULT';
      await AppsScriptBackendService.fetchOrders(orgId: orgId);
    } catch (_) {}
    if (mounted) setState(() {});
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
            const Icon(Icons.logout_rounded, color: ClassicTheme.dangerRed, size: 22),
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
              backgroundColor: ClassicTheme.dangerRed,
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

  // ── Plan expiry (owner only) ───────────────────────────────────────────────

  /// True when the owner can still do something about it: the plan is close to
  /// its end, or already past it. `expiryWarningDays` is set per tenant by the
  /// console, so a shop on an annual plan is not nagged for a month.
  bool _planNeedsAttention(SaasLicense? licence) {
    if (licence == null) return false;
    return licence.isExpired || licence.isNearExpiry || licence.isPastDue;
  }

  /// A trial can be upgraded by the owner asking; a paid plan is a
  /// conversation with the administrator. Neither shows a price (D5).
  bool _isTrial(SaasLicense licence) =>
      licence.planTier.toUpperCase().contains('TRIAL') ||
      (licence.planProfile ?? '').toUpperCase().contains('TRIAL');

  Future<void> _openPlanRequest(SaasLicense licence) async {
    final sent = await PlanRequestSheet.show(
      context,
      type: licence.isExpired ? 'RENEWAL' : 'UPGRADE',
    );
    if (sent == true && mounted) {
      AppToast.showSuccess(context, 'Request sent',
          subtitle: 'Your administrator will confirm the final plan with you.');
    }
  }

  Widget _planActionButton(BuildContext context, SaasLicense licence) {
    final expired = licence.isExpired;
    final trial = _isTrial(licence);
    final color = expired ? ClassicTheme.dangerRed : ClassicTheme.warningAmber;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextButton.icon(
        onPressed: () => _openPlanRequest(licence),
        icon: Icon(trial ? Icons.bolt_rounded : Icons.support_agent_rounded,
            size: 18, color: color),
        label: Text(
          trial ? 'Upgrade' : 'Contact admin',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold, color: color),
        ),
        style: TextButton.styleFrom(
          backgroundColor: color.withValues(alpha: 0.10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  Widget _buildPlanBanner(SaasLicense licence) {
    final expired = licence.isExpired;
    final trial = _isTrial(licence);
    final days = licence.daysRemaining;
    final color = expired ? ClassicTheme.dangerRed : ClassicTheme.warningAmber;

    final String headline;
    if (expired) {
      headline = trial ? 'Your trial has ended' : 'Your plan has ended';
    } else if (licence.isPastDue) {
      headline = 'Payment is past due';
    } else {
      headline = trial
          ? 'Trial ends in $days day${days == 1 ? '' : 's'}'
          : 'Plan ends in $days day${days == 1 ? '' : 's'}';
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(expired ? Icons.event_busy_rounded : Icons.schedule_rounded,
              color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(headline,
                    style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: context.textPrimary)),
                const SizedBox(height: 3),
                Text(
                  // Rule 7, said out loud: whatever happens to the plan, the
                  // till keeps working. An owner who fears losing the register
                  // mid-service will pay under duress; that is not a business
                  // we want to run.
                  expired
                      ? 'Billing keeps working on this device. Ask your administrator to '
                          'restore the rest.'
                      : 'Nothing stops working on the day it ends — billing carries on '
                          'either way.',
                  style: TextStyle(
                      fontSize: 12, color: context.textSecondary, height: 1.4),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ElevatedButton.icon(
                      onPressed: () => _openPlanRequest(licence),
                      icon: Icon(trial ? Icons.bolt_rounded : Icons.mail_outline_rounded,
                          size: 16),
                      label: Text(trial ? 'Ask for an upgrade' : 'Contact administrator',
                          style: const TextStyle(
                              fontSize: 12, fontWeight: FontWeight.bold)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: color,
                        foregroundColor: Colors.white,
                        elevation: 0,
                        visualDensity: VisualDensity.compact,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                    ),
                  ],
                ),
              ],
            ),
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

    // Feature enablement, resolved from the tenant's plan. A card whose feature
    // is not in the plan is absent from the dashboard entirely — the filtering
    // happens in `DashboardCardMeta.isAllowedFor`, so there is no second list
    // of booleans here to drift out of step with it.
    final ent = ref.watch(entitlementsProvider);

    // Role permission flags for each card
    final bool roleBilling = isOwner || isManager || isBilling;
    final bool roleTables = isOwner || isManager || isBilling || isWaiter;
    final bool roleKds = isOwner || isManager || isKitchen;
    final bool roleMenu = isOwner || isManager;
    final bool roleOutlets = isOwner;
    final bool roleStaff = isOwner || isManager;
    final bool roleStoreConfig = isOwner || isManager;
    final bool roleAnalytics = isOwner || isManager;
    final bool roleOrders = isOwner || isManager || isBilling;
    final bool roleExpenses = isOwner || isManager;
    final bool roleWaiter = isOwner || isManager || isWaiter;

    final bool isPureOffline = ent.isPureOffline;

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
                color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Icon(Icons.restaurant_rounded, color: ClassicTheme.warningAmber, size: 22),
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
                          color: isOwner ? ClassicTheme.warningAmber.withValues(alpha: 0.15) : ClassicTheme.infoBlue.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          roleDisplayName,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: isOwner ? ClassicTheme.warningAmber : ClassicTheme.infoBlue,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (isPureOffline)
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.offline_pin_rounded, size: 11, color: ClassicTheme.successEmerald),
                              SizedBox(width: 4),
                              Text(
                                'Pure Offline Station',
                                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                              ),
                            ],
                          ),
                        )
                      else
                        Icon(
                          _sheetAccessVerified == true ? Icons.cloud_done_rounded : Icons.cloud_sync_rounded,
                          size: 13,
                          color: _sheetAccessVerified == true ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          // Owner only (rule 2 for roles): a waiter mid-service can do nothing
          // about a licence, so telling them about it is noise on a busy screen.
          if (isOwner && _planNeedsAttention(saasSession.currentLicense))
            _planActionButton(context, saasSession.currentLicense!),
          IconButton(
            tooltip: 'User & Terminal Settings',
            icon: Icon(Icons.settings_outlined, color: context.textPrimary, size: 22),
            onPressed: () {
              showDialog(
                context: context,
                builder: (_) => const SettingsSidebarDialog(initialTab: 0),
              );
            },
          ),
          IconButton(
            tooltip: 'Log Out of POS',
            icon: const Icon(Icons.logout_rounded, color: ClassicTheme.dangerRed, size: 22),
            onPressed: _confirmLogout,
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: _handleRefresh,
          color: ClassicTheme.primaryAccent,
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Google Sheets Authorization Banner (if not verified and not pure offline)
              if (_sheetAccessVerified != true && !isOwner && !isPureOffline)
                _buildSheetAuthBanner(),

              // Plan running out — owner only.
              if (isOwner && _planNeedsAttention(saasSession.currentLicense))
                _buildPlanBanner(saasSession.currentLicense!),

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
                        style: TextStyle(fontSize: 12, color: context.textSecondary),
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
                    icon: Icon(Icons.dashboard_customize_rounded, size: 15, color: ClassicTheme.primaryAccent),
                    label: Text(
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
                  final entitlements = ref.watch(entitlementsProvider);
                  final allowedCards = kAllDashboardCards.where((c) {
                    return c.isAllowedFor(
                      entitlements: entitlements,
                      role: roleStr,
                    );
                  }).toList();
                  final allowedCardIds = allowedCards.map((c) => c.id).toSet();

                  // 1. Pinned Screen Cards
                  final primaryCards = <Widget>[];
                  for (final cardId in layoutState.primaryCardIds) {
                    if (!allowedCardIds.contains(cardId)) continue;
                    final w = _buildCardById(
                      cardId,
                      context,
                      isOwner,
                      roleBilling,
                      roleTables,
                      roleKds,
                      roleMenu,
                      roleOutlets,
                      roleStaff,
                      roleStoreConfig,
                      roleAnalytics,
                      roleOrders,
                      roleExpenses,
                      roleWaiter,
                    );
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
                                  icon: Icon(
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
                                        child: Icon(
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
                                                    fontSize: 12,
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
                                         if (roleBilling) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()));
                                         }
                                         break;
                                       case 'tables':
                                         if (roleTables) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const TableManagementScreen()));
                                         }
                                         break;
                                       case 'orders_history':
                                         if (roleOrders) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantOrderHistoryScreen()));
                                         }
                                         break;
                                       case 'kds':
                                         if (roleKds) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const KitchenDisplayScreen()));
                                         }
                                         break;
                                       case 'menu':
                                         if (roleMenu) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantMenuManagementScreen()));
                                         }
                                         break;
                                       case 'outlets':
                                         if (roleOutlets) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const BranchManagementScreen()));
                                         }
                                         break;
                                       case 'staff':
                                         if (roleStaff) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const StaffManagementScreen()));
                                         }
                                         break;
                                       case 'store_config':
                                         if (roleStoreConfig) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const StoreConfigurationScreen()));
                                         }
                                         break;
                                       case 'analytics':
                                         if (roleAnalytics) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const RestaurantAnalyticsScreen()));
                                         }
                                         break;
                                       case 'expenses':
                                         if (roleExpenses) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const ExpensesScreen()));
                                         }
                                         break;
                                       case 'waiter':
                                         if (roleWaiter) {
                                           Navigator.push(context, MaterialPageRoute(builder: (_) => const WaiterTablePickerScreen()));
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
     ),
   );
   }


  Widget? _buildCardById(
    String id,
    BuildContext context,
    bool isOwner,
    bool roleBilling,
    bool roleTables,
    bool roleKds,
    bool roleMenu,
    bool roleOutlets,
    bool roleStaff,
    bool roleStoreConfig,
    bool roleAnalytics,
    [bool roleOrders = true, bool roleExpenses = true, bool roleWaiter = true]
  ) {
    switch (id) {
      case 'counter_billing':
        if (!roleBilling) return null;
        return FeatureGatedCard(
          featureKey: 'qsrBilling',
          featureLabel: 'Counter POS Billing',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Counter Billing',
            subtitle: 'Fast QSR & instant tokens',
            badge: 'POS Desk',
            icon: Icons.point_of_sale_rounded,
            accentColor: ClassicTheme.warningAmber,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()),
            ),
          ),
        );
      case 'tables':
        if (!roleTables) return null;
        return FeatureGatedCard(
          featureKey: 'tableManagement',
          featureLabel: 'Tables & Floor Plan',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Tables & Floor',
            subtitle: 'Dine-in layout & live KOT',
            badge: 'Captain',
            icon: Icons.table_restaurant_rounded,
            accentColor: ClassicTheme.successEmerald,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TableManagementScreen()),
            ),
          ),
        );
      case 'orders_history':
        if (!roleOrders) return null;
        return _buildFeatureCard(
          title: 'Order History',
          subtitle: 'All bills, modes & online orders',
          badge: 'Live Ledger',
          icon: Icons.receipt_long_rounded,
          accentColor: ClassicTheme.secondaryAccent,
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const RestaurantOrderHistoryScreen()),
          ),
        );
      case 'kds':
        if (!roleKds) return null;
        return FeatureGatedCard(
          featureKey: 'kdsEnabled',
          featureLabel: 'Kitchen Display Screen (KDS)',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Kitchen (KDS)',
            subtitle: 'Live kitchen orders & tickets',
            badge: 'Chef Desk',
            icon: Icons.outdoor_grill_rounded,
            accentColor: ClassicTheme.primaryAccent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const KitchenDisplayScreen()),
            ),
          ),
        );
      case 'menu':
        if (!roleMenu) return null;
        return FeatureGatedCard(
          featureKey: 'menuManagement',
          featureLabel: 'Menu Configuration',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Menu Config',
            subtitle: 'Dishes, prices & categories',
            badge: 'Dynamic',
            icon: Icons.restaurant_menu_rounded,
            accentColor: ClassicTheme.secondaryAccent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RestaurantMenuManagementScreen()),
            ),
          ),
        );
      case 'outlets':
        if (!roleOutlets) return null;
        return FeatureGatedCard(
          featureKey: 'multiOutlet',
          featureLabel: 'Multi-Store Outlets',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Outlets / Stores',
            subtitle: 'Create branch & auto-sheets',
            badge: 'Multi-Store',
            icon: Icons.storefront_rounded,
            accentColor: ClassicTheme.infoBlue,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const BranchManagementScreen()),
            ),
          ),
        );
      case 'staff':
        if (!roleStaff) return null;
        return FeatureGatedCard(
          featureKey: 'staffManagement',
          featureLabel: 'Staff Management & RBAC',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Staff Mapping',
            subtitle: 'Roles, logins & sheet access',
            badge: 'RBAC Security',
            icon: Icons.people_alt_rounded,
            accentColor: ClassicTheme.secondaryAccent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StaffManagementScreen()),
            ),
          ),
        );
      case 'store_config':
        if (!roleStoreConfig) return null;
        return FeatureGatedCard(
          featureKey: 'storeConfiguration',
          featureLabel: 'Store Settings',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Store Settings',
            subtitle: 'Shifts, taxes, UPI & printer',
            badge: 'Operations',
            icon: Icons.tune_rounded,
            accentColor: ClassicTheme.primaryAccent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const StoreConfigurationScreen()),
            ),
          ),
        );
      case 'analytics':
        if (!roleAnalytics) return null;
        return FeatureGatedCard(
          featureKey: FeatureKeys.analytics,
          featureLabel: 'Analytics & Rush Reports',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Analytics & Rush',
            subtitle: 'Heatmaps, dayparts & AOV',
            badge: 'Real-Time',
            icon: Icons.analytics_rounded,
            accentColor: ClassicTheme.primaryAccent,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const RestaurantAnalyticsScreen()),
            ),
          ),
        );
      case 'expenses':
        if (!roleExpenses) return null;
        return FeatureGatedCard(
          featureKey: FeatureKeys.expenseManagement,
          featureLabel: 'Expense Tracking',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Expenses',
            subtitle: 'Purchases, wages & bills paid',
            badge: 'Spend',
            icon: Icons.receipt_long_rounded,
            accentColor: ClassicTheme.warningAmber,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ExpensesScreen()),
            ),
          ),
        );
      case 'waiter':
        if (!roleWaiter) return null;
        return FeatureGatedCard(
          featureKey: FeatureKeys.waiterOrdering,
          featureLabel: 'Waiter Pad',
          onTap: null,
          child: _buildFeatureCard(
            title: 'Waiter Pad',
            subtitle: 'Pick a table, take the order',
            badge: 'Floor',
            icon: Icons.room_service_rounded,
            accentColor: ClassicTheme.infoBlue,
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const WaiterTablePickerScreen()),
            ),
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

            final entitlements = ref.watch(entitlementsProvider);
            final allowedCards = kAllDashboardCards.where((c) {
              return c.isAllowedFor(
                entitlements: entitlements,
                role: userRole,
              );
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
                                style: TextStyle(color: context.textSecondary, fontSize: 12),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            onPressed: () {
                              layoutNotifier.resetToDefault(allowedCardIds: allowedCards.map((c) => c.id).toList());
                            },
                            icon: Icon(Icons.refresh, size: 14, color: ClassicTheme.primaryAccent),
                            label: Text(
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
                              const Icon(Icons.push_pin_rounded, size: 14, color: ClassicTheme.successEmerald),
                              const SizedBox(width: 6),
                              Text(
                                "PINNED ON SCREEN (${primaryMetas.length})",
                                style: const TextStyle(
                                  color: ClassicTheme.successEmerald,
                                  fontSize: 12,
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
                                    style: TextStyle(color: context.textSecondary, fontSize: 12),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: "Move to Dropdown",
                                        icon: const Icon(Icons.arrow_downward_rounded, size: 18, color: ClassicTheme.infoBlue),
                                        onPressed: () => layoutNotifier.moveToDropdown(card.id),
                                      ),
                                      IconButton(
                                        tooltip: "Hide Card",
                                        icon: const Icon(Icons.visibility_off_outlined, size: 18, color: ClassicTheme.dangerRed),
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
                              const Icon(Icons.menu_open_rounded, size: 14, color: ClassicTheme.infoBlue),
                              const SizedBox(width: 6),
                              Text(
                                "IN 'MORE TOOLS' DROPDOWN (${dropdownMetas.length})",
                                style: const TextStyle(
                                  color: ClassicTheme.infoBlue,
                                  fontSize: 12,
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
                                    style: TextStyle(color: context.textSecondary, fontSize: 12),
                                  ),
                                  trailing: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      IconButton(
                                        tooltip: "Pin to Screen",
                                        icon: const Icon(Icons.arrow_upward_rounded, size: 18, color: ClassicTheme.successEmerald),
                                        onPressed: () => layoutNotifier.moveToScreen(card.id),
                                      ),
                                      IconButton(
                                        tooltip: "Hide Card",
                                        icon: const Icon(Icons.visibility_off_outlined, size: 18, color: ClassicTheme.dangerRed),
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
                                    fontSize: 12,
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
                                    icon: const Icon(Icons.restore_rounded, size: 16, color: ClassicTheme.successEmerald),
                                    label: const Text("Restore", style: TextStyle(color: ClassicTheme.successEmerald, fontSize: 12)),
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
              color: ClassicTheme.warningAmber.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.circle, color: ClassicTheme.successEmerald, size: 8),
                const SizedBox(width: 6),
                Text(
                  shiftName,
                  style: TextStyle(color: ClassicTheme.warningAmber, fontSize: 12, fontWeight: FontWeight.bold),
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
        border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline_rounded, color: ClassicTheme.warningAmber, size: 22),
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
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
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
                        fontSize: 12,
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
                      fontSize: 12,
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
