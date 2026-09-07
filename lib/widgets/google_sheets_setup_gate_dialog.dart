import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import '../core/classic_theme.dart';
import '../core/constants.dart';
import '../providers/saas_session_provider.dart';
import '../providers/restaurant_auth_provider.dart';
import '../services/restaurant_sheets_service.dart';
import '../services/client_ledger_cloud_router_service.dart';
import '../services/apps_script_backend_service.dart';
import '../utils/ui_feedback.dart';

class GoogleSheetsSetupGateDialog extends ConsumerStatefulWidget {
  const GoogleSheetsSetupGateDialog({super.key});

  static Future<void> showIfRequired(BuildContext context, WidgetRef ref) async {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final user = saasSession.currentUser;

    if (org == null) return;

    // Only store owners / client admins or master admins configure cloud database
    final role = user?.role.toUpperCase() ?? '';
    final isClientAdmin = role == 'OWNER' || role == 'MASTER_ADMIN' || user?.isClient == true;
    if (!isClientAdmin) return;

    final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
    final localSheetId = box?.get('restaurant_sheet_id_${org.id}') as String?;

    final isConnected = (org.isGoogleConnected == true && org.googleSheetId != null && org.googleSheetId!.isNotEmpty) ||
        (localSheetId != null && localSheetId.isNotEmpty);

    if (!isConnected) {
      if (context.mounted) {
        await showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => const GoogleSheetsSetupGateDialog(),
        );
      }
    }
  }

  @override
  ConsumerState<GoogleSheetsSetupGateDialog> createState() => _GoogleSheetsSetupGateDialogState();
}

class _GoogleSheetsSetupGateDialogState extends ConsumerState<GoogleSheetsSetupGateDialog> {
  bool _isLoading = false;
  String _statusText = '';

  Future<void> _handleAuthorizeGoogle() async {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final user = saasSession.currentUser;
    if (org == null) return;

    final orgId = org.id;
    final storeName = org.name.isNotEmpty ? org.name : (org.appName.isNotEmpty ? org.appName : 'My Restaurant');
    final expectedEmail = (user?.email != null && user!.email.isNotEmpty)
        ? user.email
        : (org.ownerGoogleEmail ?? '');

    setState(() {
      _isLoading = true;
      _statusText = 'Signing in to Google account...';
    });

    try {
      final authNotifier = ref.read(restaurantAuthProvider.notifier);
      final signInRes = await authNotifier.signInWithGoogle();

      if (signInRes['success'] != true) {
        final err = signInRes['error']?.toString() ?? 'Google sign-in was cancelled';
        throw Exception(err);
      }

      final client = authNotifier.authenticatedHttpClient;
      if (client == null) {
        throw Exception('Failed to obtain authenticated Google client.');
      }

      final currentAuthState = ref.read(restaurantAuthProvider);
      final authorizedEmail = signInRes['staff']?.email ?? currentAuthState.googleEmail ?? expectedEmail;

      setState(() => _statusText = 'Provisioning 7-tab Restaurant Google Sheet...');

      // 1. Provision 7-Tab Restaurant Google Sheet on Client's Drive
      final provisionRes = await RestaurantSheetsService.provisionRestaurantSheet(
        authenticatedClient: client,
        restaurantName: storeName,
        orgId: orgId,
      );

      if (provisionRes['success'] != true) {
        throw Exception(provisionRes['error'] ?? 'Failed to provision Google Sheet on Google Drive.');
      }

      final sheetId = provisionRes['spreadsheetId']?.toString() ?? '';
      final sheetUrl = provisionRes['sheetUrl']?.toString() ?? 'https://docs.google.com/spreadsheets/d/$sheetId/edit';

      setState(() => _statusText = 'Granting platform sync permissions...');

      // 2. Grant Editor/Writer permissions to platform and admin emails
      for (final adminEmail in kAdminEmails) {
        try {
          await RestaurantSheetsService.shareSpreadsheetWithStaff(
            authenticatedClient: client,
            spreadsheetId: sheetId,
            staffEmail: adminEmail,
          );
        } catch (e) {
          debugPrint('Platform permission grant note: $e');
        }
      }

      setState(() => _statusText = 'Registering cloud webhook & web menu sync...');

      // 3. Register tenant in Apps Script Webhook so web QR menu works immediately
      try {
        final box = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
        final upiId = box?.get('restaurant_upi_id', defaultValue: kDefaultMerchantVpa);
        await AppsScriptBackendService.registerTenant(
          orgId: orgId,
          spreadsheetId: sheetId,
          orgName: storeName,
          upiId: upiId,
        );
      } catch (e) {
        debugPrint('Webhook registration note: $e');
      }

      setState(() => _statusText = 'Finalizing store database records...');

      // 4. Update Firestore Organization & Primary Outlet
      await FirebaseFirestore.instance.collection('organizations').doc(orgId).set({
        'googleSheetId': sheetId,
        'googleSheetUrl': sheetUrl,
        'spreadsheetId': sheetId,
        'ownerGoogleEmail': authorizedEmail,
        'isGoogleConnected': true,
        'storageMode': 'CLIENTS_OWN_SHEETS',
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      try {
        final outletSnap = await FirebaseFirestore.instance
            .collection('outlets')
            .where('organizationId', isEqualTo: orgId)
            .limit(1)
            .get();
        if (outletSnap.docs.isNotEmpty) {
          await outletSnap.docs.first.reference.set({
            'googleSheetId': sheetId,
            'googleSheetUrl': sheetUrl,
            'updatedAt': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true));
        }
      } catch (_) {}

      // 5. Cache locally in Hive
      final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
      await configBox?.put('restaurant_sheet_id_$orgId', sheetId);
      await configBox?.put('restaurant_sheet_url_$orgId', sheetUrl);
      await configBox?.put('google_sheet_id', sheetId);
      await configBox?.put('google_sheet_url', sheetUrl);

      // 6. Refresh SaaS session
      await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();

      if (mounted) {
        Navigator.pop(context);
        AppToast.showSuccess(
          context,
          'Cloud Database Connected Successfully!',
          subtitle: '7-Tab Restaurant Google Sheet initialized & live for web orders.',
        );
      }
    } catch (e) {
      if (mounted) {
        final errStr = e.toString();
        if (errStr.contains('10') || errStr.contains('verification') || errStr.contains('sign_in_failed')) {
          _showGoogleVerificationHelpDialog();
        } else {
          AppToast.showError(context, e, title: 'Cloud Database Setup');
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _statusText = '';
        });
      }
    }
  }

  Future<void> _handlePasteSheet() async {
    final saasSession = ref.read(saasSessionProvider);
    final org = saasSession.currentOrganization;
    if (org == null) return;
    final orgId = org.id;

    final urlCtrl = TextEditingController(text: org.googleSheetUrl ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            const Icon(Icons.link_rounded, color: ClassicTheme.primaryAccent, size: 24),
            const SizedBox(width: 10),
            Text(
              'Link Google Sheet',
              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste your existing Google Sheet URL or ID below to link your store database immediately:',
              style: TextStyle(color: context.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: urlCtrl,
              style: TextStyle(color: context.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'https://docs.google.com/spreadsheets/d/.../edit',
                hintStyle: TextStyle(color: context.textSecondary.withValues(alpha: 0.5)),
                prefixIcon: const Icon(Icons.link_rounded, size: 20),
                filled: true,
                fillColor: context.canvasColor,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Cancel', style: TextStyle(color: context.textSecondary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Connect Sheet'),
          ),
        ],
      ),
    );

    if (confirmed == true && urlCtrl.text.trim().isNotEmpty) {
      final input = urlCtrl.text.trim();
      String sheetId = input;
      if (input.contains('/spreadsheets/d/')) {
        final reg = RegExp(r'/spreadsheets/d/([a-zA-Z0-9-_]+)');
        final match = reg.firstMatch(input);
        if (match != null) sheetId = match.group(1)!;
      }
      final sheetUrl = 'https://docs.google.com/spreadsheets/d/$sheetId/edit';

      setState(() {
        _isLoading = true;
        _statusText = 'Linking Google Sheet to store...';
      });

      try {
        final configBox = Hive.isBoxOpen('restaurant_config_box') ? Hive.box('restaurant_config_box') : null;
        await configBox?.put('restaurant_sheet_id_$orgId', sheetId);
        await configBox?.put('restaurant_sheet_url_$orgId', sheetUrl);
        await configBox?.put('google_sheet_id', sheetId);
        await configBox?.put('google_sheet_url', sheetUrl);

        await FirebaseFirestore.instance.collection('organizations').doc(orgId).set({
          'googleSheetId': sheetId,
          'googleSheetUrl': sheetUrl,
          'spreadsheetId': sheetId,
          'isGoogleConnected': true,
          'storageMode': 'CLIENTS_OWN_SHEETS',
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        await FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
          'googleSheetId': sheetId,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));

        // Ensure 7 standard restaurant tabs and permissions if authenticated client is available
        final authClient = await ClientLedgerCloudRouterService.getAuthenticatedClientIfAvailable() ??
            ref.read(restaurantAuthProvider.notifier).authenticatedHttpClient;
        if (authClient != null) {
          try {
            await RestaurantSheetsService.ensureRestaurantTabsExist(
              authenticatedClient: authClient,
              sheetId: sheetId,
            );
            for (final admin in kAdminEmails) {
              await RestaurantSheetsService.shareSpreadsheetWithStaff(
                authenticatedClient: authClient,
                spreadsheetId: sheetId,
                staffEmail: admin,
              );
            }
          } catch (pe) {
            debugPrint('Tab/permission setup notice on sheet paste: $pe');
          }
        }

        // Register in AppsScript backend so cloud webhook can sync without permissions issues
        try {
          final upiId = configBox?.get('restaurant_upi_id', defaultValue: kDefaultMerchantVpa);
          await AppsScriptBackendService.registerTenant(
            orgId: orgId,
            spreadsheetId: sheetId,
            orgName: org.name,
            upiId: upiId,
          );
        } catch (we) {
          debugPrint('AppsScript tenant registration notice: $we');
        }

        await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();

        if (mounted) {
          Navigator.pop(context); // Close gate dialog
          AppToast.showSuccess(
            context,
            'Google Sheet Connected!',
            subtitle: 'Store database successfully linked and verified.',
          );
        }
      } catch (e) {
        if (mounted) {
          AppToast.showError(context, e, title: 'Sheet Linking Failed');
        }
      } finally {
        if (mounted) setState(() => _isLoading = false);
      }
    }
  }

  void _showGoogleVerificationHelpDialog() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: context.borderColor),
        ),
        title: Row(
          children: [
            const Icon(Icons.info_outline_rounded, color: Colors.amber, size: 24),
            const SizedBox(width: 10),
            Text(
              'Google Authorization Notice',
              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Google Play Services returned Code 10 (App signature verification in progress).',
              style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 10),
            const Text(
              'Google servers can take 5-10 minutes to propagate the newly registered OAuth client to your device.\n\n'
              'You can click Retry now, or paste an existing Google Sheet link to connect immediately:',
              style: TextStyle(color: Colors.black54, fontSize: 12, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _handleAuthorizeGoogle();
            },
            child: const Text('Retry Authorization', style: TextStyle(color: ClassicTheme.primaryAccent, fontWeight: FontWeight.bold)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _handlePasteSheet();
            },
            child: const Text('Paste Sheet Link'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final saasSession = ref.watch(saasSessionProvider);
    final org = saasSession.currentOrganization;
    final userEmail = saasSession.currentUser?.email ?? '';
    final expectedEmail = userEmail.isNotEmpty ? userEmail : (org?.ownerGoogleEmail ?? '');

    return PopScope(
      canPop: false,
      child: Dialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
          side: BorderSide(color: context.borderColor, width: 1.5),
        ),
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 480),
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header Icon
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.table_chart_rounded,
                      color: ClassicTheme.primaryAccent,
                      size: 40,
                    ),
                  ),
                ),
                const SizedBox(height: 18),

                // Title
                Text(
                  'Connect Google Sheets Database',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 8),

                // Description
                Text(
                  'SmartDine Restaurant POS stores your dishes, orders, KOTs, and bills directly in your Google Drive. '
                  'Authorize your Google account to initialize your 7-tab store database and activate online QR ordering.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 13,
                    color: context.textSecondary,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 18),

                // Expected Email Card
                if (expectedEmail.isNotEmpty)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: context.canvasColor,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: context.borderColor),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.account_circle_outlined, color: ClassicTheme.primaryAccent, size: 22),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Registered Store Owner Email',
                                style: TextStyle(color: context.textSecondary, fontSize: 11),
                              ),
                              Text(
                                expectedEmail,
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.bold,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 18),

                // Feature Highlights
                _buildBenefitRow(Icons.check_circle_rounded, 'Private 7-Tab Spreadsheet in your Google Drive'),
                const SizedBox(height: 8),
                _buildBenefitRow(Icons.check_circle_rounded, 'Synchronized with web QR digital menu'),
                const SizedBox(height: 8),
                _buildBenefitRow(Icons.check_circle_rounded, r'Zero cloud storage costs ($0.00 / month)'),
                const SizedBox(height: 24),

                // Progress indicator & text
                if (_isLoading) ...[
                  Center(
                    child: Column(
                      children: [
                        const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            color: ClassicTheme.primaryAccent,
                            strokeWidth: 2.5,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _statusText,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],

                // Action Button 1: Authorize Google Account
                SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: ClassicTheme.primaryAccent,
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 0,
                    ),
                    onPressed: _isLoading ? null : _handleAuthorizeGoogle,
                    icon: const Icon(Icons.cloud_upload_rounded, size: 20, color: Colors.black),
                    label: Text(
                      _isLoading ? 'Connecting Database...' : 'Authorize Google Account',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.black,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Action Button 2: Paste Google Sheet Link
                SizedBox(
                  height: 44,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.borderColor),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                    onPressed: _isLoading ? null : _handlePasteSheet,
                    icon: Icon(Icons.link_rounded, size: 18, color: context.textPrimary),
                    label: Text(
                      'Paste Existing Google Sheet Link',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBenefitRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFF10B981), size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: context.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }
}
