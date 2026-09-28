import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/classic_theme.dart';
import '../../core/entitlements.dart';
import '../../core/package_model.dart';
import '../admin/widgets/tier_visuals.dart';
import '../../widgets/package_features_breakdown_widget.dart';
import '../../services/package_service.dart';
import '../../services/otp_verification_service.dart';
import '../../services/apps_script_backend_service.dart';
import '../../services/smtp_email_service.dart';
import '../../services/subscription_plan_service.dart';
import '../../services/tenant_provisioning_service.dart';
import '../../utils/ui_feedback.dart';

class ClientSignUpScreen extends ConsumerStatefulWidget {
  const ClientSignUpScreen({super.key});

  @override
  ConsumerState<ClientSignUpScreen> createState() => _ClientSignUpScreenState();
}

class _ClientSignUpScreenState extends ConsumerState<ClientSignUpScreen> {
  final _formKey = GlobalKey<FormState>();
  final _firestore = FirebaseFirestore.instance;

  // Controllers
  final _nameController = TextEditingController();
  final _shopNameController = TextEditingController();
  final _mobileController = TextEditingController();
  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String _businessCategory = 'Restaurant & Cafe';

  /// Onboarding option: 'free_trial' | a tier id ('offline', 'basic',
  /// 'standard', 'premium') asked for with admin approval | 'enterprise'.
  String _selectedOption = 'free_trial';

  /// The free trial's storage choice: offline on this device, or the
  /// owner's own Google Drive. It selects the trial package.
  bool _trialOffline = true;
  bool get _isFreeTrial => _selectedOption == 'free_trial';
  bool get _isEnterprise => _selectedOption == 'enterprise';
  bool get _isPaidPackage => !_isFreeTrial && !_isEnterprise;

  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;

  // State
  bool _isSendingOtp = false;
  bool _isVerifyingOtp = false;
  bool _isOtpSent = false;
  bool _isEmailVerified = false;
  String? _verifiedEmail;
  bool _isSubmitting = false;

  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  static final RegExp _emailRegex =
      RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');

  // One list for signup, the console and the website trial form.
  final List<String> _categories = BusinessCategories.all;

  @override
  void initState() {
    super.initState();
    _emailController.addListener(_onEmailChanged);
  }

  void _onEmailChanged() {
    final current = _emailController.text.trim().toLowerCase();
    if (_verifiedEmail != null && current == _verifiedEmail) {
      if (!_isEmailVerified) {
        setState(() {
          _isEmailVerified = true;
          _isOtpSent = false;
        });
      }
    } else {
      if (_isEmailVerified) {
        setState(() {
          _isEmailVerified = false;
          _isOtpSent = false;
          _otpController.clear();
        });
      }
    }
  }

  @override
  void dispose() {
    _emailController.removeListener(_onEmailChanged);
    _nameController.dispose();
    _shopNameController.dispose();
    _mobileController.dispose();
    _emailController.dispose();
    _otpController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startResendCooldown() {
    setState(() => _resendCooldown = 30);
    _cooldownTimer?.cancel();
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_resendCooldown <= 1) {
        timer.cancel();
        if (mounted) setState(() => _resendCooldown = 0);
      } else {
        if (mounted) setState(() => _resendCooldown--);
      }
    });
  }

  String get _vertical => Verticals.forCategory(_businessCategory);

  IconData get _categoryHeaderIcon {
    switch (_vertical) {
      case Verticals.restaurant:
        return Icons.restaurant_rounded;
      case Verticals.kirana:
        return Icons.storefront_rounded;
      case Verticals.supermarket:
        return Icons.shopping_cart_rounded;
      case Verticals.pharmacy:
        return Icons.local_pharmacy_rounded;
      case Verticals.retail:
        return Icons.shopping_bag_rounded;
      default:
        return Icons.storefront_rounded;
    }
  }

  String get _categoryHeaderTitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "Onboard Your Restaurant & Cafe";
      case Verticals.kirana:
        return "Onboard Your Kirana Store";
      case Verticals.supermarket:
        return "Onboard Your Supermarket";
      case Verticals.pharmacy:
        return "Onboard Your Pharmacy";
      case Verticals.retail:
        return "Onboard Your Retail Store";
      default:
        return "Onboard Your Business";
    }
  }

  String get _categoryHeaderSubtitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "Get instant access to POS billing, tables, KDS, and QR ordering.";
      case Verticals.kirana:
        return "Get instant access to barcode billing, inventory, khata, and receipts.";
      case Verticals.supermarket:
        return "Get instant access to fast barcode POS, stock manager, and analytics.";
      case Verticals.pharmacy:
        return "Get instant access to medicine billing, inventory, khata, and receipts.";
      case Verticals.retail:
        return "Get instant access to barcode billing, products, khata, and receipts.";
      default:
        return "Instant POS billing, inventory, barcode scanning & digital ordering.";
    }
  }

  String get _storeNameFieldLabel {
    switch (_vertical) {
      case Verticals.restaurant:
        return "Restaurant / Cafe Name *";
      case Verticals.kirana:
        return "Kirana / Grocery Store Name *";
      case Verticals.supermarket:
        return "Supermarket Name *";
      case Verticals.pharmacy:
        return "Pharmacy / Medical Store Name *";
      case Verticals.retail:
        return "Retail Store Name *";
      default:
        return "Store / Business Name *";
    }
  }

  String get _storeNameHintText {
    switch (_vertical) {
      case Verticals.restaurant:
        return "e.g. Spice Garden Bistro";
      case Verticals.kirana:
        return "e.g. Sri Lakshmi Kirana & General Store";
      case Verticals.supermarket:
        return "e.g. Fresh Choice Supermarket";
      case Verticals.pharmacy:
        return "e.g. MedPlus Pharmacy & Healthcare";
      case Verticals.retail:
        return "e.g. City Fashion & Lifestyle";
      default:
        return "e.g. Modern Retail Store";
    }
  }

  String get _freeTrialSubtitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "No approval required. Start using POS, tables, kitchen tickets and printing immediately.";
      case Verticals.kirana:
        return "No approval required. Start using barcode billing, inventory, khata, and receipts immediately.";
      case Verticals.supermarket:
        return "No approval required. Start using barcode POS, inventory, and analytics immediately.";
      case Verticals.pharmacy:
        return "No approval required. Start using medicine billing, stock tracking, and receipts immediately.";
      case Verticals.retail:
        return "No approval required. Start using POS billing, product inventory, and receipts immediately.";
      default:
        return "No approval required. Start using POS billing, inventory, and printing immediately.";
    }
  }

  String get _enterpriseSubtitle {
    switch (_vertical) {
      case Verticals.restaurant:
        return "For multi-outlet restaurant chains needing customized franchise limits and dedicated consultation.";
      case Verticals.kirana:
        return "For multi-branch grocery chains needing customized store limits and dedicated consultation.";
      case Verticals.supermarket:
        return "For supermarket chains needing multi-store setup, central warehouse, and dedicated consultation.";
      case Verticals.pharmacy:
        return "For pharmacy chains needing multi-outlet inventory, batch tracking, and dedicated consultation.";
      case Verticals.retail:
        return "For retail franchise chains needing multi-store setup and dedicated consultation.";
      default:
        return "For multi-store chains needing customized franchise limits and dedicated consultation.";
    }
  }

  String get _emailHintText {
    switch (_vertical) {
      case Verticals.restaurant:
        return "owner@restaurant.com";
      case Verticals.kirana:
        return "owner@kiranastore.com";
      case Verticals.supermarket:
        return "owner@supermarket.com";
      case Verticals.pharmacy:
        return "owner@pharmacy.com";
      case Verticals.retail:
        return "owner@retailstore.com";
      default:
        return "owner@business.com";
    }
  }

  String get _submitButtonLabel {
    if (_isEnterprise) return "Submit Enterprise Request";
    if (_isPaidPackage) return "Submit Package Request";
    switch (_vertical) {
      case Verticals.restaurant:
        return "Start Free Trial & Open Restaurant 🚀";
      case Verticals.kirana:
        return "Start Free Trial & Open Kirana 🚀";
      case Verticals.supermarket:
        return "Start Free Trial & Open Supermarket 🚀";
      case Verticals.pharmacy:
        return "Start Free Trial & Open Pharmacy 🚀";
      case Verticals.retail:
        return "Start Free Trial & Open Store 🚀";
      default:
        return "Start Free Trial & Open Store 🚀";
    }
  }

  /// The trial's tier: the storage choice decides it (contract §3).
  /// Offline on this device -> `<trade>_offline`; my own Google Drive ->
  /// `<trade>_basic` ([Verticals.defaultPackageFor]).
  PackageTier get _trialTier => _trialOffline ? PackageTier.offline : PackageTier.basic;

  /// The tier the chosen option asks for.
  PackageTier get _selectedTier {
    if (_isFreeTrial) return _trialTier;
    if (_isEnterprise) return PackageTier.enterprise;
    return PackageTier.tryParse(_selectedOption) ?? PackageTier.basic;
  }

  /// The features of this trade's package at [tier] (only keys that apply
  /// to the trade are ever on).
  List<FeatureDef> _tierFeatures(PackageTier tier) {
    final map = PackageCatalog.featuresFor(_vertical, tier);
    return [
      for (final def in FeatureCatalog.all)
        if (map[def.key] == true) def,
    ];
  }

  /// "Up to 2 devices · 1 store · 3 users" for [tier] in this trade.
  String _limitsLine(PackageTier tier) {
    final shop = Verticals.isShop(_vertical);
    final l = tier.defaultLimits;
    String n(int v, String one, String many) => '$v ${v == 1 ? one : many}';
    final store = shop ? 'store' : 'outlet';
    final stores = shop ? 'stores' : 'outlets';
    if (tier.isOffline) return '1 device · 1 $store · 1 user (the owner)';
    if (tier.allowsCustomLimits) {
      return 'Devices, $stores and users set for your business '
          '(usually ${l.maxDevices} · ${l.maxOutlets} · ${l.maxUsers})';
    }
    return 'Up to ${n(l.maxDevices, 'device', 'devices')} · ${n(l.maxOutlets, store, stores)} · '
        '${n(l.maxUsers, 'user', 'users')}';
  }

  /// Contract §7 wording for [tier].
  static String _tierNotice(PackageTier tier) => tier.isOffline
      ? '${PackageCatalog.offlineNotice} You can export an encrypted backup of your data '
          'from Settings → Backup & restore.'
      : PackageCatalog.driveNotice;

  /// The storage choice for the free trial: it selects the trial package.
  Widget _trialStorageChoice(Color accent) {
    Widget option(bool offline, IconData icon, String label) {
      final selected = _trialOffline == offline;
      return Expanded(
        child: InkWell(
          onTap: () => setState(() {
            _trialOffline = offline;
            _selectedOption = 'free_trial';
          }),
          borderRadius: BorderRadius.circular(10),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.14) : context.canvasColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: selected ? accent : context.borderColor, width: selected ? 1.4 : 1),
            ),
            child: Row(
              children: [
                Icon(icon, size: 18, color: selected ? accent : context.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.bold : FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Where should your data live?',
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: context.textSecondary)),
        const SizedBox(height: 6),
        Row(
          children: [
            option(true, TierVisuals.icon(PackageTier.offline), 'Offline on this device'),
            const SizedBox(width: 8),
            option(false, TierVisuals.icon(PackageTier.basic), 'My own Google Drive'),
          ],
        ),
      ],
    );
  }

  /// Builds a tappable option card for the plan picker.
  Widget _buildOptionCard({
    required String optionValue,
    required Color primaryAccent,
    required IconData icon,
    required String title,
    required Widget badge,
    required String subtitle,
    List<FeatureDef>? featureChips,
    Widget? top,
    String? heading,
    String? limits,
    String? notice,
    bool isFirst = false,
    bool isLast = false,
  }) {
    final selected = _selectedOption == optionValue;
    return InkWell(
      onTap: () => setState(() => _selectedOption = optionValue),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? primaryAccent.withValues(alpha: 0.10) : context.surfaceColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? primaryAccent : context.borderColor,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                  color: selected ? primaryAccent : context.textSecondary,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Icon(icon, color: selected ? primaryAccent : context.textSecondary, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          color: context.textPrimary,
                        ),
                      ),
                      badge,
                    ],
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 58),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style: TextStyle(color: context.textSecondary, fontSize: 11.5, height: 1.3),
                  ),
                  if (top != null) ...[
                    const SizedBox(height: 10),
                    top,
                  ],
                  if (heading != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      heading,
                      style: TextStyle(color: context.textPrimary, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                  ],
                  if (limits != null) ...[
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Icon(Icons.devices_other_rounded, size: 13, color: context.textSecondary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            limits,
                            style: TextStyle(color: context.textSecondary, fontSize: 11.5, fontWeight: FontWeight.w600),
                          ),
                        ),
                      ],
                    ),
                  ],
                  if (featureChips != null && featureChips.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    PackageFeaturesBreakdownWidget(
                      features: featureChips,
                      vertical: _vertical,
                      accentColor: primaryAccent,
                      isCompact: true,
                      showFeatureIcons: false,
                    ),
                  ],
                  if (notice != null) ...[
                    const SizedBox(height: 8),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.shield_outlined, size: 13, color: context.textSecondary),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            notice,
                            style: TextStyle(color: context.textSecondary, fontSize: 11, height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleSendOtp() async {
    final email = _emailController.text.trim().toLowerCase();
    final name = _nameController.text.trim();

    if (name.isEmpty) {
      AppToast.showError(context, "Please enter your full name first.");
      return;
    }

    if (email.isEmpty || !_emailRegex.hasMatch(email)) {
      AppToast.showError(context, "Please enter a valid email address.");
      return;
    }

    setState(() => _isSendingOtp = true);

    try {
      // 1. Check if user already exists. Under the locked-down rules a
      //    signed-out device can't read /users; the server (START_TRIAL)
      //    refuses a registered e-mail anyway, so a refused read is not an error.
      bool exists = false;
      try {
        final existingUser = await _firestore
            .collection('users')
            .where('email', isEqualTo: email)
            .limit(1)
            .get();
        exists = existingUser.docs.isNotEmpty;
      } catch (e) {
        debugPrint('Existing-account check skipped: $e');
      }

      if (exists) {
        if (mounted) {
          setState(() => _isSendingOtp = false);
          _showAccountExistsDialog(email);
        }
        return;
      }

      // 2. Send OTP
      final res = await OtpVerificationService.sendEmailOtp(
        email: email,
        clientName: name,
      );

      if (mounted) {
        setState(() => _isSendingOtp = false);
        if (res['success'] == true) {
          setState(() => _isOtpSent = true);
          _startResendCooldown();
          AppToast.showSuccess(
            context,
            "OTP Sent to $email",
            subtitle: "Please check your inbox or spam folder for the 6-digit code.",
          );
        } else {
          AppToast.showError(context, res['message'] ?? "Failed to send OTP.");
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSendingOtp = false);
        AppToast.showError(context, e.toString(), title: "OTP Error");
      }
    }
  }

  Future<void> _handleVerifyOtp() async {
    final email = _emailController.text.trim().toLowerCase();
    final otp = _otpController.text.trim();

    if (otp.length != 6) {
      AppToast.showError(context, "Please enter the 6-digit code.");
      return;
    }

    setState(() => _isVerifyingOtp = true);

    final res = await OtpVerificationService.verifyEmailOtp(
      email: email,
      enteredOtp: otp,
    );

    if (mounted) {
      setState(() => _isVerifyingOtp = false);
      if (res['success'] == true) {
        setState(() {
          _verifiedEmail = email;
          _isEmailVerified = true;
          _isOtpSent = false;
        });
        AppToast.showSuccess(context, "Email Verified Successfully!");
      } else {
        AppToast.showError(context, res['message'] ?? "Invalid OTP code.");
      }
    }
  }

  Future<void> _handleSubmitRegistration() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_isEmailVerified) {
      AppToast.showError(context, "Please verify your email with OTP before submitting.");
      return;
    }

    final password = _passwordController.text.trim();
    final confirmPassword = _confirmPasswordController.text.trim();

    if (password.length < 6) {
      AppToast.showError(context, "Password must be at least 6 characters.");
      return;
    }

    if (password != confirmPassword) {
      AppToast.showError(context, "Passwords do not match.");
      return;
    }

    setState(() => _isSubmitting = true);

    final email = _emailController.text.trim().toLowerCase();
    final clientName = _nameController.text.trim();
    final shopName = _shopNameController.text.trim();
    final mobile = _mobileController.text.trim();

    try {
      if (_isFreeTrial) {
        // =====================================================================
        //  INSTANT FREE TRIAL ACTIVATION (NO MANUAL ADMIN APPROVAL REQUIRED!)
        // =====================================================================
        // The trial is a package and a plan like every other licence: the
        // storage choice picks the package (offline -> `<trade>_offline`, own
        // Drive -> `<trade>_basic`), the default trial plan gives the dates
        // only, and both are composed for this trade the same way the
        // console composes them (server: START_TRIAL; here:
        // TenantProvisioningService).
        // Server first: with an e-mail the server verified, Code.gs creates
        // the tenant itself (START_TRIAL) with the password chosen here. The
        // app only writes the tenant documents when the server can't be
        // reached — those writes stop working once the locked rules go live.
        final proof = OtpVerificationService.proofFor(email);
        if (proof != null) {
          final server = await _startTrialOnServer(
            clientName: clientName,
            shopName: shopName,
            email: email,
            mobile: mobile,
            password: password,
            proof: proof,
            packageId: Verticals.defaultPackageFor(_businessCategory, offline: _trialOffline),
            tier: _trialTier,
          );
          if (server != null) {
            if (mounted) {
              setState(() => _isSubmitting = false);
              if (server['success'] == true) {
                _showTrialSuccessDialog(
                  clientName: clientName,
                  shopName: shopName.isNotEmpty ? shopName : _fallbackShopName(clientName),
                  orgId: (server['org_id'] ?? '').toString(),
                  email: email,
                );
              } else {
                AppToast.showError(context, (server['error'] ?? 'The trial could not be created.').toString());
              }
            }
            return;
          }
        }

        final trialTier = _trialTier;
        final trialPackageId = Verticals.defaultPackageFor(_businessCategory, offline: _trialOffline);
        // Validity only: a plan's legacy feature or limit fields never reach
        // the licence.
        final trialPlan = (await SubscriptionPlanService.getDefaultTrialPlan()).copyWith(features: const {});
        final trialPackage =
            (await PackageService.getById(trialPackageId)) ?? PackageCatalog.starter(_vertical, trialTier);

        final res = await TenantProvisioningService.provisionTenant(
          clientName: clientName,
          shopName: shopName,
          email: email,
          mobile: mobile,
          rawPassword: password,
          plan: trialPlan,
          category: _businessCategory,
          mustChangePassword: false,
          storageMode: trialPackage.storageMode,
          packageId: trialPackage.id,
          planId: trialPlan.id,
          tier: trialTier.id,
        );

        if (mounted) {
          setState(() => _isSubmitting = false);
          if (res['success'] == true) {
            _showTrialSuccessDialog(
              clientName: clientName,
              shopName: shopName.isNotEmpty ? shopName : _fallbackShopName(clientName),
              orgId: res['orgId'] ?? '',
              email: email,
            );
          } else {
            AppToast.showError(context, res['message'] ?? "Account creation failed.");
          }
        }
      } else if (_isPaidPackage) {
        // =====================================================================
        //  PAID PACKAGE REQUEST (SUBMITS FOR ADMIN APPROVAL)
        // =====================================================================
        // Signed-out devices can't read requests under the locked rules; a
        // duplicate then simply reaches the admin, who sees both.
        bool pending = false;
        try {
          final pendingReq = await _firestore
              .collection('registration_requests')
              .where('email', isEqualTo: email)
              .where('status', isEqualTo: 'PENDING')
              .limit(1)
              .get();
          pending = pendingReq.docs.isNotEmpty;
        } catch (e) {
          debugPrint('Pending-request check skipped: $e');
        }

        if (pending) {
          setState(() => _isSubmitting = false);
          _showDuplicateRequestDialog(email);
          return;
        }

        final tier = _selectedTier;
        final vertical = Verticals.forCategory(_businessCategory);
        final packageId = PackageCatalog.starterId(vertical, tier);
        final packageLabel = PackageCatalog.nameFor(vertical, tier);
        final fallbackSuffix = vertical == Verticals.restaurant
            ? "Restaurant"
            : vertical == Verticals.supermarket
                ? "Supermarket"
                : vertical == Verticals.pharmacy
                    ? "Pharmacy"
                    : "Store";
        final effectiveShopName = shopName.isNotEmpty ? shopName : "$clientName $fallbackSuffix";

        final reqRef = _firestore.collection('registration_requests').doc();
        await reqRef.set({
          'id': reqRef.id,
          'clientName': clientName,
          'shopName': effectiveShopName,
          'businessCategory': _businessCategory,
          'mobile': mobile,
          'email': email,
          'status': 'PENDING',
          'emailVerified': true,
          if (OtpVerificationService.proofFor(email) != null) 'emailProof': OtpVerificationService.proofFor(email),
          // A package request: this trade's package at the chosen tier. The
          // administrator picks the plan (validity) when approving.
          'requestedPlan': tier.id,
          'requestedPlanLabel': packageLabel,
          'requestedPackageId': packageId,
          'requestedTier': tier.id,
          'requestedStorageMode': tier.defaultStorageMode,
          'vertical': vertical,
          'isEnterprise': false,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
          selectedPlan: packageLabel,
          packageName: packageId,
          features: PackageCatalog.featuresFor(vertical, tier),
        ).catchError((e) {
          debugPrint("Registration email dispatch error: $e");
          return <String, dynamic>{};
        });

        if (mounted) {
          setState(() => _isSubmitting = false);
          _showPackageRequestSubmittedDialog(clientName, email, packageLabel);
        }
      } else {
        // =====================================================================
        //  CUSTOM / ENTERPRISE REQUEST (SUBMITS FOR ADMIN CONSULTATION)
        // =====================================================================
        // Signed-out devices can't read requests under the locked rules; a
        // duplicate then simply reaches the admin, who sees both.
        bool pending = false;
        try {
          final pendingReq = await _firestore
              .collection('registration_requests')
              .where('email', isEqualTo: email)
              .where('status', isEqualTo: 'PENDING')
              .limit(1)
              .get();
          pending = pendingReq.docs.isNotEmpty;
        } catch (e) {
          debugPrint('Pending-request check skipped: $e');
        }

        if (pending) {
          setState(() => _isSubmitting = false);
          _showDuplicateRequestDialog(email);
          return;
        }

        final vertical = Verticals.forCategory(_businessCategory);
        final fallbackSuffix = vertical == Verticals.restaurant
            ? "Restaurant"
            : vertical == Verticals.supermarket
                ? "Supermarket"
                : vertical == Verticals.pharmacy
                    ? "Pharmacy"
                    : "Store";
        final effectiveShopName = shopName.isNotEmpty ? shopName : "$clientName $fallbackSuffix";

        final reqRef = _firestore.collection('registration_requests').doc();
        await reqRef.set({
          'id': reqRef.id,
          'clientName': clientName,
          'shopName': effectiveShopName,
          'businessCategory': _businessCategory,
          'mobile': mobile,
          'email': email,
          'status': 'PENDING',
          'emailVerified': true,
          if (OtpVerificationService.proofFor(email) != null) 'emailProof': OtpVerificationService.proofFor(email),
          'requestedPlan': 'ENTERPRISE_CUSTOM',
          'requestedPlanLabel': PackageCatalog.nameFor(vertical, PackageTier.enterprise),
          'requestedPackageId': PackageCatalog.starterId(vertical, PackageTier.enterprise),
          'requestedTier': PackageTier.enterprise.id,
          'requestedStorageMode': PackageTier.enterprise.defaultStorageMode,
          'vertical': vertical,
          'isEnterprise': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        await SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
          selectedPlan: PackageCatalog.nameFor(vertical, PackageTier.enterprise),
          packageName: PackageCatalog.starterId(vertical, PackageTier.enterprise),
          features: PackageCatalog.featuresFor(vertical, PackageTier.enterprise),
        ).catchError((e) {
          debugPrint("Enterprise registration email dispatch error: $e");
          return <String, dynamic>{};
        });

        if (mounted) {
          setState(() => _isSubmitting = false);
          _showCustomRequestSubmittedDialog(clientName, email);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSubmitting = false);
        AppToast.showError(context, e.toString(), title: "Registration Failed");
      }
    }
  }

  String _fallbackShopName(String clientName) {
    final v = Verticals.forCategory(_businessCategory);
    final suffix = v == Verticals.restaurant
        ? 'Restaurant'
        : v == Verticals.supermarket
            ? 'Supermarket'
            : v == Verticals.pharmacy
                ? 'Pharmacy'
                : 'Store';
    return '$clientName $suffix';
  }

  /// START_TRIAL on Code.gs. null when the server can't be reached.
  Future<Map?> _startTrialOnServer({
    required String clientName,
    required String shopName,
    required String email,
    required String mobile,
    required String password,
    required String proof,
    required String packageId,
    required PackageTier tier,
  }) async {
    try {
      final res = await AppsScriptBackendService.postWithRedirects(
        Uri.parse(AppsScriptBackendService.getWebhookUrl()),
        headers: const {'Content-Type': 'text/plain;charset=utf-8'},
        body: jsonEncode({
          'action': 'START_TRIAL',
          'client_name': clientName,
          'shop_name': shopName,
          'email': email,
          'mobile': mobile,
          'business_category': _businessCategory,
          'password': password,
          'email_proof': proof,
          // The package the storage choice picked; Code.gs composes the
          // licence from it (tier defaults, trade roles) with the default
          // trial plan for the dates.
          'packageId': packageId,
          'tier': tier.id,
          'vertical': _vertical,
          'storageMode': tier.defaultStorageMode,
        }),
        timeout: const Duration(seconds: 40),
      );
      final data = jsonDecode(res.body);
      return data is Map ? data : null;
    } catch (e) {
      debugPrint('START_TRIAL unavailable: $e');
      return null;
    }
  }

  void _showTrialSuccessDialog({
    required String clientName,
    required String shopName,
    required String orgId,
    required String email,
  }) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Text("🎉", style: TextStyle(fontSize: 24)),
            SizedBox(width: 10),
            Expanded(child: Text("Free Trial Activated!", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18))),
          ],
        ),
        content: SingleChildScrollView(child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Builder(builder: (c) {
              final vertical = Verticals.forCategory(_businessCategory);
              final storeType = vertical == Verticals.restaurant
                  ? 'restaurant'
                  : vertical == Verticals.pharmacy
                      ? 'pharmacy'
                      : 'store';
              return Text(
                "Welcome $clientName! Your $storeType '$shopName' is ready with 14-Day Free Trial access.",
                style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
              );
            }),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: ClassicTheme.successEmerald.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_user_rounded, color: ClassicTheme.successEmerald, size: 18),
                      const SizedBox(width: 8),
                      Text("Store ID: $orgId", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: ClassicTheme.successEmerald)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text("Login Email: $email", style: TextStyle(fontSize: 12, color: context.textSecondary)),
                  const SizedBox(height: 2),
                  const Text("Status: Instant Active (No Approval Required)", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ClassicTheme.successEmerald)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Builder(builder: (c) {
              final tier = _trialTier;
              return Text(
                "Your ${PackageCatalog.nameFor(_vertical, tier)} package is active: ${_limitsLine(tier)}. "
                "${_tierNotice(tier)}",
                style: TextStyle(color: context.textSecondary, fontSize: 12, height: 1.4),
              );
            }),
          ],
        )),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // Back to sign in
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              "Sign In to Your ${Verticals.forCategory(_businessCategory) == Verticals.restaurant ? 'Restaurant' : 'Store'} Now →",
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _showPackageRequestSubmittedDialog(String clientName, String email, String packageLabel) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.mark_email_read_rounded, color: ClassicTheme.warningAmber),
            SizedBox(width: 8),
            Expanded(child: Text("Package Request Submitted", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16))),
          ],
        ),
        content: Text(
          "Thank you $clientName! Your request for the \"$packageLabel\" package has been submitted.\n\nOur admin team will review and activate your account at $email shortly.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
              foregroundColor: Colors.black,
            ),
            child: const Text("Return to Sign In", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showCustomRequestSubmittedDialog(String clientName, String email) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.mark_email_read_rounded, color: ClassicTheme.warningAmber),
            SizedBox(width: 8),
            Text("Enterprise Request Received", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          "Thank you $clientName! Our platform team will contact you on $email to configure your multi-branch enterprise deployment.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.warningAmber,
              foregroundColor: Colors.black,
            ),
            child: const Text("Return to Sign In", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showAccountExistsDialog(String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.info_outline, color: ClassicTheme.infoBlue),
            SizedBox(width: 8),
            Text("Account Already Exists", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          "An account for '$email' is already registered. Please proceed to sign in with your email and password.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text("Go to Sign In", style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  void _showDuplicateRequestDialog(String email) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surfaceColor,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.hourglass_top_rounded, color: ClassicTheme.warningAmber),
            SizedBox(width: 8),
            Text("Request Under Review", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          ],
        ),
        content: Text(
          "Your custom setup enquiry is currently pending review by our administrator. We will contact you at $email shortly.",
          style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            child: const Text("Got It"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final primaryAccent = ClassicTheme.warningAmber; // SmartBizz Amber Gold

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.textPrimary),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          "Business Registration",
          style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 18),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 12.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Brand Header Banner
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: primaryAccent.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: primaryAccent.withValues(alpha: 0.25)),
                      ),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.asset(
                              'lib/assets/logo.png',
                              width: 48,
                              height: 48,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: 48,
                                height: 48,
                                decoration: BoxDecoration(
                                  color: primaryAccent.withValues(alpha: 0.2),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(_categoryHeaderIcon, color: primaryAccent, size: 28),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _categoryHeaderTitle,
                                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _categoryHeaderSubtitle,
                                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // SECTION 1: BUSINESS & OWNER BASICS
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Category *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              DropdownButtonFormField<String>(
                                initialValue: _businessCategory,
                                isExpanded: true,
                                borderRadius: BorderRadius.circular(14),
                                icon: Icon(Icons.keyboard_arrow_down_rounded, color: context.textSecondary, size: 20),
                                dropdownColor: context.surfaceColor,
                                style: TextStyle(color: context.textPrimary, fontSize: 13),
                                decoration: ClassicTheme.inputDecorationFor(context, hintText: "Category"),
                                items: _categories.map((c) => DropdownMenuItem(
                                  value: c,
                                  child: Text(c, style: TextStyle(fontSize: 12, color: context.textPrimary), overflow: TextOverflow.ellipsis),
                                )).toList(),
                                onChanged: (v) {
                                  if (v != null) {
                                    // Tiers are the same for every trade; only the
                                    // package (its features) follows the category.
                                    setState(() => _businessCategory = v);
                                  }
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Mobile Number *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                              const SizedBox(height: 6),
                              TextFormField(
                                controller: _mobileController,
                                keyboardType: TextInputType.phone,
                                style: TextStyle(color: context.textPrimary, fontSize: 14),
                                decoration: ClassicTheme.inputDecorationFor(
                                  context,
                                  hintText: "10-digit mobile",
                                  prefixIcon: Icon(Icons.phone_android_outlined, color: context.textSecondary, size: 20),
                                ),
                                validator: (v) => v == null || v.trim().length < 10 ? "10-digit mobile required" : null,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),

                    Text("Owner Full Name *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _nameController,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "e.g. Santhosh Bukka",
                        prefixIcon: Icon(Icons.person_outline, color: context.textSecondary, size: 20),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? "Full name is required" : null,
                    ),
                    const SizedBox(height: 16),

                    Text(_storeNameFieldLabel, style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _shopNameController,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: _storeNameHintText,
                        prefixIcon: Icon(Icons.storefront_outlined, color: context.textSecondary, size: 20),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? "Name is required" : null,
                    ),
                    const SizedBox(height: 20),

                    // SECTION 2: PLAN SELECTION
                    Text("Select Onboarding Option", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Builder(builder: (context) {
                      final trialTier = _trialTier;
                      return _buildOptionCard(
                        optionValue: 'free_trial',
                        primaryAccent: primaryAccent,
                        isFirst: true,
                        icon: Icons.rocket_launch_rounded,
                        title: "Start 14-Day Free Trial",
                        badge: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            "INSTANT ACCESS",
                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                          ),
                        ),
                        subtitle: _freeTrialSubtitle,
                        top: _trialStorageChoice(primaryAccent),
                        heading: PackageCatalog.headingFor(_vertical, trialTier),
                        limits: _limitsLine(trialTier),
                        featureChips: _tierFeatures(trialTier),
                        notice: _tierNotice(trialTier),
                      );
                    }),
                    const SizedBox(height: 8),
                    // --- This trade's packages, tier by tier (admin approval) ---
                    ...const [
                      PackageTier.offline,
                      PackageTier.basic,
                      PackageTier.standard,
                      PackageTier.premium,
                    ].map((tier) {
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildOptionCard(
                          optionValue: tier.id,
                          primaryAccent: primaryAccent,
                          icon: TierVisuals.icon(tier),
                          title: PackageCatalog.nameFor(_vertical, tier),
                          badge: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Text(
                              "ADMIN APPROVAL",
                              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.warningAmber),
                            ),
                          ),
                          subtitle: tier.isOffline
                              ? 'Runs on this device for one store, with the owner as the only user.'
                              : 'Runs on your own Google Drive, shared across your devices and staff.',
                          heading: PackageCatalog.headingFor(_vertical, tier),
                          limits: _limitsLine(tier),
                          featureChips: _tierFeatures(tier),
                          notice: _tierNotice(tier),
                        ),
                      );
                    }),
                    // --- Enterprise card ---
                    _buildOptionCard(
                      optionValue: 'enterprise',
                      primaryAccent: primaryAccent,
                      isLast: true,
                      icon: TierVisuals.icon(PackageTier.enterprise),
                      title: PackageCatalog.nameFor(_vertical, PackageTier.enterprise),
                      badge: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: ClassicTheme.warningAmber.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          "ADMIN APPROVAL",
                          style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: ClassicTheme.warningAmber),
                        ),
                      ),
                      subtitle: _enterpriseSubtitle,
                      heading: PackageCatalog.headingFor(_vertical, PackageTier.enterprise),
                      limits: _limitsLine(PackageTier.enterprise),
                      featureChips: _tierFeatures(PackageTier.enterprise),
                      notice: _tierNotice(PackageTier.enterprise),
                    ),
                    const SizedBox(height: 20),

                    // SECTION 3: EMAIL VERIFICATION (MANDATORY)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(child: Text("Email Address (Mandatory OTP Verification) *", maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600))),
                        if (_isEmailVerified)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.check_circle_rounded, size: 12, color: ClassicTheme.successEmerald),
                                SizedBox(width: 4),
                                Text("Verified", style: TextStyle(color: ClassicTheme.successEmerald, fontSize: 12, fontWeight: FontWeight.bold)),
                              ],
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _emailController,
                            keyboardType: TextInputType.emailAddress,
                            style: TextStyle(color: context.textPrimary, fontSize: 14),
                            decoration: ClassicTheme.inputDecorationFor(
                              context,
                              hintText: _emailHintText,
                              prefixIcon: Icon(Icons.email_outlined, color: context.textSecondary, size: 20),
                            ),
                            validator: (v) {
                              if (v == null || v.trim().isEmpty) return "Email is required";
                              if (!_emailRegex.hasMatch(v.trim())) {
                                return "Enter a valid email address";
                              }
                              return null;
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        if (!_isEmailVerified)
                          ElevatedButton(
                            onPressed: (_isSendingOtp || _resendCooldown > 0) ? null : _handleSendOtp,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: primaryAccent,
                              foregroundColor: Colors.black,
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                            child: _isSendingOtp
                                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                                : Text(
                                    _resendCooldown > 0 ? "Wait ${_resendCooldown}s" : (_isOtpSent ? "Resend" : "Send OTP"),
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
                                  ),
                          ),
                      ],
                    ),

                    // OTP Input when OTP Sent
                    if (_isOtpSent && !_isEmailVerified) ...[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: primaryAccent.withValues(alpha: 0.4)),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _otpController,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, letterSpacing: 4),
                                decoration: ClassicTheme.inputDecorationFor(
                                  context,
                                  hintText: "6-digit OTP",
                                  prefixIcon: const Icon(Icons.pin_outlined, size: 20),
                                ).copyWith(counterText: ""),
                              ),
                            ),
                            const SizedBox(width: 10),
                            ElevatedButton(
                              onPressed: _isVerifyingOtp ? null : _handleVerifyOtp,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: ClassicTheme.successEmerald,
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                              ),
                              child: _isVerifyingOtp
                                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                  : const Text("Verify OTP", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),

                    // SECTION 4: LOGIN PASSWORD (FOR INSTANT LOGIN)
                    Text("Create Password *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _passwordController,
                      obscureText: _obscurePassword,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "Minimum 6 characters",
                        prefixIcon: Icon(Icons.lock_outline, color: context.textSecondary, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(_obscurePassword ? Icons.visibility_off : Icons.visibility, color: context.textSecondary, size: 20),
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                        ),
                      ),
                      validator: (v) => v == null || v.trim().length < 6 ? "Password must be at least 6 characters" : null,
                    ),
                    const SizedBox(height: 14),

                    Text("Confirm Password *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _confirmPasswordController,
                      obscureText: _obscureConfirmPassword,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "Re-enter password",
                        prefixIcon: Icon(Icons.lock_reset, color: context.textSecondary, size: 20),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureConfirmPassword ? Icons.visibility_off : Icons.visibility, color: context.textSecondary, size: 20),
                          onPressed: () => setState(() => _obscureConfirmPassword = !_obscureConfirmPassword),
                        ),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return "Please confirm password";
                        if (v.trim() != _passwordController.text.trim()) return "Passwords do not match";
                        return null;
                      },
                    ),
                    const SizedBox(height: 28),

                    // SUBMIT BUTTON
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: _isSubmitting ? null : _handleSubmitRegistration,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: primaryAccent,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          elevation: 2,
                        ),
                        child: _isSubmitting
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black))
                            : Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(_isFreeTrial ? Icons.rocket_launch_rounded : Icons.send_rounded, size: 20),
                                  const SizedBox(width: 8),
                                  Flexible(
                                    child: Text(
                                      _submitButtonLabel,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Already have an account -> Sign In
                    Center(
                      child: TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(
                          "Already have an account? Sign In",
                          style: TextStyle(color: primaryAccent, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
