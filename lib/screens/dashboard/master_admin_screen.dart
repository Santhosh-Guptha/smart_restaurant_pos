import 'dart:math';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:http/http.dart' as http;
import '../../providers/saas_session_provider.dart';
import '../../providers/auth_provider.dart';
import '../../services/apps_script_backend_service.dart';
import '../../services/client_ledger_cloud_router_service.dart';
import '../../services/database_cleanup_service.dart';
import '../../services/smtp_email_service.dart';
import '../../core/constants.dart';
import '../../utils/ui_feedback.dart';
import '../../core/classic_theme.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../../providers/theme_provider.dart';
import '../../core/subscription_plan_model.dart';
import '../../services/package_service.dart';
import '../../services/subscription_plan_service.dart';
import '../../services/tenant_provisioning_service.dart';
import '../admin/views/admin_dashboard_view.dart';
import '../admin/views/admin_inquiries_view.dart';
import '../admin/views/admin_features_view.dart';
import '../admin/views/admin_encyclopedia_view.dart';
import '../admin/views/admin_packages_view.dart';
import '../admin/views/admin_plans_view.dart';
import '../admin/views/admin_migrations_view.dart';
import '../admin/dialogs/tenant_access_dialog.dart';
import '../admin/widgets/tenant_package_editor.dart';

class MasterAdminScreen extends ConsumerStatefulWidget {
  const MasterAdminScreen({super.key});

  @override
  ConsumerState<MasterAdminScreen> createState() => _MasterAdminScreenState();
}

class _MasterAdminScreenState extends ConsumerState<MasterAdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  int _selectedNavIndex = 0;

  /// The views visited, oldest first, so Back retraces the path.
  ///
  /// This screen is one route holding an `IndexedStack`: opening a card swaps
  /// the index rather than pushing, and for a platform admin it is also the
  /// *home* route (`main.dart` builds it as `homeScreen`). So a back gesture
  /// had nothing to pop but the screen itself, and Android closed the app
  /// mid-session. Back now walks this list and only leaves from the dashboard.
  final List<int> _navHistory = <int>[0];

  bool _isSidebarExpanded = true;
  StreamSubscription<QuerySnapshot>? _regRequestsSub;
  StreamSubscription<QuerySnapshot>? _inquiriesSub;
  final Set<String> _knownRequestIds = {};
  final Set<String> _knownInquiryIds = {};
  bool _initialLoadDone = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _listenForIncomingRequests();
    // The four starter packages, kept in step with the resolver's profiles.
    // Seeded from the console only: every till re-aligning platform
    // documents on cold start was waste, and the tills fall back to the
    // in-code starters when the collection is empty anyway.
    unawaited(PackageService.ensureStarters());
  }

  void _listenForIncomingRequests() {
    // 1. Listen for new Free Trial registrations
    _regRequestsSub = FirebaseFirestore.instance
        .collection('registration_requests')
        .snapshots()
        .listen((snap) {
      if (!_initialLoadDone) {
        for (var doc in snap.docs) {
          _knownRequestIds.add(doc.id);
        }
        return;
      }
      for (var change in snap.docChanges) {
        if (change.type == DocumentChangeType.added && !_knownRequestIds.contains(change.doc.id)) {
          _knownRequestIds.add(change.doc.id);
          final data = change.doc.data() ?? {};
          final name = data['clientName'] ?? 'New Client';
          final shop = data['shopName'] ?? '';
          _triggerNewRequestAlert(
            title: "🔔 New Free Trial Registration!",
            message: "$name${shop.isNotEmpty ? ' ($shop)' : ''} registered for a 14-day Free Trial.",
          );
        }
      }
    });

    // 2. Listen for new Commercial Plan Inquiries
    _inquiriesSub = FirebaseFirestore.instance
        .collection('business_inquiries')
        .snapshots()
        .listen((snap) {
      if (!_initialLoadDone) {
        for (var doc in snap.docs) {
          _knownInquiryIds.add(doc.id);
        }
        _initialLoadDone = true;
        return;
      }
      for (var change in snap.docChanges) {
        if (change.type == DocumentChangeType.added && !_knownInquiryIds.contains(change.doc.id)) {
          _knownInquiryIds.add(change.doc.id);
          final data = change.doc.data() ?? {};
          final name = data['clientName'] ?? 'New Lead';
          final brand = data['brandName'] ?? '';
          final plan = data['selectedPlan'] ?? 'Commercial';
          _triggerNewRequestAlert(
            title: "💼 New $plan Inquiry!",
            message: "$name${brand.isNotEmpty ? ' ($brand)' : ''} submitted a $plan inquiry.",
          );
        }
      }
    });

    // Mark initial load done after 2 seconds
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        _initialLoadDone = true;
      }
    });
  }

  void _triggerNewRequestAlert({required String title, required String message}) {
    HapticFeedback.heavyImpact();
    SystemSound.play(SystemSoundType.alert);
    if (mounted) {
      AppToast.showSuccess(
        context,
        title,
        subtitle: "$message\nTap 'Requests' tab to review.",
      );
    }
  }

  @override
  void dispose() {
    _regRequestsSub?.cancel();
    _inquiriesSub?.cancel();
    _tabController.dispose();
    super.dispose();
  }

  void _showClearDatabaseDialog() {
    final confirmationController = TextEditingController();
    bool isCleaning = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: context.borderColor),
            ),
            title: const Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: ClassicTheme.dangerRed, size: 24),
                SizedBox(width: 8),
                Text("Clear All Client Data", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "This action will remove all client organizations, licenses, outlets, bills, and registration requests from the database.\n\n"
                    "🛡️ Master Admin Protection Guarantee:\n"
                    "The master admin user ($kAdminEmail) will NEVER be deleted and will remain fully active.",
                    style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
                  ),
                  const SizedBox(height: 16),
                  Text("Type 'RESET_DATA' to confirm:", style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 6),
                  TextField(
                    controller: confirmationController,
                    style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold),
                    decoration: ClassicTheme.inputDecorationFor(
                      context,
                      hintText: "RESET_DATA",
                    ),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: isCleaning ? null : () => Navigator.pop(ctx),
                child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                onPressed: (isCleaning || confirmationController.text.trim() != 'RESET_DATA')
                    ? null
                    : () async {
                        setDialogState(() => isCleaning = true);
                        final res = await DatabaseCleanupService.resetDatabaseKeepMasterAdmin();
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                          if (res['success'] == true) {
                            if (mounted) AppToast.showSuccess(context, res['message']);
                          } else {
                            if (mounted) AppToast.showError(context, res['message']);
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.dangerRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: isCleaning
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text("Confirm & Reset", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showSmtpSettingsDialog() {
    final hostController = TextEditingController();
    final portController = TextEditingController();
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final fromNameController = TextEditingController();
    final testEmailController = TextEditingController(text: kAdminEmail);
    bool isSsl = false;
    bool isLoading = true;
    bool isSaving = false;
    bool isTesting = false;
    bool obscurePassword = true;
    bool hasFetched = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          if (!hasFetched) {
            hasFetched = true;
            SmtpEmailService.getSmtpConfig().then((cfg) {
              hostController.text = cfg.host;
              portController.text = cfg.port.toString();
              usernameController.text = cfg.username;
              passwordController.text = cfg.password;
              fromNameController.text = cfg.fromName;
              isSsl = cfg.isSsl;
              if (ctx.mounted) setDialogState(() => isLoading = false);
            }).catchError((_) {
              if (ctx.mounted) setDialogState(() => isLoading = false);
            });
          }

          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: ClassicTheme.infoBlue.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.mark_email_read_rounded, color: ClassicTheme.infoBlue, size: 22),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Platform SMTP Mail Settings",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
                if (!isLoading)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: (usernameController.text.isNotEmpty && passwordController.text.isNotEmpty)
                          ? ClassicTheme.successEmerald.withValues(alpha: 0.15)
                          : ClassicTheme.warningAmber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      (usernameController.text.isNotEmpty && passwordController.text.isNotEmpty) ? "CONFIGURED" : "PENDING SETUP",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: (usernameController.text.isNotEmpty && passwordController.text.isNotEmpty) ? ClassicTheme.successEmerald : ClassicTheme.warningAmber,
                      ),
                    ),
                  ),
              ],
            ),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: min(520, MediaQuery.of(ctx).size.width * 0.92),
              ),
              child: isLoading
                  ? const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
                  : SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            "Configure the central SMTP mail server used for sending verification OTPs, tenant onboarding credentials, and staff alert emails.",
                            style: TextStyle(color: context.textSecondary, fontSize: 12, height: 1.4),
                          ),
                          const SizedBox(height: 16),
                          Row(
                            children: [
                              Expanded(
                                flex: 3,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("SMTP Host *", style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 6),
                                    TextField(
                                      controller: hostController,
                                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                                      decoration: ClassicTheme.inputDecorationFor(context, hintText: "smtp.gmail.com"),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 1,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Port *", style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                                    const SizedBox(height: 6),
                                    TextField(
                                      controller: portController,
                                      keyboardType: TextInputType.number,
                                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                                      decoration: ClassicTheme.inputDecorationFor(context, hintText: "587"),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Text("Sender Email / Username *", style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: usernameController,
                            style: TextStyle(color: context.textPrimary, fontSize: 13),
                            decoration: ClassicTheme.inputDecorationFor(context, hintText: "e.g. yourname@gmail.com"),
                          ),
                          const SizedBox(height: 14),
                          Text("SMTP App Password *", style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: passwordController,
                            obscureText: obscurePassword,
                            style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                            decoration: ClassicTheme.inputDecorationFor(
                              context,
                              hintText: "16-character Google App Password",
                              suffixIcon: IconButton(
                                icon: Icon(obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: context.textSecondary),
                                onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                              ),
                            ),
                          ),
                          const SizedBox(height: 14),
                          Text("Sender Display Name", style: TextStyle(color: context.textSecondary, fontSize: 12, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          TextField(
                            controller: fromNameController,
                            style: TextStyle(color: context.textPrimary, fontSize: 13),
                            decoration: ClassicTheme.inputDecorationFor(context, hintText: "SmartDine POS"),
                          ),
                          const SizedBox(height: 14),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text("Use SSL / TLS Direct Connection", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                            subtitle: Text("Enable if connecting directly via Port 465 (Gmail Port 587 uses STARTTLS by default)", style: TextStyle(color: context.textSecondary, fontSize: 12)),
                            value: isSsl,
                            activeThumbColor: ClassicTheme.infoBlue,
                            onChanged: (v) => setDialogState(() => isSsl = v),
                          ),
                          const Divider(height: 28),
                          Text("Send Test Email", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 6),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: testEmailController,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  decoration: ClassicTheme.inputDecorationFor(context, hintText: "recipient@domain.com"),
                                ),
                              ),
                              const SizedBox(width: 8),
                              ElevatedButton.icon(
                                onPressed: isTesting
                                    ? null
                                    : () async {
                                        if (testEmailController.text.trim().isEmpty) {
                                          AppToast.showError(context, "Please enter a test recipient email.");
                                          return;
                                        }
                                        setDialogState(() => isTesting = true);
                                        try {
                                          final cfg = SmtpConfig(
                                            host: hostController.text.trim().isNotEmpty ? hostController.text.trim() : 'smtp.gmail.com',
                                            port: int.tryParse(portController.text.trim()) ?? 587,
                                            isSsl: isSsl,
                                            username: usernameController.text.trim(),
                                            password: passwordController.text.trim(),
                                            fromName: fromNameController.text.trim().isNotEmpty ? fromNameController.text.trim() : 'SmartDine POS',
                                          );
                                          await SmtpEmailService.sendTestEmail(
                                            toEmail: testEmailController.text.trim(),
                                            config: cfg,
                                          );
                                          if (ctx.mounted && mounted) {
                                            AppToast.showSuccess(context, "Test email sent successfully to ${testEmailController.text.trim()}!");
                                          }
                                        } catch (e) {
                                          if (ctx.mounted && mounted) {
                                            AppToast.showError(context, "Test email failed: $e");
                                          }
                                        } finally {
                                          if (ctx.mounted) setDialogState(() => isTesting = false);
                                        }
                                      },
                                icon: isTesting
                                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Icon(Icons.send_rounded, size: 16),
                                label: const Text("Send Test", style: TextStyle(fontSize: 12)),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: ClassicTheme.infoBlue,
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
            ),
            actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : () async {
                  setDialogState(() => isSaving = true);
                  try {
                    final cfg = SmtpConfig(
                      host: hostController.text.trim().isNotEmpty ? hostController.text.trim() : 'smtp.gmail.com',
                      port: int.tryParse(portController.text.trim()) ?? 587,
                      isSsl: isSsl,
                      username: usernameController.text.trim(),
                      password: passwordController.text.trim(),
                      fromName: fromNameController.text.trim().isNotEmpty ? fromNameController.text.trim() : 'SmartDine POS',
                    );
                    await SmtpEmailService.saveSmtpConfig(cfg);
                    if (ctx.mounted && mounted) {
                      Navigator.pop(ctx);
                      AppToast.showSuccess(context, "SMTP Mail Server Configuration Saved!");
                    }
                  } catch (e) {
                    setDialogState(() => isSaving = false);
                    if (ctx.mounted && mounted) AppToast.showError(context, e.toString());
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.infoBlue,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text("Save SMTP Config", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showWebhookSettingsDialog() {
    final urlController = TextEditingController(text: AppsScriptBackendService.getWebhookUrl());
    bool isTesting = false;
    String? testResult;
    bool testSuccess = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: ClassicTheme.successEmerald.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.cloud_sync_rounded, color: ClassicTheme.successEmerald, size: 22),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: Text(
                    "Store Cloud Webhook",
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: ClassicTheme.dialogWidth(context, 480),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Automated cloud webhook creates dedicated databases with tabs (Bills, Inventory, Customers, Expenses) linked to your administrator account.",
                    style: TextStyle(color: context.textSecondary, fontSize: 12.5, height: 1.4),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    "Apps Script Webhook URL:",
                    style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  TextField(
                    controller: urlController,
                    maxLines: 2,
                    style: TextStyle(color: context.textPrimary, fontSize: 12),
                    decoration: ClassicTheme.inputDecorationFor(
                      context,
                      hintText: "https://script.google.com/macros/s/.../exec",
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (testResult != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: testSuccess ? ClassicTheme.successEmerald.withValues(alpha: 0.1) : ClassicTheme.dangerRed.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: testSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed),
                      ),
                      child: Row(
                        children: [
                          Icon(testSuccess ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                              color: testSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              testResult!,
                              style: TextStyle(
                                  color: testSuccess ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                  Row(
                    children: [
                      OutlinedButton.icon(
                        onPressed: isTesting
                            ? null
                            : () async {
                                final url = urlController.text.trim();
                                if (url.isEmpty || !url.startsWith('https://script.google.com')) {
                                  setDialogState(() {
                                    testResult = "Please enter a valid Google Apps Script Webhook URL.";
                                    testSuccess = false;
                                  });
                                  return;
                                }
                                setDialogState(() {
                                  isTesting = true;
                                  testResult = null;
                                });
                                try {
                                  final res = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
                                  if (res.statusCode >= 200 && res.statusCode < 300) {
                                    setDialogState(() {
                                      isTesting = false;
                                      testSuccess = true;
                                      testResult = "✓ Webhook connection successful! Script is live.";
                                    });
                                  } else {
                                    setDialogState(() {
                                      isTesting = false;
                                      testSuccess = false;
                                      testResult = "HTTP ${res.statusCode}: Failed to connect to webhook.";
                                    });
                                  }
                                } catch (e) {
                                  setDialogState(() {
                                    isTesting = false;
                                    testSuccess = false;
                                    testResult = "Connection error: $e";
                                  });
                                }
                              },
                        icon: isTesting
                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                            : const Icon(Icons.bolt_rounded, size: 16),
                        label: Text(isTesting ? "Testing..." : "Test Connection"),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: ClassicTheme.successEmerald, foregroundColor: Colors.white),
                onPressed: () async {
                  final url = urlController.text.trim();
                  await AppsScriptBackendService.setWebhookUrl(url);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    if (mounted) {
                      AppToast.showSuccess(
                        context,
                        "Google Apps Script Webhook Saved!",
                        subtitle: "New client stores will automatically create Google Spreadsheets in your Drive.",
                      );
                    }
                  }
                },
                child: const Text("Save URL", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Switch views. Every path into the `IndexedStack` goes through here so
  /// the history cannot drift from what is on screen.
  void _goToNav(int index) {
    if (index == _selectedNavIndex) return;
    setState(() {
      _selectedNavIndex = index;
      // Revisiting a view already behind us rewinds to it rather than growing
      // the list, so Back never walks a loop the admin did not take.
      final seen = _navHistory.indexOf(index);
      if (seen >= 0) {
        _navHistory.removeRange(seen + 1, _navHistory.length);
      } else {
        _navHistory.add(index);
      }
    });
  }

  /// Back: one step along the path, and only then out of the console.
  Future<void> _handleBack() async {
    if (_navHistory.length > 1) {
      setState(() {
        _navHistory.removeLast();
        _selectedNavIndex = _navHistory.last;
      });
      return;
    }

    // At the dashboard. If something pushed this screen, go back to it.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
      return;
    }

    // Otherwise this is the home route and leaving means closing the console.
    // Worth asking: an admin halfway through onboarding a tenant should not
    // lose the screen to a stray edge swipe.
    final leave = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Close the console?'),
        content: const Text(
            'You are on the dashboard, so going back closes SmartDine.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Stay')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Close', style: TextStyle(color: ctx.dangerColor)),
          ),
        ],
      ),
    );
    if (leave == true) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 850;
    final sidebarContent = _buildSidebarContent(context, isMobile: isMobile);

    return PopScope(
      // Never automatic: the whole point is that popping this route is what
      // used to close the app. `_handleBack` decides what Back means here.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _handleBack();
      },
      child: Scaffold(
      backgroundColor: context.canvasColor,
      drawer: isMobile ? Drawer(backgroundColor: context.surfaceColor, child: SafeArea(child: sidebarContent)) : null,
      body: SafeArea(
        child: Row(
          children: [
            if (!isMobile)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                width: _isSidebarExpanded ? 240 : 72,
                child: sidebarContent,
              ),
            Expanded(
              child: Column(
                children: [
                  _buildTopBar(context, isMobile: isMobile),
                  Expanded(
                    child: Material(
                      color: context.canvasColor,
                      child: IndexedStack(
                        index: _selectedNavIndex,
                        children: [
                          AdminDashboardView(
                            onNavigateToInquiries: () => _goToNav(1),
                            onNavigateToTenants: () => _goToNav(2),
                          ),
                          AdminInquiriesView(
                            onOnboardLead: (lead) {
                              OrganizationsTab.showOnboardOrganizationDialog(
                                context,
                                initialName: lead.clientName,
                                initialShopName: lead.brandName,
                                initialEmail: lead.email,
                                initialMobile: lead.phone,
                                initialAddress: lead.city,
                                requestId: lead.id,
                              );
                            },
                          ),
                          const OrganizationsTab(),
                          const AdminFeaturesView(),
                          const AdminPlansView(),
                          const AuditLogsTab(),
                          const AppUpdatesTab(),
                          const AdminEncyclopediaView(),
                          const AdminPackagesView(),
                          const AdminMigrationsView(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, {required bool isMobile}) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 950;
    final isVeryCompact = screenWidth < 650;

    final sectionTitles = [
      ("Dashboard & SaaS Analytics", "Live platform metrics, active tenants & pending alerts"),
      ("Inquiries & Pricing Desk", "Dual-feed commercial proposals and trial requests"),
      ("Tenant & Store Governance", "Manage client organizations, licenses, and branches"),
      ("Plan & Feature Allocation", "1-Click plan presets and interactive feature toggle matrix"),
      ("Subscription Plan Templates", "Platform tiers, limits, and public pricing definitions"),
      ("Platform Audit Logs", "Comprehensive chronological security and admin audit trail"),
      ("App Updates & Maintenance", "Version management, release channels, and updates"),
    ];

    final currentTitle = _selectedNavIndex < sectionTitles.length
        ? sectionTitles[_selectedNavIndex]
        : ("Control Panel", "Platform Administration");

    return Container(
      height: isVeryCompact ? 56 : 64,
      padding: EdgeInsets.symmetric(horizontal: isVeryCompact ? 8 : 16),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(
          bottom: BorderSide(color: context.borderColor),
        ),
      ),
      child: Row(
        children: [
          if (isMobile) ...[
            Builder(
              builder: (ctx) => IconButton(
                icon: const Icon(Icons.menu_rounded),
                color: context.textPrimary,
                tooltip: "Open Menu",
                padding: isVeryCompact ? const EdgeInsets.all(4) : const EdgeInsets.all(8),
                constraints: isVeryCompact ? const BoxConstraints() : null,
                onPressed: () => Scaffold.of(ctx).openDrawer(),
              ),
            ),
            SizedBox(width: isVeryCompact ? 4 : 8),
          ],
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentTitle.$1,
                  style: TextStyle(
                    fontSize: isVeryCompact ? 13 : 15.5,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (!isVeryCompact)
                  Text(
                    currentTitle.$2,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSecondary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: () => OrganizationsTab.showOnboardOrganizationDialog(context),
            icon: const Icon(Icons.add_business_rounded, size: 14),
            label: Text(
              isVeryCompact ? "Onboard" : "Onboard Tenant",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccentIndigo,
              foregroundColor: Colors.white,
              padding: EdgeInsets.symmetric(horizontal: isVeryCompact ? 8 : 14, vertical: isVeryCompact ? 6 : 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
          SizedBox(width: isVeryCompact ? 2 : 6),
          if (!isCompact) ...[
            IconButton(
              icon: const Icon(Icons.cloud_sync_rounded, color: ClassicTheme.successEmerald, size: 20),
              tooltip: "Cloud Database Webhook",
              onPressed: _showWebhookSettingsDialog,
            ),
            IconButton(
              icon: const Icon(Icons.email_outlined, color: ClassicTheme.infoBlue, size: 20),
              tooltip: "Platform SMTP Email",
              onPressed: _showSmtpSettingsDialog,
            ),
            IconButton(
              icon: const Icon(Icons.cleaning_services_rounded, color: ClassicTheme.warningAmber, size: 20),
              tooltip: "Clean Database (Keep Admin)",
              onPressed: _showClearDatabaseDialog,
            ),
          ] else ...[
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert_rounded, color: context.textPrimary, size: 20),
              padding: isVeryCompact ? EdgeInsets.zero : const EdgeInsets.all(8),
              constraints: isVeryCompact ? const BoxConstraints() : null,
              tooltip: "System Settings",
              color: context.surfaceColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: context.borderColor),
              ),
              onSelected: (val) {
                switch (val) {
                  case 'webhook':
                    _showWebhookSettingsDialog();
                    break;
                  case 'smtp':
                    _showSmtpSettingsDialog();
                    break;
                  case 'cleanup':
                    _showClearDatabaseDialog();
                    break;
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(
                  value: 'webhook',
                  child: Row(
                    children: [
                      Icon(Icons.cloud_sync_rounded, color: ClassicTheme.successEmerald, size: 18),
                      SizedBox(width: 10),
                      Text('Cloud Webhook URL', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                const PopupMenuItem(
                  value: 'smtp',
                  child: Row(
                    children: [
                      Icon(Icons.email_outlined, color: ClassicTheme.infoBlue, size: 18),
                      SizedBox(width: 10),
                      Text('Platform SMTP Email', style: TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'cleanup',
                  child: Row(
                    children: [
                      Icon(Icons.cleaning_services_rounded, color: ClassicTheme.dangerRed, size: 18),
                      SizedBox(width: 10),
                      Text('Clean Database (Keep Admin)', style: TextStyle(fontSize: 13, color: ClassicTheme.dangerRed)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSidebarContent(BuildContext context, {required bool isMobile}) {
    final showExpanded = isMobile || _isSidebarExpanded;

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        border: Border(
          right: BorderSide(color: context.borderColor),
        ),
      ),
      child: Column(
        children: [
          Container(
            height: 64,
            padding: EdgeInsets.symmetric(horizontal: showExpanded ? 16 : 8),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.borderColor),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    Icons.restaurant_rounded,
                    color: ClassicTheme.primaryAccentIndigo,
                    size: 20,
                  ),
                ),
                if (showExpanded) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "SmartDine",
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary,
                          ),
                        ),
                        Text(
                          "Super Admin Console",
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                if (!isMobile)
                  IconButton(
                    icon: Icon(
                      _isSidebarExpanded ? Icons.menu_open_rounded : Icons.menu_rounded,
                      size: 20,
                      color: context.textSecondary,
                    ),
                    tooltip: _isSidebarExpanded ? "Collapse Sidebar" : "Expand Sidebar",
                    onPressed: () => setState(() => _isSidebarExpanded = !_isSidebarExpanded),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
              children: [
                _buildNavItem(
                  context,
                  index: 0,
                  title: "Dashboard",
                  icon: Icons.dashboard_outlined,
                  activeIcon: Icons.dashboard_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 1,
                  title: "Inquiries & Leads",
                  icon: Icons.mark_email_unread_outlined,
                  activeIcon: Icons.mark_email_unread_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                  badgeWidget: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('registration_requests')
                        .where('status', isEqualTo: 'PENDING')
                        .snapshots(),
                    builder: (context, regSnap) {
                      return StreamBuilder<QuerySnapshot>(
                        stream: FirebaseFirestore.instance.collection('business_inquiries').snapshots(),
                        builder: (context, inqSnap) {
                          final regCount = regSnap.hasData ? regSnap.data!.docs.length : 0;
                          int inqCount = 0;
                          if (inqSnap.hasData) {
                            inqCount = inqSnap.data!.docs.where((d) {
                              final st = (d.data() as Map<String, dynamic>)['status'];
                              return st == 'NEW_INQUIRY' || st == 'PENDING';
                            }).length;
                          }
                          final total = regCount + inqCount;
                          if (total <= 0) return const SizedBox.shrink();
                          return Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ClassicTheme.warningAmber,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$total',
                              style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
                _buildNavItem(
                  context,
                  index: 2,
                  title: "Tenants & Stores",
                  icon: Icons.business_outlined,
                  activeIcon: Icons.business_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                  badgeWidget: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('renewal_requests')
                        .where('status', isEqualTo: 'PENDING')
                        .snapshots(),
                    builder: (context, snapshot) {
                      final count = snapshot.hasData ? snapshot.data!.docs.length : 0;
                      if (count <= 0) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ClassicTheme.warningAmber,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$count',
                          style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      );
                    },
                  ),
                ),
                _buildNavItem(
                  context,
                  index: 3,
                  title: "Feature Matrix",
                  icon: Icons.tune_outlined,
                  activeIcon: Icons.tune_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 4,
                  title: "Plans",
                  icon: Icons.calendar_month_outlined,
                  activeIcon: Icons.calendar_month_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 5,
                  title: "Audit Logs",
                  icon: Icons.history_edu_outlined,
                  activeIcon: Icons.history_edu_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 6,
                  title: "App Updates",
                  icon: Icons.system_update_alt_outlined,
                  activeIcon: Icons.system_update_alt_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 7,
                  title: "Feature Guide",
                  icon: Icons.menu_book_outlined,
                  activeIcon: Icons.menu_book_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 8,
                  title: "Packages",
                  icon: Icons.inventory_2_outlined,
                  activeIcon: Icons.inventory_2_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                ),
                _buildNavItem(
                  context,
                  index: 9,
                  title: "Migrations",
                  icon: Icons.swap_horiz_outlined,
                  activeIcon: Icons.swap_horiz_rounded,
                  showExpanded: showExpanded,
                  isMobile: isMobile,
                  badgeWidget: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance
                        .collection('organizations')
                        .where('pendingStorageChange.status', isEqualTo: 'PENDING')
                        .snapshots(),
                    builder: (context, snap) {
                      final n = snap.hasData ? snap.data!.docs.length : 0;
                      if (n <= 0) return const SizedBox.shrink();
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ClassicTheme.infoBlue,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          '$n',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12, fontWeight: FontWeight.bold),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: EdgeInsets.symmetric(horizontal: showExpanded ? 12 : 6, vertical: 12),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: context.borderColor),
              ),
            ),
            child: Column(
              children: [
                Consumer(
                  builder: (context, ref, _) {
                    final isDark = ref.watch(themeModeProvider) == ThemeMode.dark;
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: () {
                        ref.read(themeModeProvider.notifier).toggleTheme();
                        HapticFeedback.lightImpact();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          mainAxisAlignment: showExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                          children: [
                            Icon(
                              isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined,
                              size: 18,
                              color: isDark ? ClassicTheme.warningAmber : context.textSecondary,
                            ),
                            if (showExpanded) ...[
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  isDark ? "Light Mode" : "Dark Mode",
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: context.textPrimary,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 4),
                if (showExpanded)
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    decoration: BoxDecoration(
                      color: context.canvasColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: context.borderColor),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.admin_panel_settings_rounded, size: 16, color: ClassicTheme.primaryAccentIndigo),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            kAdminEmail,
                            style: TextStyle(fontSize: 12, color: context.textSecondary),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => ref.read(authProvider.notifier).signOut(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    child: Row(
                      mainAxisAlignment: showExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.logout_rounded, size: 18, color: ClassicTheme.dangerRed),
                        if (showExpanded) ...[
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Text(
                              "Sign Out",
                              style: TextStyle(
                                fontSize: 12,
                                color: ClassicTheme.dangerRed,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNavItem(
    BuildContext context, {
    required int index,
    required String title,
    required IconData icon,
    required IconData activeIcon,
    required bool showExpanded,
    required bool isMobile,
    Widget? badgeWidget,
  }) {
    final isSelected = _selectedNavIndex == index;
    final color = isSelected ? ClassicTheme.primaryAccentIndigo : context.textSecondary;

    return Tooltip(
      message: showExpanded ? '' : title,
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () {
            _goToNav(index);
            if (isMobile) Navigator.of(context).pop();
          },
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: showExpanded ? 12 : 8, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: isSelected
                  ? Border.all(color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.3))
                  : null,
            ),
            child: Row(
              mainAxisAlignment: showExpanded ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                Icon(isSelected ? activeIcon : icon, size: 20, color: color),
                if (showExpanded) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                        color: isSelected ? context.textPrimary : context.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (badgeWidget != null) badgeWidget,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// --- TAB 1: ORGANIZATIONS MANAGEMENT ---

class OrganizationsTab extends ConsumerStatefulWidget {
  const OrganizationsTab({super.key});

  static String generateUniqueOrgId() {
    final now = DateTime.now();
    final year = now.year.toString().substring(2);
    final randomDigits = 1000 + Random().nextInt(9000);
    return "ORG$year$randomDigits";
  }

  static Widget buildFeatureGroup({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required List<Widget> children,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: accentColor.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: accentColor, size: 16),
              const SizedBox(width: 8),
              Text(title, style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 12.5)),
            ],
          ),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(color: context.textSecondary, fontSize: 12)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: children,
          ),
        ],
      ),
    );
  }

  static Widget featureChipWidget({
    required String label,
    required String subtitle,
    required bool selected,
    required Color color,
    required ValueChanged<bool> onSelected,
    String? dependencyTag,
  }) {
    return FilterChip(
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 12,
              color: selected ? color : null,
            ),
          ),
          if (dependencyTag != null) ...[
            const SizedBox(width: 5),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                dependencyTag,
                style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
      selected: selected,
      selectedColor: color.withValues(alpha: 0.2),
      checkmarkColor: color,
      onSelected: onSelected,
    );
  }

  static void showOnboardOrganizationDialog(
    BuildContext context, {
    String? initialName,
    String? initialShopName,
    String? initialCategory,
    String? initialEmail,
    String? initialMobile,
    String? initialAadhaar,
    String? initialPan,
    String? initialGst,
    String? initialAddress,
    String? requestId,
  }) async {
    final availablePlans = await SubscriptionPlanService.getAllPlans();
    if (!context.mounted) return;

    final formKey = GlobalKey<FormState>();

    // Client & Org Information Controllers
    final orgIdController = TextEditingController(text: generateUniqueOrgId());
    final ownerNameController = TextEditingController(text: initialName ?? '');
    final nameController = TextEditingController(
      text: initialShopName ?? (initialName != null ? "$initialName Restaurant" : ''),
    );
    String businessCategory = initialCategory ?? 'Restaurant & Cafe';
    final mobileController = TextEditingController(text: initialMobile ?? '');
    final aadhaarController = TextEditingController(text: initialAadhaar ?? '');
    final panController = TextEditingController(text: initialPan ?? '');
    final gstController = TextEditingController(text: initialGst ?? '');
    final addressController = TextEditingController(text: initialAddress ?? '');
    final ownerEmailController = TextEditingController(text: initialEmail ?? '');
    final ownerPasswordController = TextEditingController(text: '123456');

    // Selected Dynamic Subscription Plan
    SubscriptionPlan selectedPlan = availablePlans.firstWhere(
      (p) => p.isDefaultTrial,
      orElse: () => availablePlans.isNotEmpty ? availablePlans.first : SubscriptionPlanService.fallbackTrialPlan,
    );

    int tableCount = selectedPlan.tableCount;
    String operatingMode = selectedPlan.operatingMode;

    // A package and a plan, in one value object that composes itself, so
    // nothing below can read a half-configured licence. Starts on what a new
    // restaurant most often is: the trial package for its category, on the
    // default trial plan.
    final startPackage = (await PackageService.getById(Verticals.defaultPackageFor(businessCategory))) ??
        TenantPackage.fromProfile(PlanProfile.offlineDineIn);
    if (!context.mounted) return;
    TenantPackageSelection selection =
        TenantPackageSelection(package: startPackage, plan: selectedPlan);

    // Feature Toggles: populated dynamically from the selected plan
    bool isCreating = false;
    bool obscurePassword = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final primaryAccent = ClassicTheme.warningAmber;
            return AlertDialog(
              backgroundColor: context.surfaceColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.borderColor),
              ),
              title: Row(
                children: [
                  Icon(Icons.rocket_launch_rounded, color: primaryAccent, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Onboard New Restaurant Client",
                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 17),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: primaryAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      "Dynamic Plan Onboarding",
                      style: TextStyle(color: primaryAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: ClassicTheme.dialogWidth(context, 650),
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // SECTION 1: RESTAURANT & OWNER IDENTITY
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.storefront_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("1. Restaurant & Owner Identity", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: orgIdController,
                                style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold),
                                decoration: InputDecoration(
                                  labelText: "Organization ID *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.tag_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: nameController,
                                style: TextStyle(color: context.textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Restaurant / Brand Name *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.restaurant_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: ownerNameController,
                                style: TextStyle(color: context.textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Owner / Proprietor Name *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: mobileController,
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  labelText: "Phone / Mobile *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.phone_android_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: ownerEmailController,
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.emailAddress,
                                decoration: InputDecoration(
                                  labelText: "Login Email Address *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.alternate_email_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) {
                                  if (v == null || v.trim().isEmpty) return "Required";
                                  if (!v.contains('@') || !v.contains('.')) return "Enter valid email";
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: ownerPasswordController,
                                obscureText: obscurePassword,
                                style: TextStyle(color: context.textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Initial Password *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
                                  suffixIcon: IconButton(
                                    icon: Icon(obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 18),
                                    onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                                  ),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.length < 6) ? "Min 6 characters" : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: addressController,
                          style: TextStyle(color: context.textPrimary),
                          decoration: InputDecoration(
                            labelText: "Restaurant Physical Address",
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                            prefixIcon: const Icon(Icons.location_on_outlined, size: 18),
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: gstController,
                                style: TextStyle(color: context.textPrimary),
                                textCapitalization: TextCapitalization.characters,
                                decoration: InputDecoration(
                                  labelText: "GSTIN (Optional)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.receipt_long_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: panController,
                                style: TextStyle(color: context.textPrimary),
                                textCapitalization: TextCapitalization.characters,
                                decoration: InputDecoration(
                                  labelText: "PAN (Optional)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.badge_outlined, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // SECTIONS 2 & 3: PACKAGE, VALIDITY AND ADD-ONS
                        //
                        // One editor for all three. It offers only the storage
                        // modes the package can run, shows included features as
                        // included rather than as switches that would not
                        // survive the resolver, and the licence is written from
                        // what the resolver says — so the tenant gets exactly
                        // what is on this screen.
                        TenantPackageEditor(
                          value: selection,
                          onChanged: (v) => setDialogState(() => selection = v),
                        ),
                        const SizedBox(height: 20),

                        // Quotas the package does not decide.
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.tune_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("Other quotas", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              // Staff count is the plan's to decide, so it is
                              // shown here and edited on the Plans screen.
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: "Max Staff / Users (from plan)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.groups_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                ),
                                child: Text('${selection.plan.maxUsers}',
                                    style: TextStyle(color: context.textPrimary)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: tableCount.toString(),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Table Quota",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.table_restaurant_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => tableCount = int.tryParse(v) ?? tableCount,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: operatingMode,
                          dropdownColor: context.surfaceColor,
                          style: TextStyle(color: context.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Operating Mode",
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                            prefixIcon: const Icon(Icons.room_service_rounded, size: 16),
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'dineFirstPostpaid', child: Text("Dine-In Postpaid")),
                            DropdownMenuItem(value: 'counterPrepaid', child: Text("Fast QSR Prepaid")),
                            DropdownMenuItem(value: 'hybrid', child: Text("Hybrid Dynamic")),
                          ],
                          onChanged: (v) {
                            if (v != null) setDialogState(() => operatingMode = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isCreating ? null : () => Navigator.pop(context),
                  child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
                ),
                ElevatedButton(
                  onPressed: isCreating
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => isCreating = true);

                          try {
                            final orgId = orgIdController.text.trim();
                            final orgName = nameController.text.trim();
                            final ownerName = ownerNameController.text.trim();
                            final email = ownerEmailController.text.trim().toLowerCase();
                            final rawPassword = ownerPasswordController.text;
                            final mobile = mobileController.text.trim();
                            final address = addressController.text.trim();
                            final gst = gstController.text.trim();
                            final pan = panController.text.trim();
                            final aadhaar = aadhaarController.text.trim();

                            // The subscription record matching the chosen
                            // package, so the plan name and billing cycle stay
                            // meaningful. Every limit and feature below comes
                            // from the resolver, not from that record.
                            // The selection *is* a package and a plan now.
                            // What is written is their composition, so the
                            // preview the admin just looked at and the licence
                            // the till reads are the same numbers.
                            final finalPlan = selection.plan.copyWith(
                              maxOutlets: selection.effectiveOutlets,
                              maxDevices: selection.effectiveDevices,
                              maxUsers: selection.plan.maxUsers,
                              tableCount: tableCount,
                              operatingMode: operatingMode,
                              allowedRoles: selection.effectiveRoles,
                              features: selection.resolvedFeatures,
                            );

                            final result = await TenantProvisioningService.provisionTenant(
                              customOrgId: orgId,
                              shopName: orgName,
                              clientName: ownerName,
                              email: email,
                              rawPassword: rawPassword,
                              mobile: mobile,
                              category: businessCategory,
                              address: address.isNotEmpty ? address : null,
                              aadhaar: aadhaar.isNotEmpty ? aadhaar : null,
                              pan: pan.isNotEmpty ? pan : null,
                              gstNo: gst.isNotEmpty ? gst : null,
                              plan: finalPlan,
                              requestId: requestId,
                              storageMode: selection.storageMode,
                              planProfile: selection.profile.id,
                              packageId: selection.packageId,
                              planId: selection.planId,
                            );

                            if (result['success'] != true) {
                              throw Exception(result['message'] ?? "Onboarding failed");
                            }

                            if (context.mounted) {
                              Navigator.pop(context);
                              AppToast.showSuccess(
                                context,
                                "Restaurant Onboarded Successfully",
                                subtitle: "$orgName ($orgId) onboarded with ${finalPlan.name}.",
                              );
                            }
                          } catch (e) {
                            setDialogState(() => isCreating = false);
                            if (context.mounted) {
                              AppToast.showError(context, e, title: "Onboarding Failed");
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: isCreating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Onboard Restaurant", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  ConsumerState<OrganizationsTab> createState() => _OrganizationsTabState();
}

class _OrganizationsTabState extends ConsumerState<OrganizationsTab> {
  final _firestore = FirebaseFirestore.instance;

  void _showAddOrganizationDialog() {
    OrganizationsTab.showOnboardOrganizationDialog(context);
  }

  /// Renewals go through the same package-and-plan editor as every other
  /// licence change, opened as a renewal: the owner's request (if any) seeds
  /// the picker, the term restarts today, and the request is closed when the
  /// licence is written. The per-feature tick-box dialog that used to live
  /// here wrote limits and keys the resolver does not read.
  void _showRenewLicenseDialog(String orgId, String orgName) =>
      TenantAccessDialog.show(context, orgId: orgId, orgName: orgName, renew: true);

  void _showEditOrganizationDialog(String orgId, String orgName) {
    final formKey = GlobalKey<FormState>();

    // Client & Org Information Controllers
    final orgIdController = TextEditingController(text: orgId);
    final ownerNameController = TextEditingController();
    final nameController = TextEditingController(text: orgName);
    String businessCategory = 'Restaurant & Cafe';
    final mobileController = TextEditingController();
    final aadhaarController = TextEditingController();
    final panController = TextEditingController();
    final gstController = TextEditingController();
    final addressController = TextEditingController();
    final ownerEmailController = TextEditingController();
    final ownerPasswordController = TextEditingController();

    // Storage Mode & Database
    String storageMode = 'CLOUD_SYNC';
    String initialStorageMode = 'CLOUD_SYNC';
    String existingSheetId = '';
    String existingSheetUrl = '';
    bool isProvisioningSheet = false;
    bool mustChangePassword = false;

    // Tenant SMTP Configuration
    bool inheritPlatformSmtp = true;
    final smtpHostController = TextEditingController(text: 'smtp.gmail.com');
    final smtpPortController = TextEditingController(text: '587');
    final smtpUsernameController = TextEditingController();
    final smtpPasswordController = TextEditingController();
    final smtpFromNameController = TextEditingController(text: orgName);
    final smtpTestEmailController = TextEditingController(text: kAdminEmail);
    bool smtpIsSsl = false;
    bool obscureSmtpPassword = true;
    bool isTestingSmtp = false;

    bool isLoading = true;
    bool isSaving = false;
    bool obscurePassword = true;
    String? ownerUserId;
    bool dataLoaded = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final primaryAccent = context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue;

            if (!dataLoaded) {
              dataLoaded = true;
              Future.microtask(() async {
                try {
                  // 1. Organization details
                  final orgDoc = await _firestore.collection('organizations').doc(orgId).get();
                  if (orgDoc.exists) {
                    final data = orgDoc.data() ?? {};
                    nameController.text = data['name'] ?? orgName;
                    ownerNameController.text = data['ownerName'] ?? '';
                    businessCategory = data['businessCategory'] ?? 'Restaurant & Cafe';
                    mobileController.text = data['mobile'] ?? data['phone'] ?? '';
                    aadhaarController.text = data['aadhaar'] ?? '';
                    panController.text = data['pan'] ?? '';
                    gstController.text = data['gst'] ?? '';
                    addressController.text = data['address'] ?? '';
                    ownerUserId = data['ownerUserId']?.toString();
                    storageMode = data['storageMode'] ?? 'CLOUD_SYNC';
                    initialStorageMode = storageMode;
                    existingSheetId = (data['googleSheetId'] ?? '').toString();
                    existingSheetUrl = (data['googleSheetUrl'] ?? '').toString();

                    // SMTP
                    if (data['smtpConfig'] is Map) {
                      final smtp = Map<String, dynamic>.from(data['smtpConfig'] as Map);
                      inheritPlatformSmtp = smtp['inheritPlatform'] != false;
                      smtpHostController.text = (smtp['host'] ?? 'smtp.gmail.com').toString();
                      smtpPortController.text = (smtp['port'] ?? 587).toString();
                      smtpUsernameController.text = (smtp['username'] ?? '').toString();
                      smtpPasswordController.text = (smtp['password'] ?? '').toString();
                      smtpFromNameController.text = (smtp['fromName'] ?? nameController.text).toString();
                      smtpIsSsl = smtp['isSsl'] == true;
                    } else {
                      smtpFromNameController.text = nameController.text;
                    }
                  }

                  // 2. Owner User details
                  if (ownerUserId == null || ownerUserId!.isEmpty) {
                    final owners = await _firestore.collection('users')
                        .where('organizationId', isEqualTo: orgId)
                        .where('role', isEqualTo: 'CLIENT')
                        .limit(1)
                        .get();
                    if (owners.docs.isNotEmpty) {
                      ownerUserId = owners.docs.first.id;
                    } else {
                      final altOwners = await _firestore.collection('users')
                          .where('organizationId', isEqualTo: orgId)
                          .where('role', isEqualTo: 'OWNER')
                          .limit(1)
                          .get();
                      if (altOwners.docs.isNotEmpty) {
                        ownerUserId = altOwners.docs.first.id;
                      }
                    }
                  }

                  if (ownerUserId != null && ownerUserId!.isNotEmpty) {
                    final userDoc = await _firestore.collection('users').doc(ownerUserId).get();
                    if (userDoc.exists) {
                      final uData = userDoc.data()!;
                      ownerEmailController.text = uData['email'] ?? '';
                      mustChangePassword = uData['mustChangePassword'] == true;
                      if (ownerNameController.text.isEmpty) {
                        ownerNameController.text = uData['fullName'] ?? '';
                      }
                      if (mobileController.text.isEmpty) {
                        mobileController.text = uData['phone'] ?? '';
                      }
                    }
                  }
                } catch (e) {
                  debugPrint("Error loading tenant configs for edit: $e");
                } finally {
                  if (context.mounted) {
                    setDialogState(() => isLoading = false);
                  }
                }
              });
            }

            return AlertDialog(
              backgroundColor: context.surfaceColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.borderColor),
              ),
              title: Row(
                children: [
                  Icon(Icons.edit_rounded, color: primaryAccent, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Edit Tenant Profile & Gateways",
                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 17),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: primaryAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      "ID: $orgId",
                      style: TextStyle(color: primaryAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(650.0, MediaQuery.of(context).size.width * 0.94),
                ),
                child: isLoading
                    ? SizedBox(
                        height: 300,
                        child: Center(
                          child: CircularProgressIndicator(color: primaryAccent),
                        ),
                      )
                    : SingleChildScrollView(
                        child: Form(
                          key: formKey,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // ── SECTION 1: CLIENT & BUSINESS PROFILE ─────────────
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                decoration: BoxDecoration(
                                  color: primaryAccent.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.storefront_rounded, color: primaryAccent, size: 16),
                                    const SizedBox(width: 6),
                                    Text("1. Client & Business Profile", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Unique Org ID (Fixed / Read-only)
                              TextFormField(
                                controller: orgIdController,
                                readOnly: true,
                                style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, letterSpacing: 1.1),
                                decoration: InputDecoration(
                                  labelText: "Organization ID (Fixed)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: Icon(Icons.fingerprint, size: 18, color: primaryAccent),
                                  suffixIcon: const Icon(Icons.lock_outline, size: 18, color: Colors.grey),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                              ),
                              const SizedBox(height: 10),

                              // Client Name & Business Name
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: ownerNameController,
                                      style: TextStyle(color: context.textPrimary),
                                      decoration: InputDecoration(
                                        labelText: "Client Name *",
                                        hintText: "Owner full name",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.person_outline, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                      validator: (v) => v == null || v.trim().isEmpty ? "Client name is required" : null,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: nameController,
                                      style: TextStyle(color: context.textPrimary),
                                      decoration: InputDecoration(
                                        labelText: "Business / Shop Name *",
                                        hintText: "Shop name",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.store_outlined, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                      validator: (v) => v == null || v.trim().isEmpty ? "Business name is required" : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // Business Category & Mobile Number
                              Row(
                                children: [
                                  Expanded(
                                    child: DropdownButtonFormField<String>(
                                      initialValue: businessCategory,
                                      dropdownColor: context.surfaceColor,
                                      style: TextStyle(color: context.textPrimary, fontSize: 13),
                                      decoration: InputDecoration(
                                        labelText: "Business Category",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.category_outlined, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                      items: const [
                                        DropdownMenuItem(value: 'Restaurant & Cafe', child: Text('Restaurant & Cafe')),
                                        DropdownMenuItem(value: 'Supermarket / Retail', child: Text('Supermarket / Retail')),
                                        DropdownMenuItem(value: 'Bakery & Sweets', child: Text('Bakery & Sweets')),
                                        DropdownMenuItem(value: 'Clothing & Apparel', child: Text('Clothing & Apparel')),
                                        DropdownMenuItem(value: 'Electronics & Mobile', child: Text('Electronics & Mobile')),
                                        DropdownMenuItem(value: 'Pharmacy & Medical', child: Text('Pharmacy & Medical')),
                                        DropdownMenuItem(value: 'Hardware & Electrical', child: Text('Hardware & Electrical')),
                                        DropdownMenuItem(value: 'General Store', child: Text('General Store')),
                                        DropdownMenuItem(value: 'Other Business', child: Text('Other Business')),
                                      ],
                                      onChanged: (v) {
                                        if (v != null) {
                                          setDialogState(() => businessCategory = v);
                                        }
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: mobileController,
                                      style: TextStyle(color: context.textPrimary),
                                      keyboardType: TextInputType.phone,
                                      decoration: InputDecoration(
                                        labelText: "Mobile Number (Optional)",
                                        hintText: "10-digit mobile",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.phone_android_outlined, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // Client Login Email & Password Update
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: ownerEmailController,
                                      style: TextStyle(color: context.textPrimary),
                                      keyboardType: TextInputType.emailAddress,
                                      decoration: InputDecoration(
                                        labelText: "Client Login Email *",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.email_outlined, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                      validator: (v) => v == null || !v.contains('@') ? "Valid email required" : null,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: ownerPasswordController,
                                      style: TextStyle(color: context.textPrimary),
                                      obscureText: obscurePassword,
                                      decoration: InputDecoration(
                                        labelText: "New Password (Optional)",
                                        hintText: "Leave blank to keep current",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.lock_outline, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                        suffixIcon: IconButton(
                                          icon: Icon(
                                            obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                            color: context.textSecondary,
                                            size: 18,
                                          ),
                                          onPressed: () {
                                            setDialogState(() => obscurePassword = !obscurePassword);
                                          },
                                        ),
                                      ),
                                      validator: (v) {
                                        if (v != null && v.isNotEmpty && v.length < 6) {
                                          return "Min 6 characters";
                                        }
                                        return null;
                                      },
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // Optional Compliance Details: Aadhaar, PAN, GST No, Address
                              Row(
                                children: [
                                  Expanded(
                                    child: TextFormField(
                                      controller: aadhaarController,
                                      style: TextStyle(color: context.textPrimary),
                                      keyboardType: TextInputType.number,
                                      decoration: InputDecoration(
                                        labelText: "Aadhaar No (Optional)",
                                        hintText: "12-digit Aadhaar",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.badge_outlined, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: panController,
                                      style: TextStyle(color: context.textPrimary),
                                      textCapitalization: TextCapitalization.characters,
                                      decoration: InputDecoration(
                                        labelText: "PAN Card (Optional)",
                                        hintText: "10-digit PAN",
                                        labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                        prefixIcon: const Icon(Icons.credit_card_outlined, size: 18),
                                        enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                        focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              TextFormField(
                                controller: gstController,
                                style: TextStyle(color: context.textPrimary),
                                textCapitalization: TextCapitalization.characters,
                                decoration: InputDecoration(
                                  labelText: "GSTIN (Optional)",
                                  hintText: "15-digit GSTIN",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.receipt_long_outlined, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                              ),
                              const SizedBox(height: 10),

                              TextFormField(
                                controller: addressController,
                                style: TextStyle(color: context.textPrimary),
                                maxLines: 2,
                                decoration: InputDecoration(
                                  labelText: "Business Address (Optional)",
                                  hintText: "Street, Area, City, State, PIN",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.location_on_outlined, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                              ),
                              const SizedBox(height: 10),

                              DropdownButtonFormField<String>(
                                initialValue: storageMode,
                                dropdownColor: context.surfaceColor,
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                decoration: InputDecoration(
                                  labelText: "Tenant Storage Mode",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.dns_outlined, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                items: const [
                                  DropdownMenuItem(value: 'CLOUD_SYNC', child: Text('Cloud Sync Mode (Firestore & Drive)')),
                                  DropdownMenuItem(value: 'PURE_OFFLINE', child: Text('Pure Offline Mode (Device Local Only)')),
                                  DropdownMenuItem(value: 'CLIENTS_OWN_SHEETS', child: Text("Client Dedicated Cloud Database")),
                                ],
                                onChanged: (newMode) {
                                  if (newMode == null || newMode == storageMode) return;
                                  if (newMode != initialStorageMode) {
                                    showDialog<bool>(
                                      context: context,
                                      barrierDismissible: false,
                                      builder: (wCtx) => AlertDialog(
                                        backgroundColor: context.surfaceColor,
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(16),
                                          side: BorderSide(color: context.borderColor),
                                        ),
                                        title: const Row(
                                          children: [
                                            Icon(Icons.swap_horiz_rounded, color: ClassicTheme.warningAmber, size: 28),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                "Request a storage mode change",
                                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                              ),
                                            ),
                                          ],
                                        ),
                                        content: Text(
                                          "Saving will ask the store owner to move this tenant from $initialStorageMode to $newMode. "
                                          "Nothing changes right now: the owner completes the change on their own device — "
                                          "Google consent, provisioning, migrating every local record, then a count check. "
                                          "The mode flips only after the check passes, and staff can keep billing on the current mode meanwhile. "
                                          "You can cancel the request from the Features tab at any time before it completes.",
                                          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(wCtx, false),
                                            child: Text("Cancel / Keep $initialStorageMode", style: TextStyle(color: context.textSecondary)),
                                          ),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: ClassicTheme.dangerRed,
                                              foregroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                            onPressed: () => Navigator.pop(wCtx, true),
                                            child: const Text("Request change"),
                                          ),
                                        ],
                                      ),
                                    ).then((confirmed) {
                                      if (confirmed == true) {
                                        setDialogState(() => storageMode = newMode);
                                      } else {
                                        setDialogState(() => storageMode = initialStorageMode);
                                      }
                                    });
                                  } else {
                                    setDialogState(() => storageMode = newMode);
                                  }
                                },
                              ),
                              if (storageMode == 'CLIENTS_OWN_SHEETS') ...[
                                const SizedBox(height: 8),
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: existingSheetId.isNotEmpty
                                        ? ClassicTheme.successEmerald.withValues(alpha: 0.08)
                                        : ClassicTheme.warningAmber.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: existingSheetId.isNotEmpty
                                          ? ClassicTheme.successEmerald.withValues(alpha: 0.3)
                                          : ClassicTheme.warningAmber.withValues(alpha: 0.3),
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(
                                            existingSheetId.isNotEmpty
                                                ? Icons.check_circle_outline_rounded
                                                : Icons.warning_amber_rounded,
                                            size: 18,
                                            color: existingSheetId.isNotEmpty
                                                ? ClassicTheme.successEmerald
                                                : ClassicTheme.warningAmber,
                                          ),
                                          const SizedBox(width: 8),
                                          Expanded(
                                            child: Text(
                                              existingSheetId.isNotEmpty
                                                  ? "Active Cloud Database Connected"
                                                  : "No Cloud Database Provisioned for Tenant",
                                              style: TextStyle(
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                                color: existingSheetId.isNotEmpty
                                                    ? ClassicTheme.successEmerald
                                                    : ClassicTheme.warningAmber,
                                              ),
                                            ),
                                          ),
                                          if (existingSheetId.isNotEmpty)
                                            IconButton(
                                              icon: const Icon(Icons.copy_rounded, size: 16),
                                              tooltip: "Copy Database URL",
                                              onPressed: () {
                                                final url = existingSheetUrl.isNotEmpty
                                                    ? existingSheetUrl
                                                    : "https://docs.google.com/spreadsheets/d/$existingSheetId/edit";
                                                Clipboard.setData(ClipboardData(text: url));
                                                AppToast.showSuccess(context, "Database URL copied to clipboard!");
                                              },
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        existingSheetId.isNotEmpty
                                            ? "Cloud Database Status: Connected & Active"
                                            : "This tenant has no linked cloud database. Click below to provision or connect.",
                                        style: TextStyle(fontSize: 12, color: context.textSecondary),
                                      ),
                                      const SizedBox(height: 8),
                                      ElevatedButton.icon(
                                        onPressed: isProvisioningSheet
                                            ? null
                                            : () async {
                                                setDialogState(() => isProvisioningSheet = true);
                                                try {
                                                  final authClient = await ClientLedgerCloudRouterService.getAuthenticatedClientIfAvailable();
                                                  http.Client clientToUse;
                                                  String ownerEmail = kAdminEmail;
                                                  if (authClient == null) {
                                                    final authRes = await ClientLedgerCloudRouterService.authorizeGoogleAccount();
                                                    if (authRes['success'] != true || authRes['client'] == null) {
                                                      throw Exception(authRes['error'] ?? "Authorization failed.");
                                                    }
                                                    clientToUse = authRes['client'] as http.Client;
                                                    ownerEmail = authRes['email'] ?? ownerEmail;
                                                  } else {
                                                    clientToUse = authClient;
                                                  }
                                                  final prov = await ClientLedgerCloudRouterService.provisionStoreLedgerSheet(
                                                    authenticatedClient: clientToUse,
                                                    storeName: nameController.text.trim().isNotEmpty ? nameController.text.trim() : orgName,
                                                    storeId: orgId,
                                                  );
                                                  if (prov['success'] == true) {
                                                    existingSheetId = prov['spreadsheetId'];
                                                    existingSheetUrl = prov['sheetUrl'];
                                                    await ClientLedgerCloudRouterService.linkGoogleLedgerToStore(
                                                      firestore: _firestore,
                                                      storeId: orgId,
                                                      sheetId: existingSheetId,
                                                      sheetUrl: existingSheetUrl,
                                                      ownerGoogleEmail: ownerEmail,
                                                    );
                                                    setDialogState(() {});
                                                    if (context.mounted) {
                                                      AppToast.showSuccess(context, "Cloud Database Provisioned & Linked!", subtitle: existingSheetUrl);
                                                    }
                                                  } else {
                                                    throw Exception(prov['error'] ?? "Provisioning failed.");
                                                  }
                                                } catch (e) {
                                                  if (context.mounted) {
                                                    AppToast.showError(context, e.toString(), title: "Provisioning Failed");
                                                  }
                                                } finally {
                                                  setDialogState(() => isProvisioningSheet = false);
                                                }
                                              },
                                        icon: isProvisioningSheet
                                            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                            : const Icon(Icons.add_to_drive_rounded, size: 16),
                                        label: Text(
                                          existingSheetId.isNotEmpty ? "Re-connect / Repair Database" : "Provision Cloud Database Now",
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: ClassicTheme.successEmerald,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 8),
                              SwitchListTile.adaptive(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text("Require Password Reset on Next Login", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                                subtitle: Text("Prompt user to change their temporary password upon login", style: TextStyle(color: context.textSecondary, fontSize: 12)),
                                value: mustChangePassword,
                                activeThumbColor: primaryAccent,
                                onChanged: (v) => setDialogState(() => mustChangePassword = v),
                              ),

                              const SizedBox(height: 18),

                              // ── SECTION 3: EMAIL & SMTP CONFIGURATION ─────────────
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                decoration: BoxDecoration(
                                  color: ClassicTheme.infoBlue.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.mark_email_read_rounded, color: ClassicTheme.infoBlue, size: 16),
                                    SizedBox(width: 6),
                                    Text("3. Email & SMTP Configuration", style: TextStyle(color: ClassicTheme.infoBlue, fontWeight: FontWeight.bold, fontSize: 13)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "Configure outgoing email server for sending digital POS tax invoices to customers upon bill settlement and administrative alerts.",
                                style: TextStyle(color: context.textSecondary, fontSize: 12, height: 1.3),
                              ),
                              const SizedBox(height: 6),
                              SwitchListTile.adaptive(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text("Inherit Platform Master Admin SMTP Server", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                                subtitle: Text(
                                  inheritPlatformSmtp
                                      ? "Uses the central system SMTP server configured by master admin"
                                      : "Using dedicated custom SMTP credentials for this tenant",
                                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                                ),
                                value: inheritPlatformSmtp,
                                activeThumbColor: ClassicTheme.infoBlue,
                                onChanged: (v) => setDialogState(() => inheritPlatformSmtp = v),
                              ),
                              if (!inheritPlatformSmtp) ...[
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Expanded(
                                      flex: 3,
                                      child: TextFormField(
                                        controller: smtpHostController,
                                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                                        decoration: InputDecoration(
                                          labelText: "SMTP Host *",
                                          hintText: "smtp.gmail.com",
                                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: ClassicTheme.infoBlue, width: 2)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      flex: 1,
                                      child: TextFormField(
                                        controller: smtpPortController,
                                        keyboardType: TextInputType.number,
                                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                                        decoration: InputDecoration(
                                          labelText: "Port *",
                                          hintText: "587",
                                          labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                          enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: ClassicTheme.infoBlue, width: 2)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: smtpUsernameController,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  decoration: InputDecoration(
                                    labelText: "Sender Email / Username *",
                                    hintText: "restaurant@gmail.com",
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                    prefixIcon: const Icon(Icons.account_circle_outlined, size: 18),
                                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: ClassicTheme.infoBlue, width: 2)),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: smtpPasswordController,
                                  obscureText: obscureSmtpPassword,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                                  decoration: InputDecoration(
                                    labelText: "SMTP App Password *",
                                    hintText: "16-character Google App Password",
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                    prefixIcon: const Icon(Icons.lock_outline, size: 18),
                                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: ClassicTheme.infoBlue, width: 2)),
                                    suffixIcon: IconButton(
                                      icon: Icon(obscureSmtpPassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: context.textSecondary),
                                      onPressed: () => setDialogState(() => obscureSmtpPassword = !obscureSmtpPassword),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: smtpFromNameController,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                                  decoration: InputDecoration(
                                    labelText: "Sender Display Name",
                                    hintText: "$orgName POS",
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                    prefixIcon: const Icon(Icons.badge_outlined, size: 18),
                                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: ClassicTheme.infoBlue, width: 2)),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SwitchListTile.adaptive(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text("Use SSL / TLS Direct Connection", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                                  subtitle: Text("Enable if Port 465 (Port 587 uses STARTTLS by default)", style: TextStyle(color: context.textSecondary, fontSize: 12)),
                                  value: smtpIsSsl,
                                  activeThumbColor: ClassicTheme.infoBlue,
                                  onChanged: (v) => setDialogState(() => smtpIsSsl = v),
                                ),
                                const Divider(height: 20),
                                Text("Test SMTP Mail Server", style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.bold)),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: TextField(
                                        controller: smtpTestEmailController,
                                        style: TextStyle(color: context.textPrimary, fontSize: 12),
                                        decoration: InputDecoration(
                                          hintText: "recipient@domain.com",
                                          isDense: true,
                                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    ElevatedButton.icon(
                                      onPressed: isTestingSmtp
                                          ? null
                                          : () async {
                                              if (smtpTestEmailController.text.trim().isEmpty) {
                                                AppToast.showError(context, "Enter a test recipient email.");
                                                return;
                                              }
                                              setDialogState(() => isTestingSmtp = true);
                                              try {
                                                final cfg = SmtpConfig(
                                                  host: smtpHostController.text.trim().isNotEmpty ? smtpHostController.text.trim() : 'smtp.gmail.com',
                                                  port: int.tryParse(smtpPortController.text.trim()) ?? 587,
                                                  isSsl: smtpIsSsl,
                                                  username: smtpUsernameController.text.trim(),
                                                  password: smtpPasswordController.text.trim(),
                                                  fromName: smtpFromNameController.text.trim().isNotEmpty ? smtpFromNameController.text.trim() : nameController.text.trim(),
                                                  inheritPlatform: false,
                                                );
                                                await SmtpEmailService.sendTestEmail(
                                                  toEmail: smtpTestEmailController.text.trim(),
                                                  config: cfg,
                                                );
                                                if (context.mounted) {
                                                  AppToast.showSuccess(context, "Test email sent successfully to ${smtpTestEmailController.text.trim()}!");
                                                }
                                              } catch (e) {
                                                if (context.mounted) {
                                                  AppToast.showError(context, "Test email failed: $e");
                                                }
                                              } finally {
                                                if (context.mounted) setDialogState(() => isTestingSmtp = false);
                                              }
                                            },
                                      icon: isTestingSmtp
                                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                          : const Icon(Icons.send_rounded, size: 14),
                                      label: const Text("Send Test", style: TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: ClassicTheme.infoBlue,
                                        foregroundColor: Colors.white,
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
              ),
              actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              actions: [
                TextButton(
                  onPressed: isSaving ? null : () => Navigator.pop(context),
                  child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
                ),
                ElevatedButton(
                  onPressed: (isSaving || isLoading)
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => isSaving = true);
                          try {
                            final orgName = nameController.text.trim();
                            final ownerName = ownerNameController.text.trim();
                            final email = ownerEmailController.text.trim().toLowerCase();
                            final mobile = mobileController.text.trim();
                            final aadhaar = aadhaarController.text.trim();
                            final pan = panController.text.trim();
                            final gst = gstController.text.trim();
                            final address = addressController.text.trim();
                            final rawPassword = ownerPasswordController.text.trim();

                            final smtpMap = {
                              'inheritPlatform': inheritPlatformSmtp,
                              'host': smtpHostController.text.trim().isNotEmpty ? smtpHostController.text.trim() : 'smtp.gmail.com',
                              'port': int.tryParse(smtpPortController.text.trim()) ?? 587,
                              'isSsl': smtpIsSsl,
                              'username': smtpUsernameController.text.trim(),
                              'password': smtpPasswordController.text.trim(),
                              'fromName': smtpFromNameController.text.trim().isNotEmpty ? smtpFromNameController.text.trim() : orgName,
                              'updatedAt': FieldValue.serverTimestamp(),
                            };

                            // 1. Update Organization Doc
                            await _firestore.collection('organizations').doc(orgId).set({
                              'name': orgName,
                              'appName': orgName,
                              'ownerName': ownerName,
                              'businessCategory': businessCategory,
                              'phone': mobile,
                              'mobile': mobile,
                              'aadhaar': aadhaar,
                              'pan': pan,
                              'gst': gst,
                              'address': address,
                              // The live mode is never flipped from the console. A different
                              // selection becomes a pending request the owner completes on
                              // their device (consent → provision → migrate → verify → flip).
                              if (storageMode == initialStorageMode) 'storageMode': storageMode,
                              if (storageMode != initialStorageMode)
                                'pendingStorageChange': {
                                  'from': initialStorageMode,
                                  'to': storageMode,
                                  'status': 'PENDING',
                                  'requestedBy': 'master_admin',
                                  'requestedAt': FieldValue.serverTimestamp(),
                                  'steps': <String, dynamic>{},
                                },
                              if (storageMode == initialStorageMode &&
                                  storageMode == 'CLIENTS_OWN_SHEETS' &&
                                  existingSheetId.isNotEmpty) ...{
                                'googleSheetId': existingSheetId,
                                'googleSheetUrl': existingSheetUrl,
                                'isGoogleConnected': true,
                              },
                              'smtpConfig': smtpMap,
                              'updatedAt': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true));

                            // Payment gateway credentials are no longer stored.
                            // A bill is settled in cash, on the restaurant's own
                            // card machine, or against the restaurant's UPI ID —
                            // the platform never holds the money, so there is
                            // nothing here to configure.
                            FirebaseFirestore.instance
                                .collection('public_stores')
                                .doc(orgId)
                                .set({
                              'isRazorpayEnabled': false,
                              'razorpayKeyId': '',
                              'updatedAt': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true)).catchError((e) =>
                                    debugPrint("public_stores gateway clear note: $e"));

                            // 2. Cache SMTP Config to Hive for instant offline billing invoice dispatch
                            try {
                              final box = Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null;
                              await box?.put('smtp_config_$orgId', {
                                'inheritPlatform': inheritPlatformSmtp,
                                'host': smtpHostController.text.trim().isNotEmpty ? smtpHostController.text.trim() : 'smtp.gmail.com',
                                'port': int.tryParse(smtpPortController.text.trim()) ?? 587,
                                'isSsl': smtpIsSsl,
                                'username': smtpUsernameController.text.trim(),
                                'password': smtpPasswordController.text.trim(),
                                'fromName': smtpFromNameController.text.trim().isNotEmpty ? smtpFromNameController.text.trim() : orgName,
                              });
                            } catch (_) {}

                            // 3. Update Owner User Doc
                            if (ownerUserId != null && ownerUserId!.isNotEmpty) {
                              final userUpdates = <String, dynamic>{
                                'fullName': ownerName,
                                'email': email,
                                'phone': mobile,
                                'mustChangePassword': mustChangePassword,
                                'updatedAt': FieldValue.serverTimestamp(),
                              };
                              if (rawPassword.isNotEmpty) {
                                userUpdates['passwordHash'] = BCrypt.hashpw(rawPassword, BCrypt.gensalt());
                              }
                              await _firestore.collection('users').doc(ownerUserId).update(userUpdates);
                            }

                            // 4. Write Master Admin Audit Log
                            final masterSession = ref.read(saasSessionProvider);
                            await ref.read(saasSessionProvider.notifier).logAudit(
                                  orgId: orgId,
                                  userId: masterSession.currentUser?.id ?? 'master_admin',
                                  actionType: 'CLIENT_UPDATED',
                                  details: 'Tenant $orgName ($orgId) settings and SMTP updated.',
                                );

                            // 5. Reload active context if master admin is currently impersonating this client
                            if (masterSession.currentOrganization?.id == orgId) {
                              await ref.read(saasSessionProvider.notifier).enterOrganizationConsole(orgId);
                            }

                            if (context.mounted) {
                              Navigator.pop(context);
                              AppToast.showSuccess(
                                context,
                                "Tenant Updated Successfully",
                                subtitle: "$orgName ($orgId) configuration updated.",
                              );
                            }
                          } catch (e) {
                            setDialogState(() => isSaving = false);
                            if (context.mounted) {
                              AppToast.showError(context, e, title: "Update Failed");
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: isSaving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Save Tenant Info", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryAccent = context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Registered Organizations",
                style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
              ),
              ElevatedButton.icon(
                onPressed: _showAddOrganizationDialog,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text("New Tenant"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAccent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // RENEWAL REQUESTS NOTIFICATION BANNER
          StreamBuilder<QuerySnapshot>(
            stream: _firestore.collection('renewal_requests').where('status', isEqualTo: 'PENDING').snapshots(),
            builder: (context, renewalSnap) {
              if (!renewalSnap.hasData || renewalSnap.data!.docs.isEmpty) {
                return const SizedBox.shrink();
              }
              final requests = renewalSnap.data!.docs;
              return Container(
                margin: const EdgeInsets.only(bottom: 16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: ClassicTheme.warningAmber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ClassicTheme.warningAmber.withValues(alpha: 0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: ClassicTheme.warningAmber.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.notifications_active_rounded, color: ClassicTheme.warningAmber, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Action Required: ${requests.length} License Renewal Request${requests.length > 1 ? 's' : ''}",
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ClassicTheme.warningAmber),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "Client stores have completed their trial or plan and requested immediate license extension.",
                                style: TextStyle(color: context.textSecondary, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    ...requests.map((doc) {
                      final rData = doc.data() as Map<String, dynamic>;
                      final rOrgId = rData['organizationId'] ?? doc.id;
                      final rOrgName = rData['organizationName'] ?? rOrgId;
                      final rTier = rData['previousPlanTier'] ?? 'TRIAL';
                      final rPkg = (rData['requestedPackageName'] ?? rData['requestedPackageId'] ?? '').toString();
                      final rPlan = (rData['requestedPlanName'] ?? rData['requestedPlanId'] ?? '').toString();
                      final rAsked = [rPkg, rPlan].where((x) => x.isNotEmpty).join(' \u00b7 ');
                      return Container(
                        margin: const EdgeInsets.only(top: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    rOrgName,
                                    style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    rAsked.isEmpty
                                        ? "Tenant: $rOrgId  \u2022  Previous: $rTier"
                                        : "Tenant: $rOrgId  \u2022  Asked for: $rAsked",
                                    style: TextStyle(color: context.textSecondary, fontSize: 12),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: () => _showRenewLicenseDialog(rOrgId, rOrgName),
                              icon: const Icon(Icons.card_membership_rounded, size: 14),
                              label: const Text("Renew License", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.successEmerald,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              );
            },
          ),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore.collection('organizations').snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator(color: primaryAccent));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(child: Text("No client organizations registered yet.", style: TextStyle(color: context.textSecondary)));
                }

                final docs = snapshot.data!.docs.where((d) => d.id != 'SYSTEM_ADMIN').toList();
                if (docs.isEmpty) {
                  return Center(child: Text("No client organizations registered yet.", style: TextStyle(color: context.textSecondary)));
                }

                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final docId = docs[index].id;
                    final name = data['name'] ?? 'Unnamed';
                    final ownerName = data['ownerName'] ?? '';
                    final phone = data['mobile'] ?? data['phone'] ?? '';
                    final category = data['businessCategory'] ?? 'General';
                    final storageMode = data['storageMode'] ?? 'CLOUD_SYNC';
                    final aadhaar = data['aadhaar'] ?? '';
                    final pan = data['pan'] ?? '';
                    final gst = data['gst'] ?? '';
                    final status = data['status'] ?? 'ACTIVE';

                    return Card(
                      color: context.surfaceColor,
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: context.borderColor),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(14.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Flexible(
                                            child: Text(
                                              name,
                                              style: TextStyle(
                                                color: context.textPrimary,
                                                fontWeight: FontWeight.bold,
                                                fontSize: 16,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          _infoBadge(Icons.fingerprint, docId, isAccent: true),
                                        ],
                                      ),
                                      if (ownerName.isNotEmpty) ...[
                                        const SizedBox(height: 3),
                                        Text(
                                          "Owner: $ownerName ${phone.isNotEmpty ? '($phone)' : ''}",
                                          style: TextStyle(color: context.textSecondary, fontSize: 12.5),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.card_membership_rounded, color: ClassicTheme.successEmerald, size: 20),
                                      tooltip: "Edit License & Plan Entitlements",
                                      onPressed: () => _showRenewLicenseDialog(docId, name),
                                    ),
                                    IconButton(
                                      icon: Icon(Icons.edit_outlined, color: primaryAccent, size: 20),
                                      tooltip: "Edit tenant profile & email",
                                      onPressed: () => _showEditOrganizationDialog(docId, name),
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.admin_panel_settings_outlined,
                                          color: ClassicTheme.warningAmber, size: 20),
                                      tooltip: "Access, licence & closure",
                                      onPressed: () => TenantAccessDialog.show(
                                        context,
                                        orgId: docId,
                                        orgName: name,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                StreamBuilder<DocumentSnapshot>(
                                  stream: _firestore.collection('licenses').doc(docId).snapshots(),
                                  builder: (context, licSnap) {
                                    if (!licSnap.hasData || !licSnap.data!.exists) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: status == 'ACTIVE' ? ClassicTheme.successEmerald.withValues(alpha: 0.15) : ClassicTheme.dangerRed.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          status,
                                          style: TextStyle(
                                            color: status == 'ACTIVE' ? ClassicTheme.successEmerald : ClassicTheme.dangerRed,
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                      );
                                    }

                                    final lData = licSnap.data!.data() as Map<String, dynamic>? ?? {};
                                    final tier = lData['planTier'] ?? 'TRIAL';
                                    final licStatus = lData['status'] ?? 'ACTIVE';
                                    final warnDays = lData['expiryWarningDays'] is num ? (lData['expiryWarningDays'] as num).toInt() : 3;

                                    DateTime expDate = DateTime.now();
                                    if (lData['endDate'] is Timestamp) {
                                      expDate = (lData['endDate'] as Timestamp).toDate();
                                    } else if (lData['endDate'] is String) {
                                      expDate = DateTime.tryParse(lData['endDate']) ?? expDate;
                                    }

                                    final daysLeft = expDate.difference(DateTime.now()).inDays.clamp(0, 99999);
                                    final isExpired = DateTime.now().isAfter(expDate) || licStatus == 'EXPIRED';
                                    final isNear = !isExpired && daysLeft <= warnDays;

                                    Color badgeColor;
                                    String badgeLabel;

                                    if (isExpired) {
                                      badgeColor = ClassicTheme.dangerRed;
                                      badgeLabel = "EXPIRED";
                                    } else if (isNear) {
                                      badgeColor = ClassicTheme.warningAmber;
                                      badgeLabel = "EXPIRES IN $daysLeft DAYS";
                                    } else if (tier == 'TRIAL') {
                                      badgeColor = ClassicTheme.warningAmber;
                                      badgeLabel = "TRIAL ($daysLeft days)";
                                    } else {
                                      badgeColor = ClassicTheme.successEmerald;
                                      badgeLabel = "$tier ($daysLeft days)";
                                    }

                                    return Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: badgeColor.withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(color: badgeColor.withValues(alpha: 0.3)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            isExpired ? Icons.lock_outline_rounded :
                                            isNear ? Icons.warning_amber_rounded :
                                            tier == 'TRIAL' ? Icons.hourglass_top_rounded : Icons.check_circle_outline,
                                            size: 11,
                                            color: badgeColor,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            badgeLabel,
                                            style: TextStyle(color: badgeColor, fontSize: 12, fontWeight: FontWeight.bold),
                                          ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                                StreamBuilder<DocumentSnapshot>(
                                  stream: _firestore.collection('renewal_requests').doc(docId).snapshots(),
                                  builder: (context, renSnap) {
                                    if (renSnap.hasData && renSnap.data!.exists) {
                                      final rData = renSnap.data!.data() as Map<String, dynamic>? ?? {};
                                      if (rData['status'] == 'PENDING') {
                                        return Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: ClassicTheme.dangerRed.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: ClassicTheme.dangerRed),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.bolt_rounded, size: 12, color: ClassicTheme.dangerRed),
                                              SizedBox(width: 4),
                                              Text(
                                                "RENEWAL REQUESTED",
                                                style: TextStyle(color: ClassicTheme.dangerRed, fontSize: 12, fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),
                                        );
                                      }
                                    }
                                    return const SizedBox.shrink();
                                  },
                                ),
                                _infoBadge(Icons.category_outlined, category),
                                _infoBadge(Icons.cloud_sync_outlined, storageMode == 'CLIENTS_OWN_SHEETS' ? "Cloud Database" : storageMode),
                                if (aadhaar.isNotEmpty)
                                  _infoBadge(Icons.badge_outlined, "Aadhaar: $aadhaar"),
                                if (pan.isNotEmpty)
                                  _infoBadge(Icons.credit_card_outlined, "PAN: $pan"),
                                if (gst.isNotEmpty)
                                  _infoBadge(Icons.receipt_long_outlined, "GST: $gst"),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _infoBadge(IconData icon, String text, {bool isVerified = false, bool isAccent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isAccent ? ClassicTheme.infoBlue.withValues(alpha: 0.12) : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: isAccent ? ClassicTheme.infoBlue : Colors.grey),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: isAccent ? FontWeight.bold : FontWeight.normal, color: context.textPrimary)),
          if (isVerified) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified_rounded, size: 12, color: ClassicTheme.successEmerald),
          ],
        ],
      ),
    );
  }
}


// --- TAB 2: AUDIT LOGS TAB ---
class AuditLogsTab extends StatelessWidget {
  const AuditLogsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final firestore = FirebaseFirestore.instance;
    final primaryAccent = context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text("SaaS Platform Audit Trails", style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: firestore.collection('audit_logs').orderBy('timestamp', descending: true).limit(50).snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator(color: primaryAccent));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(child: Text("No audit logs written yet.", style: TextStyle(color: context.textSecondary)));
                }

                final docs = snapshot.data!.docs;

                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final data = docs[index].data() as Map<String, dynamic>;
                    final action = data['actionType'] ?? 'ACTION';
                    final details = data['details'] ?? '';
                    final org = data['organizationId'] ?? 'SYSTEM';
                    final orgName = data['organizationName'] ?? org;
                    final userName = data['userName'] ?? data['userId'] ?? 'System';
                    final franchiseName = data['franchiseName'] as String?;
                    final timestamp = data['timestamp'] is Timestamp
                        ? (data['timestamp'] as Timestamp).toDate().toLocal().toString().split('.')[0]
                        : '';

                    return Card(
                      color: context.surfaceColor,
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 8),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: context.borderColor),
                      ),
                      child: ListTile(
                        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        title: Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(action, style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            Text(timestamp, style: TextStyle(color: context.textSecondary, fontSize: 12)),
                          ],
                        ),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 6),
                            Text(details, style: TextStyle(color: context.textPrimary, fontSize: 12)),
                            const SizedBox(height: 10),
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: context.isDark ? context.textPrimary : context.inputFill,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: Text("By: $userName", style: TextStyle(color: primaryAccent, fontSize: 12, fontWeight: FontWeight.w600)),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: context.isDark ? context.textPrimary : context.inputFill,
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: Text(
                                    "Org: $orgName",
                                    style: TextStyle(
                                      color: context.isDark ? const Color(0xFF34D399) : ClassicTheme.successEmerald,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (franchiseName != null && franchiseName.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: context.isDark ? context.textPrimary : context.inputFill,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: context.borderColor),
                                    ),
                                    child: Text(
                                      "Outlet: $franchiseName",
                                      style: TextStyle(
                                        color: context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// --- TAB 3: APP UPDATES TAB ---
class AppUpdatesTab extends StatefulWidget {
  const AppUpdatesTab({super.key});

  @override
  State<AppUpdatesTab> createState() => _AppUpdatesTabState();
}

class _AppUpdatesTabState extends State<AppUpdatesTab> {
  final _firestore = FirebaseFirestore.instance;
  final _formKey = GlobalKey<FormState>();
  final _versionController = TextEditingController();
  final _apkUrlController = TextEditingController();
  bool _mandatory = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _loadLatestAppVersion();
  }

  Future<void> _loadLatestAppVersion() async {
    final doc = await _firestore.collection('app_versions').doc('latest').get();
    if (doc.exists) {
      final data = doc.data()!;
      setState(() {
        _versionController.text = data['latestVersion'] ?? '1.0.0';
        _apkUrlController.text = data['apkUrl'] ?? '';
        _mandatory = data['mandatory'] == true;
      });
    }
  }

  @override
  void dispose() {
    _versionController.dispose();
    _apkUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primaryAccent = context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue;

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text("Deploy App Update Metadata", style: TextStyle(color: context.textPrimary, fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 20),
            TextFormField(
              controller: _versionController,
              style: TextStyle(color: context.textPrimary),
              decoration: InputDecoration(
                labelText: "Latest Version Code (e.g. 1.0.5)",
                labelStyle: TextStyle(color: context.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
              ),
              validator: (v) => v == null || v.trim().isEmpty ? "Required" : null,
            ),
            const SizedBox(height: 20),
            TextFormField(
              controller: _apkUrlController,
              style: TextStyle(color: context.textPrimary),
              decoration: InputDecoration(
                labelText: "Direct APK URL",
                labelStyle: TextStyle(color: context.textSecondary),
                enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
              ),
              validator: (v) => v == null || v.trim().isEmpty ? "Required" : null,
            ),
            const SizedBox(height: 20),
            SwitchListTile(
              title: Text("Mandatory Update (Locks app until updated)", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.w500)),
              value: _mandatory,
              activeThumbColor: primaryAccent,
              onChanged: (val) => setState(() => _mandatory = val),
            ),
            const Spacer(),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _isSaving
                    ? null
                    : () async {
                        if (!_formKey.currentState!.validate()) return;
                        setState(() => _isSaving = true);

                        try {
                          await _firestore.collection('app_versions').doc('latest').set({
                            'latestVersion': _versionController.text.trim(),
                            'apkUrl': _apkUrlController.text.trim(),
                            'mandatory': _mandatory,
                            'updatedAt': FieldValue.serverTimestamp(),
                          });

                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("App version metadata updated successfully!")),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text("Error saving: $e"), backgroundColor: ClassicTheme.dangerRed),
                            );
                          }
                        } finally {
                          if (mounted) {
                            setState(() => _isSaving = false);
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAccent,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: _isSaving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text("Publish Update Metadata", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class UnifiedClientRequest {
  final String id;
  final String requestType; // 'FREE_TRIAL' or 'PLAN_INQUIRY'
  final String clientName;
  final String shopName;
  final String businessCategory;
  final String email;
  final String mobile;
  final String cityOrAddress;
  final String referralSource;
  final String selectedPlan;
  final String outlets;
  final String stations;
  final String notes;
  final String status;
  final DateTime? createdAt;
  final Map<String, dynamic> rawData;

  UnifiedClientRequest({
    required this.id,
    required this.requestType,
    required this.clientName,
    required this.shopName,
    required this.businessCategory,
    required this.email,
    required this.mobile,
    required this.cityOrAddress,
    required this.referralSource,
    required this.selectedPlan,
    required this.outlets,
    required this.stations,
    required this.notes,
    required this.status,
    this.createdAt,
    required this.rawData,
  });

  bool get isTrial => requestType == 'FREE_TRIAL';
  bool get isPending => status == 'PENDING' || status == 'NEW_INQUIRY';
}

// --- TAB: REGISTRATION REQUESTS TAB ---
class RegistrationRequestsTab extends ConsumerStatefulWidget {
  const RegistrationRequestsTab({super.key});

  @override
  ConsumerState<RegistrationRequestsTab> createState() => _RegistrationRequestsTabState();
}

class _RegistrationRequestsTabState extends ConsumerState<RegistrationRequestsTab> {
  final _firestore = FirebaseFirestore.instance;
  final TextEditingController _searchController = TextEditingController();
  String _selectedFilter = 'PENDING'; // 'ALL', 'PENDING', 'TRIALS', 'INQUIRIES', 'APPROVED', 'REJECTED'
  String _searchQuery = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  String _generateUniqueOrgId() {
    final now = DateTime.now();
    final year = now.year.toString().substring(2);
    final randomDigits = 1000 + Random().nextInt(9000);
    return "ORG$year$randomDigits";
  }

  void _showOnboardDialogFromRequest({
    required String requestId,
    required String clientName,
    required String shopName,
    required String category,
    required String email,
    required String mobile,
    String initialAadhaar = '',
    String initialPan = '',
    String initialGst = '',
    String initialAddress = '',
    int initialTrialDays = 14,
    int initialMaxUsers = 5,
    int initialMaxOutlets = 1,
    int initialTableCount = 10,
    String initialOperatingMode = 'dineFirstPostpaid',
    List<String>? initialRoles,
    Map<String, bool>? initialFeatures,
    /// What the applicant asked for, when they asked in package/plan terms
    /// (the app's upgrade sheet does). The editor snaps to these documents.
    String initialPackageId = '',
    String initialPlanId = '',
  }) async {
    final availablePlans = await SubscriptionPlanService.getAllPlans();
    if (!context.mounted) return;

    final formKey = GlobalKey<FormState>();

    final orgIdController = TextEditingController(text: _generateUniqueOrgId());
    final ownerNameController = TextEditingController(text: clientName);
    final nameController = TextEditingController(text: shopName.isNotEmpty ? shopName : "$clientName Restaurant");
    String businessCategory = category.isNotEmpty ? category : 'Restaurant & Cafe';
    final mobileController = TextEditingController(text: mobile);
    final aadhaarController = TextEditingController(text: initialAadhaar);
    final panController = TextEditingController(text: initialPan);
    final gstController = TextEditingController(text: initialGst);
    final addressController = TextEditingController(text: initialAddress);
    final ownerEmailController = TextEditingController(text: email);
    final ownerPasswordController = TextEditingController(text: '123456');

    // Default plan matches trial or first available
    SubscriptionPlan selectedPlan = availablePlans.firstWhere(
      (p) => initialTrialDays > 0 ? p.isDefaultTrial : !p.isDefaultTrial,
      orElse: () => availablePlans.isNotEmpty ? availablePlans.first : SubscriptionPlanService.fallbackTrialPlan,
    );

    // `initialMaxUsers` is still accepted from older callers, but the staff
    // cap is the plan's since 18 Sep 2026 and is not editable here.
    int tableCount = initialTableCount;
    String operatingMode = initialOperatingMode;

    // A package and a plan. The applicant's own request names both when it
    // came from the app's upgrade sheet; a web lead names neither, and starts
    // on the trial package for its category with the default trial plan.
    // More than one outlet asked for is a chain, so it starts on the only
    // starter that can run one. The admin can change any of it.
    final startPackage = (await PackageService.getById(initialPackageId)) ??
        (await PackageService.getById(initialMaxOutlets > 1
            ? PlanProfile.omnichannel.id
            : Verticals.defaultPackageFor(category))) ??
        TenantPackage.fromProfile(PlanProfile.offlineDineIn);
    final startPlan = availablePlans.where((p) => p.id == initialPlanId).firstOrNull ?? selectedPlan;
    if (!context.mounted) return;
    TenantPackageSelection selection =
        TenantPackageSelection(package: startPackage, plan: startPlan);

    bool isCreating = false;
    bool obscurePassword = true;

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            const primaryAccent = ClassicTheme.successEmerald;
            return AlertDialog(
              backgroundColor: context.surfaceColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: context.borderColor),
              ),
              title: Row(
                children: [
                  const Icon(Icons.verified_user_rounded, color: primaryAccent, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      "Approve & Onboard Restaurant Request",
                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 17),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: primaryAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      "Request Approval",
                      style: TextStyle(color: primaryAccent, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: ClassicTheme.dialogWidth(context, 650),
                child: SingleChildScrollView(
                  child: Form(
                    key: formKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // SECTION 1: IDENTITY
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.restaurant_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("1. Applicant Identity", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: orgIdController,
                                style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold),
                                decoration: InputDecoration(
                                  labelText: "Organization ID *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.tag_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: nameController,
                                style: TextStyle(color: context.textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Restaurant Name *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.storefront_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: ownerNameController,
                                style: TextStyle(color: context.textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Owner Name *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.person_outline_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: mobileController,
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.phone,
                                decoration: InputDecoration(
                                  labelText: "Mobile *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.phone_android_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: ownerEmailController,
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.emailAddress,
                                decoration: InputDecoration(
                                  labelText: "Login Email *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.alternate_email_rounded, size: 18),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || !v.contains('@')) ? "Valid email required" : null,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                controller: ownerPasswordController,
                                obscureText: obscurePassword,
                                style: TextStyle(color: context.textPrimary),
                                decoration: InputDecoration(
                                  labelText: "Assign Password *",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.lock_outline_rounded, size: 18),
                                  suffixIcon: IconButton(
                                    icon: Icon(obscurePassword ? Icons.visibility_off_rounded : Icons.visibility_rounded, size: 18),
                                    onPressed: () => setDialogState(() => obscurePassword = !obscurePassword),
                                  ),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                validator: (v) => (v == null || v.length < 6) ? "Min 6 characters" : null,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        TextFormField(
                          controller: addressController,
                          style: TextStyle(color: context.textPrimary),
                          decoration: InputDecoration(
                            labelText: "Physical Address",
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                            prefixIcon: const Icon(Icons.location_on_outlined, size: 18),
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                          ),
                        ),
                        const SizedBox(height: 20),

                        // SECTIONS 2 & 3: PACKAGE, VALIDITY AND ADD-ONS
                        //
                        // One editor for all three. It offers only the storage
                        // modes the package can run, shows included features as
                        // included rather than as switches that would not
                        // survive the resolver, and the licence is written from
                        // what the resolver says — so the tenant gets exactly
                        // what is on this screen.
                        TenantPackageEditor(
                          value: selection,
                          onChanged: (v) => setDialogState(() => selection = v),
                        ),
                        const SizedBox(height: 20),

                        // Quotas the package does not decide.
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.tune_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("Other quotas", style: const TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              // Staff count is the plan's to decide, so it is
                              // shown here and edited on the Plans screen.
                              child: InputDecorator(
                                decoration: InputDecoration(
                                  labelText: "Max Staff / Users (from plan)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.groups_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                ),
                                child: Text('${selection.plan.maxUsers}',
                                    style: TextStyle(color: context.textPrimary)),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: tableCount.toString(),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Table Quota",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.table_restaurant_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => tableCount = int.tryParse(v) ?? tableCount,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<String>(
                          initialValue: operatingMode,
                          dropdownColor: context.surfaceColor,
                          style: TextStyle(color: context.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Operating Mode",
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                            prefixIcon: const Icon(Icons.room_service_rounded, size: 16),
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                          ),
                          items: const [
                            DropdownMenuItem(value: 'dineFirstPostpaid', child: Text("Dine-In Postpaid")),
                            DropdownMenuItem(value: 'counterPrepaid', child: Text("Fast QSR Prepaid")),
                            DropdownMenuItem(value: 'hybrid', child: Text("Hybrid Dynamic")),
                          ],
                          onChanged: (v) {
                            if (v != null) setDialogState(() => operatingMode = v);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isCreating ? null : () => Navigator.pop(context),
                  child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
                ),
                ElevatedButton(
                  onPressed: isCreating
                      ? null
                      : () async {
                          if (!formKey.currentState!.validate()) return;
                          setDialogState(() => isCreating = true);

                          try {
                            final orgId = orgIdController.text.trim();
                            final orgName = nameController.text.trim();
                            final ownerName = ownerNameController.text.trim();
                            final email = ownerEmailController.text.trim().toLowerCase();
                            final rawPassword = ownerPasswordController.text;
                            final mobile = mobileController.text.trim();
                            final address = addressController.text.trim();
                            final gst = gstController.text.trim();
                            final pan = panController.text.trim();
                            final aadhaar = aadhaarController.text.trim();

                            // The subscription record matching the chosen
                            // package, so the plan name and billing cycle stay
                            // meaningful. Every limit and feature below comes
                            // from the resolver, not from that record.
                            // The selection *is* a package and a plan now.
                            // What is written is their composition, so the
                            // preview the admin just looked at and the licence
                            // the till reads are the same numbers.
                            final finalPlan = selection.plan.copyWith(
                              maxOutlets: selection.effectiveOutlets,
                              maxDevices: selection.effectiveDevices,
                              maxUsers: selection.plan.maxUsers,
                              tableCount: tableCount,
                              operatingMode: operatingMode,
                              allowedRoles: selection.effectiveRoles,
                              features: selection.resolvedFeatures,
                            );

                            final result = await TenantProvisioningService.provisionTenant(
                              customOrgId: orgId,
                              shopName: orgName,
                              clientName: ownerName,
                              email: email,
                              rawPassword: rawPassword,
                              mobile: mobile,
                              category: businessCategory,
                              address: address.isNotEmpty ? address : null,
                              aadhaar: aadhaar.isNotEmpty ? aadhaar : null,
                              pan: pan.isNotEmpty ? pan : null,
                              gstNo: gst.isNotEmpty ? gst : null,
                              plan: finalPlan,
                              requestId: requestId,
                              storageMode: selection.storageMode,
                              planProfile: selection.profile.id,
                              packageId: selection.packageId,
                              planId: selection.planId,
                            );

                            if (result['success'] != true) {
                              throw Exception(result['message'] ?? "Approval onboarding failed");
                            }

                            if (context.mounted) {
                              Navigator.pop(context);
                              AppToast.showSuccess(
                                context,
                                "Request Approved & Client Onboarded",
                                subtitle: "$orgName ($orgId) onboarded with ${finalPlan.name}.",
                              );
                            }
                          } catch (e) {
                            setDialogState(() => isCreating = false);
                            if (context.mounted) {
                              AppToast.showError(context, e, title: "Approval Failed");
                            }
                          }
                        },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: primaryAccent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: isCreating
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Approve & Onboard", style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _makePhoneCall(String phone) async {
    final clean = phone.replaceAll(RegExp(r'[^0-9+]'), '');
    if (clean.isEmpty) return;
    final uri = Uri.parse('tel:$clean');
    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (_) {}
  }

  Future<void> _openWhatsApp(String phone, String clientName) async {
    var clean = phone.replaceAll(RegExp(r'[^0-9]'), '');
    if (clean.length == 10) clean = '91$clean';
    if (clean.isEmpty) return;
    final msg = Uri.encodeComponent("Hello $clientName, this is from SmartDine POS! We received your request.");
    final uri = Uri.parse('https://wa.me/$clean?text=$msg');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _sendEmail(String email, String clientName) async {
    if (email.isEmpty) return;
    final uri = Uri.parse('mailto:$email?subject=${Uri.encodeComponent("SmartDine POS Setup & Onboarding")}');
    try {
      await launchUrl(uri);
    } catch (_) {}
  }

  void _showRequestDetailsDialog(UnifiedClientRequest request) {
    final primaryAccent = context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue;
    final isTrial = request.isTrial;
    final cleanPhone = request.mobile.replaceAll(RegExp(r'[^0-9+]'), '');

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: context.surfaceColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: context.borderColor),
          ),
          titlePadding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          actionsPadding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: (isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  isTrial ? Icons.storefront_rounded : Icons.business_center_rounded,
                  color: isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent,
                  size: 22,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.clientName,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 17,
                      ),
                    ),
                    if (request.shopName.isNotEmpty)
                      Text(
                        request.shopName,
                        style: TextStyle(
                          color: primaryAccent,
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                        ),
                      ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _getStatusColor(request.status).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  request.status,
                  style: TextStyle(
                    color: _getStatusColor(request.status),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.close_rounded, size: 20),
                color: context.textSecondary,
                onPressed: () => Navigator.pop(ctx),
                tooltip: "Close",
              ),
            ],
          ),
          content: SizedBox(
            width: ClassicTheme.dialogWidth(context, 580),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Type & Plan Banner
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: (isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: (isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent).withValues(alpha: 0.25),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isTrial ? Icons.verified_rounded : Icons.star_rounded,
                          size: 18,
                          color: isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isTrial ? "14-Day Full Access Free Trial Request" : "Commercial Plan: ${request.selectedPlan}",
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              color: isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Section 1: Contact Information & Quick Actions
                  Text(
                    "Contact Information",
                    style: TextStyle(
                      color: context.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: context.borderColor),
                    ),
                    child: Column(
                      children: [
                        // Phone Row with Quick Call & WhatsApp
                        Row(
                          children: [
                            Icon(Icons.phone_android_rounded, size: 16, color: primaryAccent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                request.mobile.isNotEmpty ? request.mobile : "No mobile provided",
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (cleanPhone.isNotEmpty) ...[
                              InkWell(
                                onTap: () => _makePhoneCall(request.mobile),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: ClassicTheme.infoBlue.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.call_rounded, size: 13, color: ClassicTheme.infoBlue),
                                      SizedBox(width: 4),
                                      Text("Call", style: TextStyle(color: ClassicTheme.infoBlue, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              InkWell(
                                onTap: () => _openWhatsApp(request.mobile, request.clientName),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFF25D366).withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: const Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.chat_bubble_outline_rounded, size: 13, color: Color(0xFF25D366)),
                                      SizedBox(width: 4),
                                      Text("WhatsApp", style: TextStyle(color: Color(0xFF25D366), fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 10),
                        Divider(height: 1, color: context.borderColor),
                        const SizedBox(height: 10),

                        // Email Row with Send Email
                        Row(
                          children: [
                            Icon(Icons.mail_outline_rounded, size: 16, color: primaryAccent),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                request.email.isNotEmpty ? request.email : "No email provided",
                                style: TextStyle(
                                  color: context.textPrimary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            if (request.email.isNotEmpty)
                              InkWell(
                                onTap: () => _sendEmail(request.email, request.clientName),
                                borderRadius: BorderRadius.circular(6),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: ClassicTheme.secondaryAccent.withValues(alpha: 0.12),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(Icons.send_rounded, size: 13, color: ClassicTheme.secondaryAccent),
                                      const SizedBox(width: 4),
                                      Text("Email", style: TextStyle(color: ClassicTheme.secondaryAccent, fontSize: 12, fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                        if (request.cityOrAddress.isNotEmpty) ...[
                          const SizedBox(height: 10),
                          Divider(height: 1, color: context.borderColor),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Icon(Icons.location_on_outlined, size: 16, color: primaryAccent),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  request.cityOrAddress,
                                  style: TextStyle(
                                    color: context.textSecondary,
                                    fontSize: 12.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Section 2: Business & Operational Scope
                  Text(
                    "Business & Store Specifications",
                    style: TextStyle(
                      color: context.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: [
                      _infoBadge(Icons.category_rounded, request.businessCategory),
                      _infoBadge(Icons.store_mall_directory_rounded, request.outlets),
                      _infoBadge(Icons.devices_rounded, request.stations),
                      if (isTrial && request.rawData['tableCount'] != null)
                        _infoBadge(Icons.table_restaurant_rounded, "${request.rawData['tableCount']} Tables"),
                      if (request.rawData['preferredOperatingMode'] != null)
                        _infoBadge(
                          Icons.sync_alt_rounded,
                          request.rawData['preferredOperatingMode'] == 'payFirstQSR' ? 'Pay First (QSR)' : 'Dine First (Table)',
                        ),
                      if (request.referralSource.isNotEmpty)
                        _infoBadge(Icons.share_outlined, "Source: ${request.referralSource}"),
                      if (request.rawData['gstNo'] != null || request.rawData['gst'] != null)
                        _infoBadge(Icons.receipt_long_rounded, "GST: ${request.rawData['gstNo'] ?? request.rawData['gst']}"),
                      if (request.createdAt != null)
                        _infoBadge(Icons.calendar_today_rounded, "${request.createdAt!.day}/${request.createdAt!.month}/${request.createdAt!.year} ${request.createdAt!.hour.toString().padLeft(2, '0')}:${request.createdAt!.minute.toString().padLeft(2, '0')}"),
                      if (request.rawData['organizationId'] != null)
                        _infoBadge(Icons.check_circle_outline_rounded, "Org: ${request.rawData['organizationId']}", isAccent: true),
                    ],
                  ),

                  // Section 3: Notes / Special Requirements
                  if (request.notes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      "Client Special Requirements / Notes",
                      style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: context.canvasColor,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Text(
                        request.notes,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 12.5,
                          height: 1.4,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text("Close", style: TextStyle(color: context.textSecondary)),
            ),

            // Actions for Free Trial Request
            if (isTrial && request.status == 'PENDING') ...[
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _firestore.collection('registration_requests').doc(request.id).update({
                    'status': 'REJECTED',
                    'rejectedAt': FieldValue.serverTimestamp(),
                    'updatedAt': FieldValue.serverTimestamp(),
                  });
                  SmtpEmailService.sendRegistrationRejectedEmail(
                    recipientEmail: request.email,
                    clientName: request.clientName,
                    shopName: request.shopName,
                    reason: "Information verification could not be completed.",
                  ).catchError((_) => <String, dynamic>{});
                  if (mounted) {
                    AppToast.showSuccess(context, "Trial Request Rejected.");
                  }
                },
                icon: const Icon(Icons.close_rounded, size: 16, color: ClassicTheme.dangerRed),
                label: const Text("Reject", style: TextStyle(color: ClassicTheme.dangerRed, fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: ClassicTheme.dangerRed),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showOnboardDialogFromRequest(
                    requestId: request.id,
                    clientName: request.clientName,
                    shopName: request.shopName,
                    category: request.businessCategory,
                    email: request.email,
                    mobile: request.mobile,
                    initialAadhaar: request.rawData['aadhaar']?.toString() ?? '',
                    initialPan: request.rawData['pan']?.toString() ?? '',
                    initialGst: (request.rawData['gstNo'] ?? request.rawData['gst'])?.toString() ?? '',
                    initialAddress: request.cityOrAddress,
                    initialTrialDays: (request.rawData['requestedTrialDays'] ?? 14) as int,
                    initialMaxUsers: (request.rawData['requestedMaxUsers'] ?? 5) as int,
                    initialMaxOutlets: (request.rawData['requestedStoreCount'] ?? 1) as int,
                    initialTableCount: (request.rawData['tableCount'] ?? 10) as int,
                    initialOperatingMode: request.rawData['preferredOperatingMode']?.toString() ?? 'dineFirstPostpaid',
                    initialRoles: (request.rawData['requestedRoles'] is List)
                        ? List<String>.from(request.rawData['requestedRoles'])
                        : null,
                    initialFeatures: (request.rawData['requestedFeatures'] is Map)
                        ? Map<String, bool>.from((request.rawData['requestedFeatures'] as Map).map((k, v) => MapEntry(k.toString(), v == true)))
                        : null,
                    initialPackageId: (request.rawData['requestedPackageId'] ?? '').toString(),
                    initialPlanId: (request.rawData['requestedPlanId'] ?? '').toString(),
                  );
                },
                icon: const Icon(Icons.rocket_launch_rounded, size: 16),
                label: const Text("Approve & Onboard Store", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.successEmerald,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],

            // Actions for Commercial Plan Inquiry
            if (!isTrial && (request.status == 'NEW_INQUIRY' || request.status == 'PENDING')) ...[
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _firestore.collection('business_inquiries').doc(request.id).update({
                    'status': 'ARCHIVED',
                    'archivedAt': FieldValue.serverTimestamp(),
                  });
                  if (mounted) {
                    AppToast.showSuccess(context, "Inquiry archived.");
                  }
                },
                icon: const Icon(Icons.archive_outlined, size: 16, color: Colors.grey),
                label: const Text("Archive", style: TextStyle(color: Colors.grey, fontSize: 12)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: Colors.grey),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () async {
                  Navigator.pop(ctx);
                  await _firestore.collection('business_inquiries').doc(request.id).update({
                    'status': 'CONTACTED',
                    'contactedAt': FieldValue.serverTimestamp(),
                  });
                  if (mounted) {
                    AppToast.showSuccess(context, "Marked as Contacted.");
                  }
                },
                icon: const Icon(Icons.check_rounded, size: 16, color: ClassicTheme.infoBlue),
                label: const Text("Mark as Contacted", style: TextStyle(color: ClassicTheme.infoBlue, fontSize: 12, fontWeight: FontWeight.bold)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: ClassicTheme.infoBlue),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showOnboardDialogFromRequest(
                    requestId: request.id,
                    clientName: request.clientName,
                    shopName: request.shopName,
                    category: request.businessCategory,
                    email: request.email,
                    mobile: request.mobile,
                    initialAddress: request.cityOrAddress,
                    initialTrialDays: 365,
                    initialMaxUsers: 10,
                    initialMaxOutlets: request.outlets.contains('5') ? 5 : (request.outlets.contains('6') ? 10 : 1),
                    initialTableCount: 20,
                  );
                },
                icon: const Icon(Icons.rocket_launch_rounded, size: 16),
                label: const Text("Onboard Store Directly", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.secondaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],

            if (!isTrial && request.status == 'CONTACTED') ...[
              ElevatedButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _showOnboardDialogFromRequest(
                    requestId: request.id,
                    clientName: request.clientName,
                    shopName: request.shopName,
                    category: request.businessCategory,
                    email: request.email,
                    mobile: request.mobile,
                    initialAddress: request.cityOrAddress,
                    initialTrialDays: 365,
                    initialMaxUsers: 10,
                    initialMaxOutlets: request.outlets.contains('5') ? 5 : (request.outlets.contains('6') ? 10 : 1),
                    initialTableCount: 20,
                  );
                },
                icon: const Icon(Icons.rocket_launch_rounded, size: 16),
                label: const Text("Convert & Onboard Store", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.successEmerald,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryAccent = context.isDark ? ClassicTheme.infoBlue : ClassicTheme.infoBlue;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header & Search Bar
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Client Requests & Inquiries",
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      "Real-time incoming Free Trial signups & commercial plan leads",
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          // Search Field
          TextField(
            controller: _searchController,
            style: TextStyle(color: context.textPrimary, fontSize: 13),
            decoration: InputDecoration(
              hintText: "Search by client name, restaurant, mobile, email, city...",
              hintStyle: TextStyle(color: context.textSecondary, fontSize: 12.5),
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: _searchQuery.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear_rounded, size: 16),
                      onPressed: () {
                        setState(() {
                          _searchController.clear();
                          _searchQuery = '';
                        });
                      },
                    )
                  : null,
              filled: true,
              fillColor: context.surfaceColor,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: context.borderColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: context.borderColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: primaryAccent, width: 1.5),
              ),
            ),
            onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 10),

          // Filter Chips Bar
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _filterChip("Pending", 'PENDING', ClassicTheme.warningAmber),
                const SizedBox(width: 6),
                _filterChip("Free Trials", 'TRIALS', ClassicTheme.successEmerald),
                const SizedBox(width: 6),
                _filterChip("Plan Inquiries", 'INQUIRIES', ClassicTheme.secondaryAccent),
                const SizedBox(width: 6),
                _filterChip("Approved / Done", 'APPROVED', ClassicTheme.successEmerald),
                const SizedBox(width: 6),
                _filterChip("All", 'ALL', primaryAccent),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Dual Stream Builder (registration_requests + business_inquiries)
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('registration_requests')
                  .snapshots(),
              builder: (context, regSnapshot) {
                return StreamBuilder<QuerySnapshot>(
                  stream: _firestore
                      .collection('business_inquiries')
                      .snapshots(),
                  builder: (context, inqSnapshot) {
                    if (regSnapshot.connectionState == ConnectionState.waiting &&
                        inqSnapshot.connectionState == ConnectionState.waiting) {
                      return Center(child: CircularProgressIndicator(color: primaryAccent));
                    }

                    // Parse Free Trials
                    final List<UnifiedClientRequest> trialList = [];
                    if (regSnapshot.hasData) {
                      for (var doc in regSnapshot.data!.docs) {
                        final d = doc.data() as Map<String, dynamic>;
                        final created = (d['createdAt'] as Timestamp?)?.toDate();
                        trialList.add(UnifiedClientRequest(
                          id: doc.id,
                          requestType: 'FREE_TRIAL',
                          clientName: d['clientName'] ?? 'Unknown Client',
                          shopName: d['shopName'] ?? '',
                          businessCategory: d['businessCategory'] ?? 'Restaurant & Cafe',
                          email: d['email'] ?? '',
                          mobile: d['mobile'] ?? d['phone'] ?? '',
                          cityOrAddress: d['address'] ?? d['city'] ?? '',
                          referralSource: d['referralSource'] ?? 'Direct',
                          selectedPlan: '14-Day Free Trial',
                          outlets: "${d['requestedStoreCount'] ?? 1} Outlet",
                          stations: "${d['requestedMaxUsers'] ?? 5} Staff / Terminals",
                          notes: d['notes'] ?? d['requirements'] ?? '',
                          status: (d['status'] ?? 'PENDING').toString().toUpperCase(),
                          createdAt: created,
                          rawData: d,
                        ));
                      }
                    }

                    // Parse Business Inquiries
                    final List<UnifiedClientRequest> inquiryList = [];
                    if (inqSnapshot.hasData) {
                      for (var doc in inqSnapshot.data!.docs) {
                        final d = doc.data() as Map<String, dynamic>;
                        final created = (d['createdAt'] as Timestamp?)?.toDate();
                        inquiryList.add(UnifiedClientRequest(
                          id: doc.id,
                          requestType: 'PLAN_INQUIRY',
                          clientName: d['clientName'] ?? d['name'] ?? 'Commercial Lead',
                          shopName: d['brandName'] ?? d['shopName'] ?? '',
                          businessCategory: d['businessModel'] ?? d['category'] ?? 'Restaurant',
                          email: d['email'] ?? '',
                          mobile: d['phone'] ?? d['mobile'] ?? '',
                          cityOrAddress: d['city'] ?? d['address'] ?? '',
                          referralSource: d['referralSource'] ?? 'Website Inquiry',
                          selectedPlan: d['selectedPlan'] ?? d['plan'] ?? 'Commercial Plan',
                          outlets: d['outletsCount']?.toString() ?? '1 Outlet',
                          stations: d['stationsCount']?.toString() ?? 'Standard Setup',
                          notes: d['requirements'] ?? d['notes'] ?? '',
                          status: (d['status'] ?? 'NEW_INQUIRY').toString().toUpperCase(),
                          createdAt: created,
                          rawData: d,
                        ));
                      }
                    }

                    // Merge & Sort
                    List<UnifiedClientRequest> allRequests = [...trialList, ...inquiryList];
                    allRequests.sort((a, b) {
                      if (a.createdAt == null && b.createdAt == null) return 0;
                      if (a.createdAt == null) return 1;
                      if (b.createdAt == null) return -1;
                      return b.createdAt!.compareTo(a.createdAt!);
                    });

                    // Filter by selected tab chip
                    if (_selectedFilter == 'PENDING') {
                      allRequests = allRequests.where((r) => r.isPending).toList();
                    } else if (_selectedFilter == 'TRIALS') {
                      allRequests = allRequests.where((r) => r.isTrial).toList();
                    } else if (_selectedFilter == 'INQUIRIES') {
                      allRequests = allRequests.where((r) => !r.isTrial).toList();
                    } else if (_selectedFilter == 'APPROVED') {
                      allRequests = allRequests.where((r) =>
                        r.status == 'APPROVED' || r.status == 'CONTACTED' || r.status == 'CONVERTED'
                      ).toList();
                    }

                    // Filter by search query
                    if (_searchQuery.isNotEmpty) {
                      allRequests = allRequests.where((r) =>
                        r.clientName.toLowerCase().contains(_searchQuery) ||
                        r.shopName.toLowerCase().contains(_searchQuery) ||
                        r.mobile.toLowerCase().contains(_searchQuery) ||
                        r.email.toLowerCase().contains(_searchQuery) ||
                        r.cityOrAddress.toLowerCase().contains(_searchQuery) ||
                        r.selectedPlan.toLowerCase().contains(_searchQuery)
                      ).toList();
                    }

                    if (allRequests.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.inbox_rounded, size: 48, color: context.textSecondary.withValues(alpha: 0.5)),
                            const SizedBox(height: 10),
                            Text(
                              "No requests match the current criteria.",
                              style: TextStyle(color: context.textSecondary),
                            ),
                          ],
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: allRequests.length,
                      itemBuilder: (context, index) {
                        final req = allRequests[index];
                        final isTrial = req.isTrial;
                        final cleanPhone = req.mobile.replaceAll(RegExp(r'[^0-9+]'), '');

                        return Card(
                          color: context.surfaceColor,
                          elevation: 0,
                          margin: const EdgeInsets.only(bottom: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(
                              color: req.isPending
                                  ? ClassicTheme.warningAmber.withValues(alpha: 0.4)
                                  : context.borderColor,
                            ),
                          ),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () => _showRequestDetailsDialog(req),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Header Row
                                  Row(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      // Type Avatar Icon
                                      Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: (isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent).withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(8),
                                        ),
                                        child: Icon(
                                          isTrial ? Icons.storefront_rounded : Icons.business_center_rounded,
                                          color: isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent,
                                          size: 20,
                                        ),
                                      ),
                                      const SizedBox(width: 12),

                                      // Client & Shop Name
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: Text(
                                                    req.clientName,
                                                    style: TextStyle(
                                                      color: context.textPrimary,
                                                      fontWeight: FontWeight.bold,
                                                      fontSize: 15,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                            if (req.shopName.isNotEmpty)
                                              Text(
                                                req.shopName,
                                                style: TextStyle(
                                                  color: primaryAccent,
                                                  fontWeight: FontWeight.w600,
                                                  fontSize: 13,
                                                ),
                                              ),
                                          ],
                                        ),
                                      ),

                                      // Badges Column
                                      Column(
                                        crossAxisAlignment: CrossAxisAlignment.end,
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: _getStatusColor(req.status).withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(6),
                                            ),
                                            child: Text(
                                              req.status,
                                              style: TextStyle(
                                                color: _getStatusColor(req.status),
                                                fontWeight: FontWeight.bold,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: (isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent).withValues(alpha: 0.1),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              isTrial ? "Trial" : req.selectedPlan,
                                              style: TextStyle(
                                                color: isTrial ? ClassicTheme.successEmerald : ClassicTheme.secondaryAccent,
                                                fontSize: 12,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),

                                  // Detail chips & contact info
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 6,
                                    children: [
                                      _infoBadge(Icons.phone_android_outlined, req.mobile),
                                      _infoBadge(Icons.mail_outline, req.email),
                                      _infoBadge(Icons.category_outlined, req.businessCategory),
                                      _infoBadge(Icons.store_outlined, req.outlets),
                                      if (req.cityOrAddress.isNotEmpty)
                                        _infoBadge(Icons.location_on_outlined, req.cityOrAddress),
                                      if (req.referralSource.isNotEmpty)
                                        _infoBadge(Icons.share_outlined, req.referralSource),
                                      if (req.createdAt != null)
                                        _infoBadge(Icons.calendar_today_outlined, "${req.createdAt!.day}/${req.createdAt!.month}/${req.createdAt!.year}"),
                                    ],
                                  ),

                                  const SizedBox(height: 12),
                                  Divider(height: 1, color: context.borderColor),
                                  const SizedBox(height: 8),

                                  // Card Quick Actions Row
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      // Quick Call & WhatsApp
                                      Row(
                                        children: [
                                          if (cleanPhone.isNotEmpty) ...[
                                            IconButton(
                                              icon: const Icon(Icons.call_rounded, size: 18, color: ClassicTheme.infoBlue),
                                              tooltip: "Call ${req.mobile}",
                                              onPressed: () => _makePhoneCall(req.mobile),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            ),
                                            const SizedBox(width: 4),
                                            IconButton(
                                              icon: const Icon(Icons.chat_bubble_outline_rounded, size: 18, color: Color(0xFF25D366)),
                                              tooltip: "WhatsApp ${req.clientName}",
                                              onPressed: () => _openWhatsApp(req.mobile, req.clientName),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            ),
                                            const SizedBox(width: 4),
                                          ],
                                          if (req.email.isNotEmpty)
                                            IconButton(
                                              icon: Icon(Icons.mail_outline_rounded, size: 18, color: ClassicTheme.secondaryAccent),
                                              tooltip: "Email ${req.email}",
                                              onPressed: () => _sendEmail(req.email, req.clientName),
                                              padding: EdgeInsets.zero,
                                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                            ),
                                        ],
                                      ),

                                      // On-click details trigger button
                                      TextButton.icon(
                                        onPressed: () => _showRequestDetailsDialog(req),
                                        icon: const Icon(Icons.visibility_outlined, size: 15),
                                        label: const Text("View Details & Actions", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, String value, Color color) {
    final isSelected = _selectedFilter == value;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 12, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      selected: isSelected,
      selectedColor: color.withValues(alpha: 0.2),
      onSelected: (_) => setState(() => _selectedFilter = value),
    );
  }

  Color _getStatusColor(String status) {
    switch (status.toUpperCase()) {
      case 'APPROVED':
      case 'CONVERTED':
        return ClassicTheme.successEmerald;
      case 'CONTACTED':
        return ClassicTheme.infoBlue;
      case 'REJECTED':
      case 'ARCHIVED':
        return ClassicTheme.dangerRed;
      case 'NEW_INQUIRY':
      case 'PENDING':
      default:
        return ClassicTheme.warningAmber;
    }
  }

  Widget _infoBadge(IconData icon, String text, {bool isVerified = false, bool isAccent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isAccent ? ClassicTheme.infoBlue.withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: isAccent ? ClassicTheme.infoBlue : Colors.grey),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 12, fontWeight: isAccent ? FontWeight.bold : FontWeight.normal)),
          if (isVerified) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified_rounded, size: 12, color: ClassicTheme.successEmerald),
          ],
        ],
      ),
    );
  }
}
