import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/classic_theme.dart';
import '../../core/entitlements.dart';
import '../../core/license_composer.dart';
import '../../core/package_model.dart';
import '../../services/package_service.dart';
import '../../services/otp_verification_service.dart';
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

  /// Onboarding option: 'free_trial' | PlanProfile ID | 'enterprise'
  String _selectedOption = 'free_trial';
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

  final List<String> _categories = const [
    // Restaurant sub-categories
    'Restaurant & Cafe',
    'Fast Food / QSR',
    'Fine Dining & Bar',
    'Bakery & Sweets',
    'Food Court / Kiosk',
    'Cloud Kitchen / Delivery',
    'Pizzeria / Italian',
    'Coffee House / Tea Lounge',
    'Other Hospitality',
    // Retail verticals
    'Kirana / Grocery Store',
    'Supermarket / Departmental Store',
    'Pharmacy / Medical Store',
    'General Retail / Fashion / Electronics',
  ];

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
        return "No approval required. Start using POS, tables, KDS, and printing immediately.";
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

  /// Returns features enabled in [profile] that are relevant to [vertical].
  static List<FeatureDef> _filteredFeaturesFor(PlanProfile profile, String vertical) {
    final features = profile.features;
    return features.entries
        .where((e) => e.value) // only enabled features
        .map((e) => FeatureCatalog.find(e.key))
        .where((def) => def != null)
        .cast<FeatureDef>()
        .where((def) => def.verticals.isEmpty || def.verticals.contains(vertical))
        .toList();
  }

  /// Icon for a PlanProfile.
  static IconData _profileIcon(PlanProfile p) {
    switch (p.id) {
      case 'OFFLINE_SINGLE':
        return Icons.point_of_sale_rounded;
      case 'OFFLINE_DINE_IN':
        return Icons.table_restaurant_rounded;
      case 'CONNECTED':
        return Icons.cloud_sync_rounded;
      case 'OMNICHANNEL':
        return Icons.all_inclusive_rounded;
      default:
        return Icons.storefront_rounded;
    }
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
                  if (featureChips != null && featureChips.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: featureChips.map((def) => Container(
                        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                        decoration: BoxDecoration(
                          color: context.borderColor.withValues(alpha: 0.35),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          def.label,
                          style: TextStyle(fontSize: 10, color: context.textSecondary),
                        ),
                      )).toList(),
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
      // 1. Check if user already exists
      final existingUser = await _firestore
          .collection('users')
          .where('email', isEqualTo: email)
          .limit(1)
          .get();

      if (existingUser.docs.isNotEmpty) {
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
        // starter package for this business category, on the default trial
        // plan, composed the same way the console composes them.
        final trialPlan = await SubscriptionPlanService.getDefaultTrialPlan();
        final trialPackage =
            (await PackageService.getById(Verticals.defaultPackageFor(_businessCategory))) ??
                TenantPackage.fromProfile(PlanProfile.offlineDineIn);
        final composed = LicenseComposer.compose(trialPackage, trialPlan);

        final res = await TenantProvisioningService.provisionTenant(
          clientName: clientName,
          shopName: shopName,
          email: email,
          mobile: mobile,
          rawPassword: password,
          plan: trialPlan.copyWith(
            maxOutlets: composed.maxOutlets,
            maxDevices: composed.maxDevices,
            maxUsers: composed.maxUsers,
            allowedRoles: composed.allowedRoles,
            features: composed.features,
          ),
          category: _businessCategory,
          mustChangePassword: false,
          storageMode: composed.storageMode,
          planProfile: trialPackage.nearestProfile.id,
          packageId: trialPackage.id,
          planId: trialPlan.id,
        );

        if (mounted) {
          setState(() => _isSubmitting = false);
          if (res['success'] == true) {
            _showTrialSuccessDialog(
              clientName: clientName,
              shopName: shopName.isNotEmpty ? shopName : "$clientName Restaurant",
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
        final pendingReq = await _firestore
            .collection('registration_requests')
            .where('email', isEqualTo: email)
            .where('status', isEqualTo: 'PENDING')
            .limit(1)
            .get();

        if (pendingReq.docs.isNotEmpty) {
          setState(() => _isSubmitting = false);
          _showDuplicateRequestDialog(email);
          return;
        }

        final profile = PlanProfile.byId(_selectedOption);
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
          'requestedPlan': _selectedOption,
          'requestedPlanLabel': profile.label,
          'requestedPackageId': profile.id,
          'requestedPlanId': profile.id.toLowerCase(),
          'isEnterprise': false,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
        ).catchError((_) => <String, dynamic>{});

        if (mounted) {
          setState(() => _isSubmitting = false);
          _showPackageRequestSubmittedDialog(clientName, email, profile.label);
        }
      } else {
        // =====================================================================
        //  CUSTOM / ENTERPRISE REQUEST (SUBMITS FOR ADMIN CONSULTATION)
        // =====================================================================
        final pendingReq = await _firestore
            .collection('registration_requests')
            .where('email', isEqualTo: email)
            .where('status', isEqualTo: 'PENDING')
            .limit(1)
            .get();

        if (pendingReq.docs.isNotEmpty) {
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
          'requestedPlan': 'ENTERPRISE_CUSTOM',
          'requestedPlanLabel': 'Enterprise / Custom Setup',
          'requestedPackageId': PlanProfile.omnichannel.id,
          'requestedPlanId': 'omnichannel',
          'isEnterprise': true,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: effectiveShopName,
          businessCategory: _businessCategory,
          mobile: mobile,
        ).catchError((_) => <String, dynamic>{});

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
              final vertical = Verticals.forCategory(_businessCategory);
              final highlights = vertical == Verticals.restaurant
                  ? "Full access to Counter Billing, Table Management, Kitchen KDS, and Dual Printing is now unlocked."
                  : vertical == Verticals.pharmacy
                      ? "Full access to POS Billing Desk, Medicines & Stock, and Sales Reports is now unlocked."
                      : "Full access to POS Billing Desk, Products & Stock, and Sales Reports is now unlocked.";
              return Text(
                highlights,
                style: TextStyle(color: context.textSecondary, fontSize: 12),
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
          "Thank you $clientName! Your request for the \"${packageLabel[0].toUpperCase()}${packageLabel.substring(1)}\" plan has been submitted.\n\nOur admin team will review and activate your account at $email shortly.",
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
    final primaryAccent = ClassicTheme.warningAmber; // SmartDine Amber Gold

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
          "Store Registration",
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
                                onChanged: (v) => setState(() => _businessCategory = v!),
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
                    // --- Free Trial card ---
                    _buildOptionCard(
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
                    ),
                    const SizedBox(height: 8),
                    // --- 4 Package cards ---
                    ...PlanProfile.all.map((profile) {
                      final features = _filteredFeaturesFor(profile, _vertical);
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _buildOptionCard(
                          optionValue: profile.id,
                          primaryAccent: primaryAccent,
                          icon: _profileIcon(profile),
                          title: profile.label[0].toUpperCase() + profile.label.substring(1),
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
                          subtitle: profile.description,
                          featureChips: features,
                        ),
                      );
                    }),
                    // --- Enterprise card ---
                    _buildOptionCard(
                      optionValue: 'enterprise',
                      primaryAccent: primaryAccent,
                      isLast: true,
                      icon: Icons.business_rounded,
                      title: "Enterprise / Custom Setup",
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
