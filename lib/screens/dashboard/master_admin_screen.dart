import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../../providers/theme_provider.dart';
import '../../core/subscription_plan_model.dart';
import '../../services/subscription_plan_service.dart';
import '../../services/tenant_provisioning_service.dart';
import 'franchise_payment_settings_dialog.dart';

class MasterAdminScreen extends ConsumerStatefulWidget {
  const MasterAdminScreen({super.key});

  @override
  ConsumerState<MasterAdminScreen> createState() => _MasterAdminScreenState();
}

class _MasterAdminScreenState extends ConsumerState<MasterAdminScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
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
                Icon(Icons.warning_amber_rounded, color: Colors.redAccent, size: 24),
                SizedBox(width: 8),
                Text("Clear All Client Data", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ],
            ),
            content: SizedBox(
              width: 460,
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
                            AppToast.showSuccess(context, res['message']);
                          } else {
                            AppToast.showError(context, res['message']);
                          }
                        }
                      },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.redAccent,
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

  void _showFranchisePaymentSettingsDialog() {
    showDialog(
      context: context,
      builder: (ctx) => const FranchisePaymentSettingsDialog(),
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
                  decoration: BoxDecoration(color: const Color(0xFF0284C7).withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.mark_email_read_rounded, color: Color(0xFF0284C7), size: 22),
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
                          ? Colors.green.withValues(alpha: 0.15)
                          : Colors.amber.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      (usernameController.text.isNotEmpty && passwordController.text.isNotEmpty) ? "CONFIGURED" : "PENDING SETUP",
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: (usernameController.text.isNotEmpty && passwordController.text.isNotEmpty) ? Colors.green : Colors.amber.shade800,
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
                            subtitle: Text("Enable if connecting directly via Port 465 (Gmail Port 587 uses STARTTLS by default)", style: TextStyle(color: context.textSecondary, fontSize: 11)),
                            value: isSsl,
                            activeColor: const Color(0xFF0284C7),
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
                                          if (ctx.mounted) {
                                            AppToast.showSuccess(context, "Test email sent successfully to ${testEmailController.text.trim()}!");
                                          }
                                        } catch (e) {
                                          if (ctx.mounted) {
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
                                  backgroundColor: const Color(0xFF0284C7),
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
                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      AppToast.showSuccess(context, "SMTP Mail Server Configuration Saved!");
                    }
                  } catch (e) {
                    setDialogState(() => isSaving = false);
                    if (ctx.mounted) AppToast.showError(context, e.toString());
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF0284C7),
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
                  decoration: BoxDecoration(color: Colors.green.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: const Icon(Icons.cloud_sync_rounded, color: Colors.green, size: 22),
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
              width: 480,
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
                        color: testSuccess ? Colors.green.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: testSuccess ? Colors.green : Colors.red),
                      ),
                      child: Row(
                        children: [
                          Icon(testSuccess ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                              color: testSuccess ? Colors.green : Colors.red, size: 18),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              testResult!,
                              style: TextStyle(
                                  color: testSuccess ? Colors.green.shade800 : Colors.red.shade800,
                                  fontSize: 11.5,
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
                style: ElevatedButton.styleFrom(backgroundColor: Colors.green, foregroundColor: Colors.white),
                onPressed: () async {
                  final url = urlController.text.trim();
                  await AppsScriptBackendService.setWebhookUrl(url);
                  if (ctx.mounted) {
                    Navigator.pop(ctx);
                    AppToast.showSuccess(
                      context,
                      "Google Apps Script Webhook Saved!",
                      subtitle: "New client stores will automatically create Google Spreadsheets in your Drive.",
                    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        title: Text("SmartBiz Control Panel", style: TextStyle(fontWeight: FontWeight.bold, color: context.textPrimary, fontSize: 16)),
        backgroundColor: context.canvasColor,
        actions: [
          IconButton(
            icon: const Icon(Icons.cloud_sync_rounded, color: Colors.green),
            tooltip: "Cloud Database Webhook Settings",
            onPressed: _showWebhookSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.email_outlined, color: Color(0xFF38BDF8)),
            tooltip: "Platform SMTP Email Settings",
            onPressed: _showSmtpSettingsDialog,
          ),
          IconButton(
            icon: const Icon(Icons.cleaning_services_rounded, color: Colors.orangeAccent),
            tooltip: "Clean Database (Keep Admin)",
            onPressed: _showClearDatabaseDialog,
          ),
          Consumer(
            builder: (context, ref, _) {
              final mode = ref.watch(themeModeProvider);
              final isDark = mode == ThemeMode.dark;
              return IconButton(
                icon: Icon(isDark ? Icons.light_mode_outlined : Icons.dark_mode_outlined, color: context.textPrimary),
                tooltip: isDark ? 'Switch to Light Mode' : 'Switch to Dark Mode',
                onPressed: () {
                  ref.read(themeModeProvider.notifier).toggleTheme();
                  HapticFeedback.lightImpact();
                },
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.payment_rounded, color: Color(0xFFF59E0B)),
            onPressed: _showFranchisePaymentSettingsDialog,
            tooltip: "Apply Store Razorpay Gateways",
          ),
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: ClassicTheme.dangerRed),
            onPressed: () => ref.read(authProvider.notifier).signOut(),
            tooltip: "Log Out",
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
          unselectedLabelColor: context.textSecondary,
          indicatorColor: context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB),
          indicatorWeight: 3,
          labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12.5),
          tabs: [
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('renewal_requests')
                  .where('status', isEqualTo: 'PENDING')
                  .snapshots(),
              builder: (context, snapshot) {
                final pendingRenewals = snapshot.hasData ? snapshot.data!.docs.length : 0;
                return Tab(
                  icon: Badge(
                    isLabelVisible: pendingRenewals > 0,
                    backgroundColor: Colors.amber.shade700,
                    label: Text('$pendingRenewals', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black)),
                    child: const Icon(Icons.business_rounded),
                  ),
                  text: "Organizations",
                );
              },
            ),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('registration_requests')
                  .where('status', isEqualTo: 'PENDING')
                  .snapshots(),
              builder: (context, snapshot) {
                final pendingCount = snapshot.hasData ? snapshot.data!.docs.length : 0;
                return Tab(
                  icon: Badge(
                    isLabelVisible: pendingCount > 0,
                    label: Text('$pendingCount', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold)),
                    child: const Icon(Icons.assignment_ind_rounded),
                  ),
                  text: "Requests",
                );
              },
            ),
            const Tab(icon: Icon(Icons.layers_rounded), text: "Plans & Features"),
            const Tab(icon: Icon(Icons.history_rounded), text: "Audit Logs"),
            const Tab(icon: Icon(Icons.system_update_alt_rounded), text: "App Updates"),
          ],
        ),
      ),
      body: Material(
        color: context.canvasColor,
        child: TabBarView(
          controller: _tabController,
          children: const [
            OrganizationsTab(),
            RegistrationRequestsTab(),
            PlansAndFeaturesTab(),
            AuditLogsTab(),
            AppUpdatesTab(),
          ],
        ),
      ),
    );
  }
}

// --- TAB 1: ORGANIZATIONS MANAGEMENT ---
class OrganizationsTab extends ConsumerStatefulWidget {
  const OrganizationsTab({super.key});

  @override
  ConsumerState<OrganizationsTab> createState() => _OrganizationsTabState();
}

class _OrganizationsTabState extends ConsumerState<OrganizationsTab> {
  final _firestore = FirebaseFirestore.instance;

  String _generateUniqueOrgId() {
    final now = DateTime.now();
    final year = now.year.toString().substring(2);
    final randomDigits = 1000 + Random().nextInt(9000);
    return "ORG$year$randomDigits";
  }

  Widget _buildFeatureGroup({
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
          Text(subtitle, style: TextStyle(color: context.textSecondary, fontSize: 11)),
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

  Widget _featureChipWidget({
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
                style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold),
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

  void _showAddOrganizationDialog() {
    _showOnboardOrganizationDialog(context);
  }

  void _showOnboardOrganizationDialog(
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
    final orgIdController = TextEditingController(text: _generateUniqueOrgId());
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

    int validityDays = selectedPlan.validityDays;
    int maxOutlets = selectedPlan.maxOutlets;
    int maxDevices = selectedPlan.maxDevices;
    int maxUsers = selectedPlan.maxUsers;
    int tableCount = selectedPlan.tableCount;
    String operatingMode = selectedPlan.operatingMode;

    // Feature Toggles: populated dynamically from the selected plan
    final Map<String, bool> featureToggles = Map<String, bool>.from(selectedPlan.features);

    bool isCreating = false;
    bool obscurePassword = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            final primaryAccent = const Color(0xFFF59E0B);
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
                      style: TextStyle(color: primaryAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 650,
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

                        // SECTION 2: DYNAMIC SUBSCRIPTION PLAN & ALLOCATIONS
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.workspace_premium_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("2. Subscription Plan & Quota Allocations", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<SubscriptionPlan>(
                          value: availablePlans.any((p) => p.id == selectedPlan.id)
                              ? availablePlans.firstWhere((p) => p.id == selectedPlan.id)
                              : selectedPlan,
                          dropdownColor: context.surfaceColor,
                          style: TextStyle(color: context.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Assigned Plan (Auto-Populates Features & Limits)",
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                            prefixIcon: const Icon(Icons.stars_rounded, size: 18),
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                            focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                          ),
                          items: availablePlans.map((plan) {
                            return DropdownMenuItem<SubscriptionPlan>(
                              value: plan,
                              child: Text(
                                "${plan.name}  —  ₹${plan.price.toStringAsFixed(0)} / ${plan.validityDays} Days (${plan.billingCycle})",
                                style: TextStyle(
                                  fontWeight: plan.isDefaultTrial ? FontWeight.bold : FontWeight.normal,
                                  color: plan.isDefaultTrial ? primaryAccent : null,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (newPlan) {
                            if (newPlan != null) {
                              setDialogState(() {
                                selectedPlan = newPlan;
                                validityDays = newPlan.validityDays;
                                maxOutlets = newPlan.maxOutlets;
                                maxDevices = newPlan.maxDevices;
                                maxUsers = newPlan.maxUsers;
                                tableCount = newPlan.tableCount;
                                operatingMode = newPlan.operatingMode;
                                featureToggles.clear();
                                featureToggles.addAll(newPlan.features);
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                initialValue: validityDays.toString(),
                                key: ValueKey('val_$validityDays'),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Validity (Days)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.calendar_today_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => validityDays = int.tryParse(v) ?? validityDays,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: maxOutlets.toString(),
                                key: ValueKey('out_$maxOutlets'),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Max Branches / Outlets",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.store_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => maxOutlets = int.tryParse(v) ?? maxOutlets,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: tableCount.toString(),
                                key: ValueKey('tab_$tableCount'),
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
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                initialValue: maxUsers.toString(),
                                key: ValueKey('usr_$maxUsers'),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Max Staff / Users",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.badge_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => maxUsers = int.tryParse(v) ?? maxUsers,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: maxDevices.toString(),
                                key: ValueKey('dev_$maxDevices'),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Max POS Terminals",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.devices_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => maxDevices = int.tryParse(v) ?? maxDevices,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: DropdownButtonFormField<String>(
                                value: operatingMode,
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
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),

                        // SECTION 3: FEATURE ENTITLEMENTS (Grouped from Catalog)
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              Icon(Icons.checklist_rtl_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("3. Feature Entitlements (Dynamic Catalog)", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...RestaurantFeatureCatalog.byCategory.entries.map((catEntry) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _buildFeatureGroup(
                              context: context,
                              title: catEntry.key,
                              subtitle: "Configured capabilities for ${catEntry.key}",
                              icon: Icons.tune_rounded,
                              accentColor: primaryAccent,
                              children: catEntry.value.map((feat) {
                                final isSelected = featureToggles[feat.key] ?? false;
                                return _featureChipWidget(
                                  label: feat.label,
                                  subtitle: feat.description,
                                  selected: isSelected,
                                  color: primaryAccent,
                                  onSelected: (v) {
                                    setDialogState(() {
                                      featureToggles[feat.key] = v;
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                          );
                        }),
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

                            final finalPlan = selectedPlan.copyWith(
                              validityDays: validityDays,
                              maxOutlets: maxOutlets,
                              maxDevices: maxDevices,
                              maxUsers: maxUsers,
                              tableCount: tableCount,
                              operatingMode: operatingMode,
                              features: featureToggles,
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
                            );

                            if (result['success'] != true) {
                              throw Exception(result['message'] ?? "Onboarding failed");
                            }

                            if (context.mounted) {
                              Navigator.pop(context);
                              AppToast.showSuccess(
                                context,
                                "Restaurant Onboarded Successfully",
                                subtitle: "$orgName ($orgId) onboarded with ${selectedPlan.name}.",
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


  void _showRenewLicenseDialog(String orgId, String orgName) {
    bool isLoading = true;
    bool isSaving = false;
    bool isDataLoaded = false;

    String planTier = 'TRIAL';
    DateTime endDate = DateTime.now().add(const Duration(days: 14));
    int expiryWarningDays = 3;
    int maxUsers = 5;
    int maxFranchises = 1;
    List<String> allowedRoles = ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'];

    // Restaurant Feature Toggles
    bool qsrBilling = true;
    bool tableManagement = true;
    bool kdsEnabled = true;
    bool qrOrdering = true;
    bool dualPrinting = true;
    bool recipeInventory = true;
    bool dayEndReports = true;
    bool multiOutlet = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

          if (!isDataLoaded) {
            isDataLoaded = true;
            Future.microtask(() async {
              try {
                final licDoc = await _firestore.collection('licenses').doc(orgId).get();
                if (licDoc.exists) {
                  final lData = licDoc.data()!;
                  planTier = lData['planTier'] ?? 'TRIAL';
                  expiryWarningDays = lData['expiryWarningDays'] is num ? (lData['expiryWarningDays'] as num).toInt() : 3;
                  maxUsers = lData['maxUsers'] is num ? (lData['maxUsers'] as num).toInt() : 5;
                  maxFranchises = lData['maxFranchises'] is num ? (lData['maxFranchises'] as num).toInt() : 1;
                  if (lData['allowedRoles'] is List) {
                    allowedRoles = List<String>.from((lData['allowedRoles'] as List).map((e) => e.toString().toUpperCase()));
                  }
                  if (lData['endDate'] is Timestamp) {
                    endDate = (lData['endDate'] as Timestamp).toDate();
                  } else if (lData['endDate'] is String) {
                    endDate = DateTime.tryParse(lData['endDate']) ?? endDate;
                  }
                  if (endDate.isBefore(DateTime.now())) {
                    endDate = DateTime.now().add(const Duration(days: 14));
                  }
                }

                final featDoc = await _firestore.collection('features').doc(orgId).get();
                if (featDoc.exists) {
                  final fData = Map<String, dynamic>.from(featDoc.data()?['features'] ?? {});
                  qsrBilling = fData['qsrBilling'] ?? fData['billing'] ?? true;
                  tableManagement = fData['tableManagement'] ?? true;
                  kdsEnabled = fData['kdsEnabled'] ?? true;
                  qrOrdering = fData['qrOrdering'] ?? fData['onlineOrderingEnabled'] ?? true;
                  dualPrinting = fData['dualPrinting'] ?? true;
                  recipeInventory = fData['recipeInventory'] ?? fData['inventoryEnabled'] ?? true;
                  dayEndReports = fData['dayEndReports'] ?? fData['reportsEnabled'] ?? true;
                  multiOutlet = fData['multiOutlet'] ?? (maxFranchises > 1);
                }
              } catch (e) {
                debugPrint("Error reading license for renewal: $e");
              } finally {
                if (ctx.mounted) {
                  setDialogState(() => isLoading = false);
                }
              }
            });
          }

          final daysLeft = endDate.difference(DateTime.now()).inDays.clamp(0, 99999);

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
                  decoration: BoxDecoration(
                    color: Colors.green.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.card_membership_rounded, color: Colors.green, size: 22),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Renew / Configure License", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16)),
                      Text("$orgName (ID: $orgId)", style: TextStyle(color: context.textSecondary, fontSize: 12)),
                    ],
                  ),
                ),
              ],
            ),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: min(560, MediaQuery.of(ctx).size.width * 0.92),
              ),
              child: isLoading
                  ? SizedBox(
                      height: 240,
                      child: Center(child: CircularProgressIndicator(color: primaryAccent)),
                    )
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text("Subscription Plan & Validity", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                flex: 2,
                                child: DropdownButtonFormField<String>(
                                  value: planTier,
                                  dropdownColor: context.surfaceColor,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                                  decoration: ClassicTheme.inputDecorationFor(context, labelText: "Plan Tier"),
                                  items: const [
                                    DropdownMenuItem(value: 'TRIAL', child: Text("Free Trial")),
                                    DropdownMenuItem(value: 'MONTHLY', child: Text("Monthly Active")),
                                    DropdownMenuItem(value: 'YEARLY', child: Text("Annual Paid")),
                                    DropdownMenuItem(value: 'LIFETIME', child: Text("Lifetime Enterprise")),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      setDialogState(() {
                                        planTier = val;
                                        if (val == 'MONTHLY') {
                                          endDate = DateTime.now().add(const Duration(days: 30));
                                        } else if (val == 'YEARLY') {
                                          endDate = DateTime.now().add(const Duration(days: 365));
                                        } else if (val == 'LIFETIME') {
                                          endDate = DateTime.now().add(const Duration(days: 36500));
                                        }
                                      });
                                    }
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                flex: 2,
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  decoration: BoxDecoration(
                                    color: context.isDark ? Colors.white.withValues(alpha: 0.05) : Colors.black.withValues(alpha: 0.04),
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text("Expires On", style: TextStyle(color: context.textSecondary, fontSize: 10)),
                                      const SizedBox(height: 2),
                                      Text(
                                        "${endDate.day}/${endDate.month}/${endDate.year} ($daysLeft days)",
                                        style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text("Quick Extend Duration:", style: TextStyle(color: context.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              ActionChip(
                                label: const Text("+7 Days", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                onPressed: () => setDialogState(() => endDate = DateTime.now().add(const Duration(days: 7))),
                              ),
                              ActionChip(
                                label: const Text("+14 Days", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                onPressed: () => setDialogState(() => endDate = DateTime.now().add(const Duration(days: 14))),
                              ),
                              ActionChip(
                                label: const Text("+30 Days", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                onPressed: () => setDialogState(() => endDate = DateTime.now().add(const Duration(days: 30))),
                              ),
                              ActionChip(
                                label: const Text("+1 Year", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                onPressed: () => setDialogState(() => endDate = DateTime.now().add(const Duration(days: 365))),
                              ),
                              ActionChip(
                                avatar: const Icon(Icons.calendar_today, size: 14),
                                label: const Text("Pick Date", style: TextStyle(fontSize: 11)),
                                onPressed: () async {
                                  final picked = await showDatePicker(
                                    context: context,
                                    initialDate: endDate,
                                    firstDate: DateTime.now(),
                                    lastDate: DateTime.now().add(const Duration(days: 36500)),
                                  );
                                  if (picked != null) {
                                    setDialogState(() => endDate = picked);
                                  }
                                },
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text("Advance Expiry Notice", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(
                            "Notify administrators and display in-app reminder before subscription ends.",
                            style: TextStyle(color: context.textSecondary, fontSize: 11),
                          ),
                          const SizedBox(height: 8),
                          DropdownButtonFormField<int>(
                            value: expiryWarningDays,
                            dropdownColor: context.surfaceColor,
                            style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                            decoration: ClassicTheme.inputDecorationFor(context, labelText: "Alert Ahead of Expiry"),
                            items: const [
                              DropdownMenuItem(value: 1, child: Text("1 Day in Advance")),
                              DropdownMenuItem(value: 3, child: Text("3 Days in Advance (Recommended)")),
                              DropdownMenuItem(value: 5, child: Text("5 Days in Advance")),
                              DropdownMenuItem(value: 7, child: Text("7 Days in Advance")),
                              DropdownMenuItem(value: 14, child: Text("14 Days in Advance")),
                            ],
                            onChanged: (val) {
                              if (val != null) setDialogState(() => expiryWarningDays = val);
                            },
                          ),
                          const SizedBox(height: 16),
                          Text("Operational Limits & Quotas", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  value: maxUsers,
                                  dropdownColor: context.surfaceColor,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                                  decoration: ClassicTheme.inputDecorationFor(context, labelText: "Max Staff Users"),
                                  items: const [
                                    DropdownMenuItem(value: 3, child: Text("3 Users (Starter)")),
                                    DropdownMenuItem(value: 5, child: Text("5 Users (Standard)")),
                                    DropdownMenuItem(value: 10, child: Text("10 Users (Busy)")),
                                    DropdownMenuItem(value: 20, child: Text("20 Users (Large)")),
                                    DropdownMenuItem(value: 50, child: Text("50 Users (Chain)")),
                                    DropdownMenuItem(value: 100, child: Text("100 Users (Enterprise)")),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) setDialogState(() => maxUsers = val);
                                  },
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: DropdownButtonFormField<int>(
                                  value: maxFranchises,
                                  dropdownColor: context.surfaceColor,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.bold),
                                  decoration: ClassicTheme.inputDecorationFor(context, labelText: "Max Outlets"),
                                  items: const [
                                    DropdownMenuItem(value: 1, child: Text("1 Store (Single)")),
                                    DropdownMenuItem(value: 3, child: Text("3 Branches")),
                                    DropdownMenuItem(value: 5, child: Text("5 Branches")),
                                    DropdownMenuItem(value: 10, child: Text("10 Branches")),
                                    DropdownMenuItem(value: 25, child: Text("25 Branches")),
                                  ],
                                  onChanged: (val) {
                                    if (val != null) {
                                      setDialogState(() {
                                        maxFranchises = val;
                                        if (val > 1) multiOutlet = true;
                                      });
                                    }
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text("Permitted Roles for this Organization", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              for (final role in ['OWNER', 'MANAGER', 'BILLING', 'KITCHEN', 'WAITER'])
                                FilterChip(
                                  label: Text(
                                    role == 'OWNER' ? 'Owner / Admin' :
                                    role == 'MANAGER' ? 'Store Manager' :
                                    role == 'BILLING' ? 'Cashier / Billing' :
                                    role == 'KITCHEN' ? 'Kitchen Chef' : 'Table Captain / Waiter',
                                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: allowedRoles.contains(role) ? primaryAccent : null),
                                  ),
                                  selected: allowedRoles.contains(role),
                                  selectedColor: primaryAccent.withValues(alpha: 0.15),
                                  onSelected: (selected) {
                                    setDialogState(() {
                                      if (selected) {
                                        if (!allowedRoles.contains(role)) allowedRoles.add(role);
                                      } else {
                                        if (role != 'OWNER') allowedRoles.remove(role);
                                      }
                                    });
                                  },
                                ),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text("Dynamic Feature Toggles (Real-Time Propagation)", style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                          const SizedBox(height: 4),
                          Text("Changes reflect on client POS terminals instantly without app restarts.", style: TextStyle(color: context.textSecondary, fontSize: 11)),
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              FilterChip(
                                label: const Text("Fast QSR Billing", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: qsrBilling,
                                onSelected: (val) => setDialogState(() => qsrBilling = val),
                              ),
                              FilterChip(
                                label: const Text("Dine-In Tables", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: tableManagement,
                                onSelected: (val) => setDialogState(() => tableManagement = val),
                              ),
                              FilterChip(
                                label: const Text("Kitchen Screen (KDS)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: kdsEnabled,
                                onSelected: (val) => setDialogState(() => kdsEnabled = val),
                              ),
                              FilterChip(
                                label: const Text("Table QR Menu", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: qrOrdering,
                                onSelected: (val) => setDialogState(() => qrOrdering = val),
                              ),
                              FilterChip(
                                label: const Text("Dual KOT Printing", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: dualPrinting,
                                onSelected: (val) => setDialogState(() => dualPrinting = val),
                              ),
                              FilterChip(
                                label: const Text("Recipe Inventory", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: recipeInventory,
                                onSelected: (val) => setDialogState(() => recipeInventory = val),
                              ),
                              FilterChip(
                                label: const Text("Day-End Summary", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: dayEndReports,
                                onSelected: (val) => setDialogState(() => dayEndReports = val),
                              ),
                              FilterChip(
                                label: const Text("Multi-Branch Hierarchy", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                                selected: multiOutlet,
                                onSelected: (val) => setDialogState(() => multiOutlet = val),
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
                onPressed: isSaving ? null : () => Navigator.pop(ctx),
                child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton.icon(
                onPressed: isSaving
                    ? null
                    : () async {
                        setDialogState(() => isSaving = true);
                        try {
                          final featuresMap = {
                            'billing': qsrBilling,
                            'qsrBilling': qsrBilling,
                            'tableManagement': tableManagement,
                            'kdsEnabled': kdsEnabled,
                            'qrOrdering': qrOrdering,
                            'onlineOrderingEnabled': qrOrdering,
                            'dualPrinting': dualPrinting,
                            'recipeInventory': recipeInventory,
                            'inventoryEnabled': recipeInventory,
                            'dayEndReports': dayEndReports,
                            'reportsEnabled': dayEndReports,
                            'multiOutlet': multiOutlet,
                            'expenseManagement': true,
                          };

                          final now = FieldValue.serverTimestamp();

                          await _firestore.collection('licenses').doc(orgId).set({
                            'planTier': planTier,
                            'status': 'ACTIVE',
                            'maxFranchises': maxFranchises,
                            'maxUsers': maxUsers,
                            'maxDevices': 3,
                            'allowedRoles': allowedRoles,
                            'features': featuresMap,
                            'startDate': Timestamp.now(),
                            'endDate': Timestamp.fromDate(endDate),
                            'expiryWarningDays': expiryWarningDays,
                            'lastRenewedAt': now,
                          }, SetOptions(merge: true));

                          await _firestore.collection('features').doc(orgId).set({
                            'features': featuresMap,
                            'updatedAt': now,
                          }, SetOptions(merge: true));

                          await _firestore.collection('limits').doc(orgId).set({
                            'maxFranchises': maxFranchises,
                            'maxUsers': maxUsers,
                            'maxDevices': 3,
                          }, SetOptions(merge: true));

                          await _firestore.collection('organizations').doc(orgId).set({
                            'status': 'ACTIVE',
                            'lastRenewedAt': now,
                          }, SetOptions(merge: true));

                          try {
                            await _firestore.collection('renewal_requests').doc(orgId).set({
                              'status': 'APPROVED',
                              'approvedAt': now,
                            }, SetOptions(merge: true));
                          } catch (_) {}

                          try {
                            final orgDoc = await _firestore.collection('organizations').doc(orgId).get();
                            final clientEmail = orgDoc.data()?['ownerEmail'] as String? ?? orgDoc.data()?['email'] as String?;
                            if (clientEmail != null && clientEmail.isNotEmpty) {
                              SmtpEmailService.sendLicenseRenewedEmail(
                                recipientEmail: clientEmail,
                                orgName: orgName,
                                planTier: planTier,
                                validUntil: endDate,
                                maxUsers: maxUsers,
                                maxFranchises: maxFranchises,
                              );
                            }
                          } catch (_) {}

                          await _firestore.collection('audit_logs').add({
                            'actionType': 'LICENSE_RENEWED',
                            'organizationId': orgId,
                            'organizationName': orgName,
                            'details': 'Master Admin renewed license for $orgName ($orgId): plan=$planTier, validUntil=${endDate.toIso8601String().split('T')[0]}, warningDays=$expiryWarningDays, allowedRoles=$allowedRoles',
                            'timestamp': now,
                            'priority': 'HIGH',
                          });

                          if (ctx.mounted) {
                            Navigator.pop(ctx);
                            AppToast.showSuccess(
                              context,
                              "License Updated Successfully!",
                              subtitle: "Client POS terminals will reflect the renewed subscription in real-time.",
                            );
                          }
                        } catch (e) {
                          setDialogState(() => isSaving = false);
                          if (ctx.mounted) {
                            AppToast.showError(context, "Failed to update license: $e");
                          }
                        }
                      },
                icon: isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_circle_rounded, size: 16),
                label: Text(isSaving ? "Saving..." : "Save & Activate License", style: const TextStyle(fontWeight: FontWeight.bold)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

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

    // Tenant Razorpay Gateway Configuration
    bool isRazorpayEnabled = false;
    final rzpKeyIdController = TextEditingController();
    final rzpKeySecretController = TextEditingController();
    final rzpWebhookSecretController = TextEditingController();
    bool obscureRzpSecret = true;
    bool isTestingRzp = false;
    String? rzpTestMessage;
    bool rzpTestPassed = false;

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
            final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

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

                    // Razorpay
                    if (data['razorpay'] is Map) {
                      final rzp = Map<String, dynamic>.from(data['razorpay'] as Map);
                      isRazorpayEnabled = rzp['enabled'] == true;
                      rzpKeyIdController.text = (rzp['keyId'] ?? '').toString();
                      rzpKeySecretController.text = (rzp['keySecret'] ?? '').toString();
                      rzpWebhookSecretController.text = (rzp['webhookSecret'] ?? '').toString();
                    }

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
                      style: TextStyle(color: primaryAccent, fontSize: 11, fontWeight: FontWeight.bold),
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
                                      value: businessCategory,
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
                                value: storageMode,
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
                                            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
                                            SizedBox(width: 8),
                                            Expanded(
                                              child: Text(
                                                "Warning: Storage Mode Change",
                                                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                              ),
                                            ),
                                          ],
                                        ),
                                        content: Text(
                                          "Changing the storage architecture from $initialStorageMode to $newMode will disrupt the tenant's data synchronization. The tenant will lose access to data stored under the previous mode.\n\nAre you sure you want to proceed with this migration?",
                                          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () => Navigator.pop(wCtx, false),
                                            child: Text("Cancel / Keep $initialStorageMode", style: TextStyle(color: context.textSecondary)),
                                          ),
                                          ElevatedButton(
                                            style: ElevatedButton.styleFrom(
                                              backgroundColor: Colors.redAccent,
                                              foregroundColor: Colors.white,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                            ),
                                            onPressed: () => Navigator.pop(wCtx, true),
                                            child: const Text("Yes, Change Mode"),
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
                                        ? const Color(0xFF10B981).withValues(alpha: 0.08)
                                        : Colors.amber.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(10),
                                    border: Border.all(
                                      color: existingSheetId.isNotEmpty
                                          ? const Color(0xFF10B981).withValues(alpha: 0.3)
                                          : Colors.amber.withValues(alpha: 0.3),
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
                                                ? const Color(0xFF10B981)
                                                : Colors.amber,
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
                                                    ? const Color(0xFF10B981)
                                                    : Colors.amber.shade900,
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
                                        style: TextStyle(fontSize: 11, color: context.textSecondary),
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
                                                  String ownerEmail = 'santhoshbukka5@gmail.com';
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
                                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
                                        ),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: const Color(0xFF10B981),
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
                                subtitle: Text("Prompt user to change their temporary password upon login", style: TextStyle(color: context.textSecondary, fontSize: 11)),
                                value: mustChangePassword,
                                activeColor: primaryAccent,
                                onChanged: (v) => setDialogState(() => mustChangePassword = v),
                              ),

                              const SizedBox(height: 18),

                              // ── SECTION 2: TENANT RAZORPAY GATEWAY SETUP ─────────────
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF59E0B).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.payment_rounded, color: Color(0xFFF59E0B), size: 16),
                                    SizedBox(width: 6),
                                    Text("2. Tenant Razorpay Gateway Setup", style: TextStyle(color: Color(0xFFF59E0B), fontWeight: FontWeight.bold, fontSize: 13)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "Configure dedicated Razorpay gateway credentials for this restaurant. Table QR and online customer payments will be routed directly to this restaurant's Razorpay account.",
                                style: TextStyle(color: context.textSecondary, fontSize: 11.5, height: 1.3),
                              ),
                              const SizedBox(height: 6),
                              SwitchListTile.adaptive(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                title: Text("Enable Custom Tenant Razorpay Gateway", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                                subtitle: Text("When enabled, QR & counter dynamic UPI settle directly into this tenant's account", style: TextStyle(color: context.textSecondary, fontSize: 11)),
                                value: isRazorpayEnabled,
                                activeColor: const Color(0xFFF59E0B),
                                onChanged: (v) => setDialogState(() => isRazorpayEnabled = v),
                              ),
                              if (isRazorpayEnabled) ...[
                                const SizedBox(height: 8),
                                TextFormField(
                                  controller: rzpKeyIdController,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                                  decoration: InputDecoration(
                                    labelText: "Razorpay Key ID *",
                                    hintText: "rzp_test_... or rzp_live_...",
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                    prefixIcon: const Icon(Icons.key_rounded, size: 18),
                                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFF59E0B), width: 2)),
                                  ),
                                  validator: isRazorpayEnabled ? (v) => v == null || v.trim().isEmpty ? "Key ID required" : null : null,
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: rzpKeySecretController,
                                  obscureText: obscureRzpSecret,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                                  decoration: InputDecoration(
                                    labelText: "Razorpay Key Secret *",
                                    hintText: "Enter secret key",
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                    prefixIcon: const Icon(Icons.password_rounded, size: 18),
                                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFF59E0B), width: 2)),
                                    suffixIcon: IconButton(
                                      icon: Icon(obscureRzpSecret ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18, color: context.textSecondary),
                                      onPressed: () => setDialogState(() => obscureRzpSecret = !obscureRzpSecret),
                                    ),
                                  ),
                                  validator: isRazorpayEnabled ? (v) => v == null || v.trim().isEmpty ? "Key secret required" : null : null,
                                ),
                                const SizedBox(height: 10),
                                TextFormField(
                                  controller: rzpWebhookSecretController,
                                  obscureText: true,
                                  style: TextStyle(color: context.textPrimary, fontSize: 13, fontFamily: 'monospace'),
                                  decoration: InputDecoration(
                                    labelText: "Webhook Secret (Optional)",
                                    hintText: "Webhook Secret from Razorpay Dashboard",
                                    labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                    prefixIcon: const Icon(Icons.webhook_rounded, size: 18),
                                    enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFFF59E0B), width: 2)),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    ElevatedButton.icon(
                                      onPressed: isTestingRzp
                                          ? null
                                          : () async {
                                              final keyId = rzpKeyIdController.text.trim();
                                              final keySecret = rzpKeySecretController.text.trim();
                                              if (keyId.isEmpty) {
                                                AppToast.showError(context, "Enter Key ID first");
                                                return;
                                              }
                                              setDialogState(() {
                                                isTestingRzp = true;
                                                rzpTestMessage = null;
                                              });
                                              try {
                                                final res = await AppsScriptBackendService.testOutletRazorpay(
                                                  outletId: orgId,
                                                  keyId: keyId,
                                                  keySecret: keySecret,
                                                );
                                                final ok = res['ok'] == true || res['success'] == true;
                                                setDialogState(() {
                                                  isTestingRzp = false;
                                                  rzpTestPassed = ok;
                                                  rzpTestMessage = (res['message'] ?? res['error'] ?? (ok ? "Accepted" : "Failed")).toString();
                                                });
                                                if (ok) {
                                                  AppToast.showSuccess(context, "Razorpay verified for this store!");
                                                } else {
                                                  AppToast.showError(context, rzpTestMessage ?? "Verification failed");
                                                }
                                              } catch (e) {
                                                setDialogState(() {
                                                  isTestingRzp = false;
                                                  rzpTestPassed = false;
                                                  rzpTestMessage = "Error: $e";
                                                });
                                                AppToast.showError(context, "Test failed: $e");
                                              }
                                            },
                                      icon: isTestingRzp
                                          ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                          : const Icon(Icons.verified_user_rounded, size: 16),
                                      label: Text(isTestingRzp ? "Testing..." : "Test Connection", style: const TextStyle(fontSize: 12)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFFF59E0B),
                                        foregroundColor: Colors.white,
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                                      ),
                                    ),
                                    if (rzpTestMessage != null) ...[
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          rzpTestMessage!,
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: rzpTestPassed ? Colors.green : Colors.redAccent,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ],

                              const SizedBox(height: 18),

                              // ── SECTION 3: EMAIL & SMTP CONFIGURATION ─────────────
                              Container(
                                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 10),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF0284C7).withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Row(
                                  children: [
                                    Icon(Icons.mark_email_read_rounded, color: Color(0xFF0284C7), size: 16),
                                    SizedBox(width: 6),
                                    Text("3. Email & SMTP Configuration", style: TextStyle(color: Color(0xFF0284C7), fontWeight: FontWeight.bold, fontSize: 13)),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                "Configure outgoing email server for sending digital POS tax invoices to customers upon bill settlement and administrative alerts.",
                                style: TextStyle(color: context.textSecondary, fontSize: 11.5, height: 1.3),
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
                                  style: TextStyle(color: context.textSecondary, fontSize: 11),
                                ),
                                value: inheritPlatformSmtp,
                                activeColor: const Color(0xFF0284C7),
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
                                          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF0284C7), width: 2)),
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
                                          focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF0284C7), width: 2)),
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
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF0284C7), width: 2)),
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
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF0284C7), width: 2)),
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
                                    focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF0284C7), width: 2)),
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SwitchListTile.adaptive(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: Text("Use SSL / TLS Direct Connection", style: TextStyle(color: context.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
                                  subtitle: Text("Enable if Port 465 (Port 587 uses STARTTLS by default)", style: TextStyle(color: context.textSecondary, fontSize: 11)),
                                  value: smtpIsSsl,
                                  activeColor: const Color(0xFF0284C7),
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
                                      label: const Text("Send Test", style: TextStyle(fontSize: 11)),
                                      style: ElevatedButton.styleFrom(
                                        backgroundColor: const Color(0xFF0284C7),
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
                              'storageMode': storageMode,
                              if (storageMode == 'CLIENTS_OWN_SHEETS' && existingSheetId.isNotEmpty) ...{
                                'googleSheetId': existingSheetId,
                                'googleSheetUrl': existingSheetUrl,
                                'isGoogleConnected': true,
                              },
                              'razorpay': {
                                'enabled': isRazorpayEnabled,
                                'keyId': rzpKeyIdController.text.trim(),
                                'keySecret': rzpKeySecretController.text.trim(),
                                'webhookSecret': rzpWebhookSecretController.text.trim(),
                                'updatedAt': FieldValue.serverTimestamp(),
                              },
                              'smtpConfig': smtpMap,
                              'updatedAt': FieldValue.serverTimestamp(),
                            }, SetOptions(merge: true));

                            // Sync Razorpay to Apps Script backend & public_stores
                            if (isRazorpayEnabled && rzpKeyIdController.text.trim().isNotEmpty) {
                              try {
                                await AppsScriptBackendService.setOutletRazorpay(
                                  outletId: orgId,
                                  keyId: rzpKeyIdController.text.trim(),
                                  keySecret: rzpKeySecretController.text.trim(),
                                  webhookSecret: rzpWebhookSecretController.text.trim(),
                                );
                              } catch (e) {
                                debugPrint("AppsScript razorpay sync error: $e");
                              }

                              FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
                                'isRazorpayEnabled': true,
                                'razorpayKeyId': rzpKeyIdController.text.trim(),
                                'updatedAt': FieldValue.serverTimestamp(),
                              }, SetOptions(merge: true)).catchError((e) => debugPrint("public_stores razorpay sync error: $e"));
                            } else {
                              FirebaseFirestore.instance.collection('public_stores').doc(orgId).set({
                                'isRazorpayEnabled': false,
                                'razorpayKeyId': '',
                                'updatedAt': FieldValue.serverTimestamp(),
                              }, SetOptions(merge: true)).catchError((e) => debugPrint("public_stores razorpay clear error: $e"));
                            }

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
                                  details: 'Tenant $orgName ($orgId) settings, Razorpay and SMTP updated.',
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
    final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

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
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.amber.withValues(alpha: 0.5)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.amber.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(Icons.notifications_active_rounded, color: Colors.amber, size: 18),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                "Action Required: ${requests.length} License Renewal Request${requests.length > 1 ? 's' : ''}",
                                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Colors.amber),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                "Client stores have completed their trial or plan and requested immediate license extension.",
                                style: TextStyle(color: context.textSecondary, fontSize: 11),
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
                                  ),
                                  Text(
                                    "Tenant: $rOrgId  •  Previous: $rTier",
                                    style: TextStyle(color: context.textSecondary, fontSize: 11),
                                  ),
                                ],
                              ),
                            ),
                            ElevatedButton.icon(
                              onPressed: () => _showRenewLicenseDialog(rOrgId, rOrgName),
                              icon: const Icon(Icons.card_membership_rounded, size: 14),
                              label: const Text("Renew License", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
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
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        name,
                                        style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                      ),
                                      if (ownerName.isNotEmpty)
                                        Text(
                                          "Owner: $ownerName ${phone.isNotEmpty ? '($phone)' : ''}",
                                          style: TextStyle(color: context.textSecondary, fontSize: 13),
                                        ),
                                    ],
                                  ),
                                ),
                                StreamBuilder<DocumentSnapshot>(
                                  stream: _firestore.collection('licenses').doc(docId).snapshots(),
                                  builder: (context, licSnap) {
                                    if (!licSnap.hasData || !licSnap.data!.exists) {
                                      return Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: status == 'ACTIVE' ? Colors.green.withValues(alpha: 0.15) : Colors.red.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          status,
                                          style: TextStyle(
                                            color: status == 'ACTIVE' ? Colors.green : Colors.redAccent,
                                            fontSize: 10,
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
                                      badgeColor = Colors.redAccent;
                                      badgeLabel = "EXPIRED";
                                    } else if (isNear) {
                                      badgeColor = Colors.amber;
                                      badgeLabel = "EXPIRES IN $daysLeft DAYS";
                                    } else if (tier == 'TRIAL') {
                                      badgeColor = Colors.orangeAccent;
                                      badgeLabel = "TRIAL ($daysLeft days)";
                                    } else {
                                      badgeColor = Colors.green;
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
                                            style: TextStyle(color: badgeColor, fontSize: 10, fontWeight: FontWeight.bold),
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
                                          margin: const EdgeInsets.only(left: 6),
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                          decoration: BoxDecoration(
                                            color: Colors.redAccent.withValues(alpha: 0.15),
                                            borderRadius: BorderRadius.circular(6),
                                            border: Border.all(color: Colors.redAccent),
                                          ),
                                          child: const Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.bolt_rounded, size: 12, color: Colors.redAccent),
                                              SizedBox(width: 4),
                                              Text(
                                                "RENEWAL REQUESTED",
                                                style: TextStyle(color: Colors.redAccent, fontSize: 9.5, fontWeight: FontWeight.bold),
                                              ),
                                            ],
                                          ),
                                        );
                                      }
                                    }
                                    return const SizedBox.shrink();
                                  },
                                ),
                                const SizedBox(width: 6),
                                IconButton(
                                  icon: const Icon(Icons.card_membership_rounded, color: Colors.green),
                                  tooltip: "Edit License & Plan Entitlements",
                                  onPressed: () => _showRenewLicenseDialog(docId, name),
                                ),
                                IconButton(
                                  icon: Icon(Icons.edit_outlined, color: primaryAccent),
                                  tooltip: "Edit Tenant Profile, Razorpay & SMTP",
                                  onPressed: () => _showEditOrganizationDialog(docId, name),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Wrap(
                              spacing: 6,
                              runSpacing: 4,
                              children: [
                                _infoBadge(Icons.fingerprint, "ID: $docId", isAccent: true),
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
        color: isAccent ? const Color(0xFF2563EB).withValues(alpha: 0.12) : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: isAccent ? const Color(0xFF2563EB) : Colors.grey),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 11.5, fontWeight: isAccent ? FontWeight.bold : FontWeight.normal, color: context.textPrimary)),
          if (isVerified) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified_rounded, size: 12, color: Color(0xFF10B981)),
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
    final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

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
                            Text(timestamp, style: TextStyle(color: context.textSecondary, fontSize: 10)),
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
                                    color: context.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: Text("By: $userName", style: TextStyle(color: primaryAccent, fontSize: 10, fontWeight: FontWeight.w600)),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: context.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: context.borderColor),
                                  ),
                                  child: Text(
                                    "Org: $orgName",
                                    style: TextStyle(
                                      color: context.isDark ? const Color(0xFF34D399) : const Color(0xFF059669),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                if (franchiseName != null && franchiseName.isNotEmpty)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: context.isDark ? const Color(0xFF1E293B) : const Color(0xFFF1F5F9),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(color: context.borderColor),
                                    ),
                                    child: Text(
                                      "Outlet: $franchiseName",
                                      style: TextStyle(
                                        color: context.isDark ? const Color(0xFF38BDF8) : const Color(0xFF0284C7),
                                        fontSize: 10,
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
    final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

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
              activeColor: primaryAccent,
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
                              SnackBar(content: Text("Error saving: $e"), backgroundColor: Colors.redAccent),
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

// --- TAB: REGISTRATION REQUESTS TAB ---
class RegistrationRequestsTab extends ConsumerStatefulWidget {
  const RegistrationRequestsTab({super.key});

  @override
  ConsumerState<RegistrationRequestsTab> createState() => _RegistrationRequestsTabState();
}

class _RegistrationRequestsTabState extends ConsumerState<RegistrationRequestsTab> {
  final _firestore = FirebaseFirestore.instance;
  String _selectedFilter = 'PENDING'; // 'ALL', 'PENDING', 'APPROVED', 'REJECTED'

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

    int validityDays = initialTrialDays > 0 ? initialTrialDays : selectedPlan.validityDays;
    int maxOutlets = initialMaxOutlets > 1 ? initialMaxOutlets : selectedPlan.maxOutlets;
    int maxUsers = initialMaxUsers;
    int maxDevices = selectedPlan.maxDevices;
    int tableCount = initialTableCount;
    String operatingMode = initialOperatingMode;

    // Feature Toggles: initialize from selected plan, merged with any specific initial requested features
    final Map<String, bool> featureToggles = Map<String, bool>.from(selectedPlan.features);
    if (initialFeatures != null) {
      featureToggles.addAll(initialFeatures);
    }

    bool isCreating = false;
    bool obscurePassword = true;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            const primaryAccent = Color(0xFF10B981);
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
                      style: TextStyle(color: primaryAccent, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 650,
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

                        // SECTION 2: DYNAMIC PLAN ASSIGNMENT
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.workspace_premium_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("2. Subscription Plan & Quotas", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        DropdownButtonFormField<SubscriptionPlan>(
                          value: availablePlans.any((p) => p.id == selectedPlan.id)
                              ? availablePlans.firstWhere((p) => p.id == selectedPlan.id)
                              : selectedPlan,
                          dropdownColor: context.surfaceColor,
                          style: TextStyle(color: context.textPrimary, fontSize: 13),
                          decoration: InputDecoration(
                            labelText: "Assign Subscription Plan",
                            labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                            prefixIcon: const Icon(Icons.stars_rounded, size: 18),
                            enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                            focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                          ),
                          items: availablePlans.map((plan) {
                            return DropdownMenuItem<SubscriptionPlan>(
                              value: plan,
                              child: Text(
                                "${plan.name} — ₹${plan.price.toStringAsFixed(0)} / ${plan.validityDays}d (${plan.billingCycle})",
                                style: TextStyle(
                                  fontWeight: plan.isDefaultTrial ? FontWeight.bold : FontWeight.normal,
                                  color: plan.isDefaultTrial ? primaryAccent : null,
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (newPlan) {
                            if (newPlan != null) {
                              setDialogState(() {
                                selectedPlan = newPlan;
                                validityDays = newPlan.validityDays;
                                maxOutlets = newPlan.maxOutlets;
                                maxDevices = newPlan.maxDevices;
                                maxUsers = newPlan.maxUsers;
                                tableCount = newPlan.tableCount;
                                operatingMode = newPlan.operatingMode;
                                featureToggles.clear();
                                featureToggles.addAll(newPlan.features);
                              });
                            }
                          },
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                initialValue: validityDays.toString(),
                                key: ValueKey('req_val_$validityDays'),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Validity (Days)",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.calendar_today_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => validityDays = int.tryParse(v) ?? validityDays,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: maxOutlets.toString(),
                                key: ValueKey('req_out_$maxOutlets'),
                                style: TextStyle(color: context.textPrimary),
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  labelText: "Max Branches",
                                  labelStyle: TextStyle(color: context.textSecondary, fontSize: 13),
                                  prefixIcon: const Icon(Icons.store_rounded, size: 16),
                                  enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: context.borderColor)),
                                  focusedBorder: const UnderlineInputBorder(borderSide: BorderSide(color: primaryAccent, width: 2)),
                                ),
                                onChanged: (v) => maxOutlets = int.tryParse(v) ?? maxOutlets,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: TextFormField(
                                initialValue: tableCount.toString(),
                                key: ValueKey('req_tab_$tableCount'),
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
                        const SizedBox(height: 20),

                        // SECTION 3: FEATURES FROM CATALOG
                        Container(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.checklist_rtl_rounded, color: primaryAccent, size: 16),
                              const SizedBox(width: 6),
                              Text("3. Feature Entitlements", style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 13)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 10),
                        ...RestaurantFeatureCatalog.byCategory.entries.map((catEntry) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _buildGroupWidget(
                              context: context,
                              title: catEntry.key,
                              subtitle: "Configured capabilities for ${catEntry.key}",
                              icon: Icons.tune_rounded,
                              accentColor: primaryAccent,
                              children: catEntry.value.map((feat) {
                                final isSelected = featureToggles[feat.key] ?? false;
                                return _chipWidget(
                                  label: feat.label,
                                  selected: isSelected,
                                  color: primaryAccent,
                                  onSelected: (v) {
                                    setDialogState(() {
                                      featureToggles[feat.key] = v;
                                    });
                                  },
                                );
                              }).toList(),
                            ),
                          );
                        }),
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

                            final finalPlan = selectedPlan.copyWith(
                              validityDays: validityDays,
                              maxOutlets: maxOutlets,
                              maxDevices: maxDevices,
                              maxUsers: maxUsers,
                              tableCount: tableCount,
                              operatingMode: operatingMode,
                              features: featureToggles,
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
                            );

                            if (result['success'] != true) {
                              throw Exception(result['message'] ?? "Approval onboarding failed");
                            }

                            if (context.mounted) {
                              Navigator.pop(context);
                              AppToast.showSuccess(
                                context,
                                "Request Approved & Client Onboarded",
                                subtitle: "$orgName ($orgId) onboarded with ${selectedPlan.name}.",
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


  Widget _buildGroupWidget({
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
          Text(subtitle, style: TextStyle(color: context.textSecondary, fontSize: 11)),
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

  Widget _chipWidget({
    required String label,
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
                style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold),
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

  @override
  Widget build(BuildContext context) {
    final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header & Filter Bar
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                "Client Sign-Up Requests",
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _filterChip("Pending", 'PENDING', Colors.orangeAccent),
                    const SizedBox(width: 6),
                    _filterChip("Approved", 'APPROVED', const Color(0xFF10B981)),
                    const SizedBox(width: 6),
                    _filterChip("Rejected", 'REJECTED', Colors.redAccent),
                    const SizedBox(width: 6),
                    _filterChip("All", 'ALL', primaryAccent),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Requests Stream
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: _firestore
                  .collection('registration_requests')
                  .orderBy('createdAt', descending: true)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return Center(child: CircularProgressIndicator(color: primaryAccent));
                }
                if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inbox_rounded, size: 48, color: context.textSecondary.withValues(alpha: 0.5)),
                        const SizedBox(height: 10),
                        Text("No registration requests received yet.", style: TextStyle(color: context.textSecondary)),
                      ],
                    ),
                  );
                }

                var docs = snapshot.data!.docs;
                if (_selectedFilter != 'ALL') {
                  docs = docs.where((d) => (d.data() as Map<String, dynamic>)['status'] == _selectedFilter).toList();
                }

                if (docs.isEmpty) {
                  return Center(
                    child: Text("No requests match the selected '$_selectedFilter' filter.", style: TextStyle(color: context.textSecondary)),
                  );
                }

                return ListView.builder(
                  itemCount: docs.length,
                  itemBuilder: (context, index) {
                    final doc = docs[index];
                    final data = doc.data() as Map<String, dynamic>;
                    final requestId = doc.id;
                    final clientName = data['clientName'] ?? 'Unknown Client';
                    final shopName = data['shopName'] ?? '';
                    final category = data['businessCategory'] ?? 'General';
                    final referral = data['referralSource'] ?? 'Not specified';
                    final email = data['email'] ?? '';
                    final mobile = data['mobile'] ?? '';
                    final status = data['status'] ?? 'PENDING';
                    final orgId = data['organizationId'] as String?;
                    final createdAt = (data['createdAt'] as Timestamp?)?.toDate();

                    return Card(
                      color: context.surfaceColor,
                      elevation: 0,
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: context.borderColor),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        clientName,
                                        style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                      ),
                                      if (shopName.isNotEmpty)
                                        Text(
                                          shopName,
                                          style: TextStyle(color: primaryAccent, fontWeight: FontWeight.w600, fontSize: 13),
                                        ),
                                    ],
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(
                                    color: _getStatusColor(status).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Text(
                                    status,
                                    style: TextStyle(
                                      color: _getStatusColor(status),
                                      fontWeight: FontWeight.bold,
                                      fontSize: 11,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),

                            // Detail chips & contact info
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _infoBadge(Icons.category_outlined, category),
                                _infoBadge(Icons.mail_outline, email, isVerified: data['emailVerified'] == true),
                                _infoBadge(Icons.phone_android_outlined, mobile),
                                _infoBadge(Icons.timer_outlined, "${data['requestedTrialDays'] ?? 14}-Day Free Trial", isAccent: true),
                                _infoBadge(Icons.group_outlined, "${data['requestedMaxUsers'] ?? 5} Staff Users"),
                                _infoBadge(Icons.store_mall_directory_outlined, "${data['requestedStoreCount'] ?? 1} Outlets"),
                                _infoBadge(Icons.table_restaurant_outlined, "${data['tableCount'] ?? 10} Tables"),
                                if (data['preferredOperatingMode'] != null)
                                  _infoBadge(Icons.sync_alt_rounded, data['preferredOperatingMode'] == 'payFirstQSR' ? 'Pay First (QSR)' : 'Dine First'),
                                _infoBadge(Icons.share_outlined, "Via: $referral"),
                                if (createdAt != null)
                                  _infoBadge(Icons.calendar_today_outlined, "${createdAt.day}/${createdAt.month}/${createdAt.year}"),
                                if (orgId != null)
                                  _infoBadge(Icons.verified_user_rounded, "Org: $orgId", isAccent: true),
                              ],
                            ),

                            // Actions Row for PENDING
                            if (status == 'PENDING') ...[
                              const SizedBox(height: 14),
                              Divider(height: 1, color: context.borderColor),
                              const SizedBox(height: 12),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.end,
                                children: [
                                  OutlinedButton.icon(
                                    onPressed: () async {
                                      await _firestore.collection('registration_requests').doc(requestId).update({
                                        'status': 'REJECTED',
                                        'rejectedAt': FieldValue.serverTimestamp(),
                                        'updatedAt': FieldValue.serverTimestamp(),
                                      });
                                      // Dispatch rejection email via SMTP
                                      SmtpEmailService.sendRegistrationRejectedEmail(
                                        recipientEmail: email,
                                        clientName: clientName,
                                        shopName: shopName,
                                        reason: "Information verification could not be completed.",
                                      ).catchError((e) {
                                        debugPrint("Background rejection email error: $e");
                                        return <String, dynamic>{};
                                      });
                                      if (context.mounted) {
                                        AppToast.showSuccess(context, "Request marked as Rejected and notification sent.");
                                      }
                                    },
                                    icon: const Icon(Icons.close_rounded, size: 16, color: Colors.redAccent),
                                    label: const Text("Reject", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.redAccent),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  ElevatedButton.icon(
                                    onPressed: () {
                                      _showOnboardDialogFromRequest(
                                        requestId: requestId,
                                        clientName: clientName,
                                        shopName: shopName,
                                        category: category,
                                        email: email,
                                        mobile: mobile,
                                        initialAadhaar: data['aadhaar']?.toString() ?? '',
                                        initialPan: data['pan']?.toString() ?? '',
                                        initialGst: (data['gstNo'] ?? data['gst'])?.toString() ?? '',
                                        initialAddress: data['address']?.toString() ?? '',
                                        initialTrialDays: (data['requestedTrialDays'] ?? 14) as int,
                                        initialMaxUsers: (data['requestedMaxUsers'] ?? 5) as int,
                                        initialMaxOutlets: (data['requestedStoreCount'] ?? 1) as int,
                                        initialTableCount: (data['tableCount'] ?? 10) as int,
                                        initialOperatingMode: data['preferredOperatingMode']?.toString() ?? 'dineFirstPostpaid',
                                        initialRoles: (data['requestedRoles'] is List)
                                            ? List<String>.from(data['requestedRoles'])
                                            : null,
                                        initialFeatures: (data['requestedFeatures'] is Map)
                                            ? Map<String, bool>.from((data['requestedFeatures'] as Map).map((k, v) => MapEntry(k.toString(), v == true)))
                                            : null,
                                      );
                                    },
                                    icon: const Icon(Icons.rocket_launch_rounded, size: 16),
                                    label: const Text("Approve & Onboard", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF10B981),
                                      foregroundColor: Colors.white,
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                    ),
                                  ),
                                ],
                              ),
                            ],
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

  Widget _filterChip(String label, String value, Color color) {
    final isSelected = _selectedFilter == value;
    return ChoiceChip(
      label: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: isSelected ? FontWeight.bold : FontWeight.normal)),
      selected: isSelected,
      selectedColor: color.withValues(alpha: 0.2),
      onSelected: (_) => setState(() => _selectedFilter = value),
    );
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'APPROVED':
        return const Color(0xFF10B981);
      case 'REJECTED':
        return Colors.redAccent;
      default:
        return Colors.orangeAccent;
    }
  }

  Widget _infoBadge(IconData icon, String text, {bool isVerified = false, bool isAccent = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isAccent ? const Color(0xFF2563EB).withValues(alpha: 0.1) : Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: isAccent ? const Color(0xFF2563EB) : Colors.grey),
          const SizedBox(width: 5),
          Text(text, style: TextStyle(fontSize: 11.5, fontWeight: isAccent ? FontWeight.bold : FontWeight.normal)),
          if (isVerified) ...[
            const SizedBox(width: 4),
            const Icon(Icons.verified_rounded, size: 12, color: Color(0xFF10B981)),
          ],
        ],
      ),
    );
  }
}





// =============================================================================
//  TAB 5: PLANS & FEATURES MANAGEMENT TAB
// =============================================================================
class PlansAndFeaturesTab extends ConsumerStatefulWidget {
  const PlansAndFeaturesTab({super.key});

  @override
  ConsumerState<PlansAndFeaturesTab> createState() => _PlansAndFeaturesTabState();
}

class _PlansAndFeaturesTabState extends ConsumerState<PlansAndFeaturesTab> {
  void _showPlanEditorDialog(BuildContext context, [SubscriptionPlan? existing]) {
    final formKey = GlobalKey<FormState>();
    final nameCtrl = TextEditingController(text: existing?.name ?? '');
    final descCtrl = TextEditingController(text: existing?.description ?? '');
    final daysCtrl = TextEditingController(text: (existing?.validityDays ?? 365).toString());
    final priceCtrl = TextEditingController(text: (existing?.price ?? 4999.0).toStringAsFixed(0));
    final outletsCtrl = TextEditingController(text: (existing?.maxOutlets ?? 1).toString());
    final usersCtrl = TextEditingController(text: (existing?.maxUsers ?? 5).toString());
    final devicesCtrl = TextEditingController(text: (existing?.maxDevices ?? 3).toString());
    final tablesCtrl = TextEditingController(text: (existing?.tableCount ?? 15).toString());

    String billingCycle = existing?.billingCycle ?? 'YEARLY';
    String operatingMode = existing?.operatingMode ?? 'dineFirstPostpaid';
    bool isDefaultTrial = existing?.isDefaultTrial ?? false;

    // Feature toggles initialize from catalog
    final Map<String, bool> featureToggles = {};
    for (final feat in RestaurantFeatureCatalog.allFeatures) {
      featureToggles[feat.key] = existing?.features[feat.key] ?? false;
    }

    bool isSaving = false;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) {
          final primaryAccent = const Color(0xFFF59E0B);
          return AlertDialog(
            backgroundColor: context.surfaceColor,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
              side: BorderSide(color: context.borderColor),
            ),
            title: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(color: primaryAccent.withValues(alpha: 0.15), shape: BoxShape.circle),
                  child: Icon(existing == null ? Icons.add_box_rounded : Icons.edit_note_rounded, color: primaryAccent, size: 22),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    existing == null ? "Create Subscription Plan" : "Edit Plan: ${existing.name}",
                    style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                ),
              ],
            ),
            content: SizedBox(
              width: 650,
              height: 540,
              child: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Basic Info
                      Text("Plan Details", style: TextStyle(color: primaryAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            flex: 3,
                            child: TextFormField(
                              controller: nameCtrl,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Plan Name (e.g. Pro Dining)", labelText: "Plan Name *"),
                              validator: (v) => v == null || v.trim().isEmpty ? "Required" : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            flex: 2,
                            child: DropdownButtonFormField<String>(
                              value: billingCycle,
                              isExpanded: true,
                              dropdownColor: context.surfaceColor,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, labelText: "Cycle *"),
                              items: ['TRIAL', 'MONTHLY', 'YEARLY', 'LIFETIME', 'CUSTOM'].map((c) => DropdownMenuItem(
                                value: c,
                                child: Text(c, style: TextStyle(color: context.textPrimary, fontSize: 12)),
                              )).toList(),
                              onChanged: (v) => setDialogState(() => billingCycle = v!),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: descCtrl,
                        maxLines: 2,
                        style: TextStyle(color: context.textPrimary, fontSize: 13),
                        decoration: ClassicTheme.inputDecorationFor(context, hintText: "Brief summary of plan entitlements", labelText: "Description"),
                      ),
                      const SizedBox(height: 14),

                      // Pricing & Duration
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: priceCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Price in INR", labelText: "Price (₹) *"),
                              validator: (v) => v == null || v.trim().isEmpty ? "Required" : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: TextFormField(
                              controller: daysCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "e.g. 14 or 365", labelText: "Duration (Days) *"),
                              validator: (v) => v == null || v.trim().isEmpty ? "Required" : null,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              value: operatingMode,
                              isExpanded: true,
                              dropdownColor: context.surfaceColor,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, labelText: "Service Mode"),
                              items: [
                                const DropdownMenuItem(value: 'dineFirstPostpaid', child: Text('Dine First, Pay Later', style: TextStyle(fontSize: 11))),
                                const DropdownMenuItem(value: 'payFirstQSR', child: Text('Pay First (QSR)', style: TextStyle(fontSize: 11))),
                                const DropdownMenuItem(value: 'hybrid', child: Text('Hybrid Mode', style: TextStyle(fontSize: 11))),
                              ],
                              onChanged: (v) => setDialogState(() => operatingMode = v!),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Quotas & Limits
                      Text("Quotas & Limits", style: TextStyle(color: primaryAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: outletsCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Max Outlets", labelText: "Outlets"),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: usersCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Max Staff Users", labelText: "Staff Users"),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: devicesCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Max Terminals", labelText: "Terminals"),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: TextFormField(
                              controller: tablesCtrl,
                              keyboardType: TextInputType.number,
                              style: TextStyle(color: context.textPrimary, fontSize: 13),
                              decoration: ClassicTheme.inputDecorationFor(context, hintText: "Tables", labelText: "Tables"),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),

                      // Default Trial Flag
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: isDefaultTrial ? const Color(0xFF10B981).withValues(alpha: 0.1) : context.surfaceColor,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: isDefaultTrial ? const Color(0xFF10B981).withValues(alpha: 0.3) : context.borderColor),
                        ),
                        child: SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text("Use as Default Free Trial for New Signups", style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          subtitle: const Text("New restaurants selecting 'Start Free Trial' will immediately receive this plan.", style: TextStyle(fontSize: 11)),
                          value: isDefaultTrial,
                          activeColor: const Color(0xFF10B981),
                          onChanged: (v) => setDialogState(() => isDefaultTrial = v),
                        ),
                      ),
                      const SizedBox(height: 18),

                      // Grouped Feature Toggles
                      Text("Included Features (Feature Matrix)", style: TextStyle(color: primaryAccent, fontSize: 13, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 8),
                      ...RestaurantFeatureCatalog.groupedFeatures.entries.map((entry) {
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: context.surfaceColor,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: context.borderColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(entry.key, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: context.textPrimary)),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: entry.value.map((feat) {
                                  final isChecked = featureToggles[feat.key] ?? false;
                                  return FilterChip(
                                    label: Text(feat.label),
                                    selected: isChecked,
                                    selectedColor: primaryAccent.withValues(alpha: 0.2),
                                    backgroundColor: context.canvasColor,
                                    labelStyle: TextStyle(
                                      color: isChecked ? primaryAccent : context.textSecondary,
                                      fontWeight: isChecked ? FontWeight.bold : FontWeight.normal,
                                      fontSize: 11.5,
                                    ),
                                    side: BorderSide(color: isChecked ? primaryAccent : context.borderColor),
                                    onSelected: (val) {
                                      setDialogState(() => featureToggles[feat.key] = val);
                                    },
                                  );
                                }).toList(),
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
              ),
              ElevatedButton(
                onPressed: isSaving ? null : () async {
                  if (!formKey.currentState!.validate()) return;
                  setDialogState(() => isSaving = true);

                  try {
                    final planId = existing?.id ?? 'plan_${DateTime.now().millisecondsSinceEpoch}';
                    final newPlan = SubscriptionPlan(
                      id: planId,
                      name: nameCtrl.text.trim(),
                      description: descCtrl.text.trim(),
                      isDefaultTrial: isDefaultTrial,
                      validityDays: int.tryParse(daysCtrl.text.trim()) ?? 365,
                      price: double.tryParse(priceCtrl.text.trim()) ?? 0.0,
                      billingCycle: billingCycle,
                      maxOutlets: int.tryParse(outletsCtrl.text.trim()) ?? 1,
                      maxUsers: int.tryParse(usersCtrl.text.trim()) ?? 5,
                      maxDevices: int.tryParse(devicesCtrl.text.trim()) ?? 3,
                      tableCount: int.tryParse(tablesCtrl.text.trim()) ?? 15,
                      operatingMode: operatingMode,
                      features: featureToggles,
                    );

                    await SubscriptionPlanService.savePlan(newPlan);
                    if (isDefaultTrial) {
                      await SubscriptionPlanService.setDefaultTrialPlan(planId);
                    }

                    if (ctx.mounted) {
                      Navigator.pop(ctx);
                      AppToast.showSuccess(context, "Subscription Plan Saved");
                    }
                  } catch (e) {
                    setDialogState(() => isSaving = false);
                    if (ctx.mounted) AppToast.showError(context, e.toString());
                  }
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: primaryAccent,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                ),
                child: isSaving
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                    : const Text("Save Plan", style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryAccent = const Color(0xFFF59E0B);

    return StreamBuilder<List<SubscriptionPlan>>(
      stream: SubscriptionPlanService.getAllPlansStream(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final plans = snapshot.data ?? [SubscriptionPlanService.fallbackTrialPlan];

        return Scaffold(
          backgroundColor: context.canvasColor,
          body: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Top Header Bar
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          "Subscription Plans & Feature Bundles",
                          style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 18),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          "Configure dynamic plans, feature matrices, quotas, and designate default trial access",
                          style: TextStyle(color: context.textSecondary, fontSize: 12),
                        ),
                      ],
                    ),
                    ElevatedButton.icon(
                      onPressed: () => _showPlanEditorDialog(context),
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text("Create New Plan", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: primaryAccent,
                        foregroundColor: Colors.black,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Grid of Plans
                Expanded(
                  child: ListView.separated(
                    itemCount: plans.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 14),
                    itemBuilder: (context, idx) {
                      final plan = plans[idx];
                      final isTrial = plan.isDefaultTrial;

                      return Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: isTrial ? primaryAccent.withValues(alpha: 0.5) : context.borderColor,
                            width: isTrial ? 1.5 : 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.04),
                              blurRadius: 10,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      isTrial ? Icons.star_rounded : Icons.card_membership_rounded,
                                      color: isTrial ? primaryAccent : const Color(0xFF60A5FA),
                                      size: 24,
                                    ),
                                    const SizedBox(width: 10),
                                    Text(
                                      plan.name,
                                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    const SizedBox(width: 10),
                                    if (isTrial)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: primaryAccent.withValues(alpha: 0.15),
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          "⭐ DEFAULT FREE TRIAL",
                                          style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold, fontSize: 10),
                                        ),
                                      ),
                                  ],
                                ),
                                Row(
                                  children: [
                                    Text(
                                      plan.price <= 0 ? "FREE" : "₹${plan.price.toStringAsFixed(0)}",
                                      style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                    ),
                                    Text(
                                      " / ${plan.validityDays} Days",
                                      style: TextStyle(color: context.textSecondary, fontSize: 12),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            if (plan.description.isNotEmpty) ...[
                              const SizedBox(height: 6),
                              Text(plan.description, style: TextStyle(color: context.textSecondary, fontSize: 12)),
                            ],
                            const SizedBox(height: 12),

                            // Quota Chips
                            Wrap(
                              spacing: 8,
                              runSpacing: 6,
                              children: [
                                _quotaPill(Icons.storefront_rounded, "${plan.maxOutlets} Outlet${plan.maxOutlets > 1 ? 's' : ''}", context),
                                _quotaPill(Icons.people_alt_rounded, "${plan.maxUsers} Staff", context),
                                _quotaPill(Icons.devices_rounded, "${plan.maxDevices} Terminals", context),
                                _quotaPill(Icons.table_restaurant_rounded, "${plan.tableCount} Tables", context),
                                _quotaPill(Icons.schedule_rounded, "${plan.validityDays} Days Validity", context),
                              ],
                            ),
                            const SizedBox(height: 12),

                            // Enabled Feature Chips
                            Text("Included Features:", style: TextStyle(color: context.textSecondary, fontSize: 11, fontWeight: FontWeight.w600)),
                            const SizedBox(height: 6),
                            Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: plan.features.entries.where((e) => e.value == true).map((e) {
                                final featDef = RestaurantFeatureCatalog.allFeatures.firstWhere(
                                  (f) => f.key == e.key,
                                  orElse: () => RestaurantFeatureItem(key: e.key, label: e.key, description: '', category: '', iconCode: ''),
                                );
                                return Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: primaryAccent.withValues(alpha: 0.08),
                                    borderRadius: BorderRadius.circular(6),
                                    border: Border.all(color: primaryAccent.withValues(alpha: 0.2)),
                                  ),
                                  child: Text(
                                    featDef.label,
                                    style: TextStyle(fontSize: 10.5, color: context.textPrimary, fontWeight: FontWeight.w500),
                                  ),
                                );
                              }).toList(),
                            ),
                            const SizedBox(height: 14),

                            // Actions Row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (!isTrial)
                                  TextButton.icon(
                                    onPressed: () async {
                                      await SubscriptionPlanService.setDefaultTrialPlan(plan.id);
                                      if (context.mounted) AppToast.showSuccess(context, "Set '${plan.name}' as default trial");
                                    },
                                    icon: const Icon(Icons.star_border_rounded, size: 16),
                                    label: const Text("Make Default Trial", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                                    style: TextButton.styleFrom(foregroundColor: primaryAccent),
                                  ),
                                const SizedBox(width: 8),
                                OutlinedButton.icon(
                                  onPressed: () => _showPlanEditorDialog(context, plan),
                                  icon: const Icon(Icons.edit_outlined, size: 16),
                                  label: const Text("Edit Plan", style: TextStyle(fontSize: 12)),
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                    side: BorderSide(color: context.borderColor),
                                  ),
                                ),
                                if (!isTrial) ...[
                                  const SizedBox(width: 8),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline_rounded, color: Colors.redAccent, size: 20),
                                    tooltip: "Delete Plan",
                                    onPressed: () async {
                                      try {
                                        await SubscriptionPlanService.deletePlan(plan.id);
                                        if (context.mounted) AppToast.showSuccess(context, "Plan deleted");
                                      } catch (e) {
                                        if (context.mounted) AppToast.showError(context, e.toString());
                                      }
                                    },
                                  ),
                                ],
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _quotaPill(IconData icon, String label, BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: context.canvasColor,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: context.textSecondary),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: context.textPrimary, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
