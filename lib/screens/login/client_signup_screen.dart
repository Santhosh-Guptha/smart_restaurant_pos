import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../core/classic_theme.dart';
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
  bool _isFreeTrial = true; // true = Instant 14-day Free Trial, false = Custom/Enterprise request
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
    'Restaurant & Cafe',
    'Fast Food / QSR',
    'Fine Dining & Bar',
    'Bakery & Sweets',
    'Food Court / Kiosk',
    'Cloud Kitchen / Delivery',
    'Pizzeria / Italian',
    'Coffee House / Tea Lounge',
    'Other Hospitality',
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
        final trialPlan = await SubscriptionPlanService.getDefaultTrialPlan();

        final res = await TenantProvisioningService.provisionTenant(
          clientName: clientName,
          shopName: shopName,
          email: email,
          mobile: mobile,
          rawPassword: password,
          plan: trialPlan,
          category: _businessCategory,
          mustChangePassword: false,
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

        final reqRef = _firestore.collection('registration_requests').doc();
        await reqRef.set({
          'id': reqRef.id,
          'clientName': clientName,
          'shopName': shopName.isNotEmpty ? shopName : "$clientName Restaurant",
          'businessCategory': _businessCategory,
          'mobile': mobile,
          'email': email,
          'status': 'PENDING',
          'emailVerified': true,
          'requestedPlan': 'ENTERPRISE_CUSTOM',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });

        SmtpEmailService.sendRegistrationSubmittedEmail(
          recipientEmail: email,
          clientName: clientName,
          shopName: shopName.isNotEmpty ? shopName : "$clientName Store",
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
            Text("Free Trial Activated!", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "Welcome $clientName! Your restaurant '$shopName' is ready with 14-Day Free Trial access.",
              style: TextStyle(color: context.textPrimary, fontSize: 13, height: 1.4),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFF10B981).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.verified_user_rounded, color: Color(0xFF10B981), size: 18),
                      const SizedBox(width: 8),
                      Text("Store ID: $orgId", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13, color: Color(0xFF10B981))),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text("Login Email: $email", style: TextStyle(fontSize: 12, color: context.textSecondary)),
                  const SizedBox(height: 2),
                  const Text("Status: Instant Active (No Approval Required)", style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFF10B981))),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Full access to Counter Billing, Table Management, Kitchen KDS, and Dual Printing is now unlocked.",
              style: TextStyle(color: context.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.pop(context); // Back to sign in
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFF59E0B),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            child: const Text("Sign In to Your Restaurant Now →", style: TextStyle(fontWeight: FontWeight.bold)),
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
            Icon(Icons.mark_email_read_rounded, color: Color(0xFFF59E0B)),
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
              backgroundColor: const Color(0xFFF59E0B),
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
            Icon(Icons.info_outline, color: Color(0xFF2563EB)),
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
            Icon(Icons.hourglass_top_rounded, color: Colors.orangeAccent),
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
    final primaryAccent = const Color(0xFFF59E0B); // SmartDine Amber Gold

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
                                child: Icon(Icons.restaurant_rounded, color: primaryAccent, size: 28),
                              ),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Onboard Your Restaurant & Cafe",
                                  style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  "Get instant access to POS billing, tables, KDS, and QR ordering.",
                                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // SECTION 1: RESTAURANT & OWNER BASICS
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

                    Text("Restaurant / Cafe Name *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _shopNameController,
                      style: TextStyle(color: context.textPrimary, fontSize: 14),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "e.g. Spice Garden Bistro",
                        prefixIcon: Icon(Icons.storefront_outlined, color: context.textSecondary, size: 20),
                      ),
                      validator: (v) => v == null || v.trim().isEmpty ? "Restaurant name is required" : null,
                    ),
                    const SizedBox(height: 16),

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
                                value: _businessCategory,
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
                    const SizedBox(height: 20),

                    // SECTION 2: PLAN SELECTION
                    Text("Select Onboarding Option", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: context.surfaceColor,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: context.borderColor),
                      ),
                      child: Column(
                        children: [
                          // Option 1: Free Trial
                          InkWell(
                            onTap: () => setState(() => _isFreeTrial = true),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: _isFreeTrial ? primaryAccent.withValues(alpha: 0.12) : Colors.transparent,
                                borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                                border: _isFreeTrial ? Border.all(color: primaryAccent, width: 1.5) : null,
                              ),
                              child: Row(
                                children: [
                                  Radio<bool>(
                                    value: true,
                                    groupValue: _isFreeTrial,
                                    activeColor: primaryAccent,
                                    onChanged: (v) => setState(() => _isFreeTrial = v!),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            const Text(
                                              "Start 14-Day Free Trial",
                                              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                            ),
                                            const SizedBox(width: 8),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: const Text(
                                                "INSTANT ACCESS",
                                                style: TextStyle(fontSize: 9, fontWeight: FontWeight.bold, color: Color(0xFF10B981)),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          "No approval required. Start using POS, tables, KDS, and printing immediately.",
                                          style: TextStyle(color: context.textSecondary, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          Divider(height: 1, color: context.borderColor),
                          // Option 2: Enterprise / Custom Request
                          InkWell(
                            onTap: () => setState(() => _isFreeTrial = false),
                            borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                            child: Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: !_isFreeTrial ? primaryAccent.withValues(alpha: 0.12) : Colors.transparent,
                                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(16)),
                                border: !_isFreeTrial ? Border.all(color: primaryAccent, width: 1.5) : null,
                              ),
                              child: Row(
                                children: [
                                  Radio<bool>(
                                    value: false,
                                    groupValue: _isFreeTrial,
                                    activeColor: primaryAccent,
                                    onChanged: (v) => setState(() => _isFreeTrial = v!),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          "Request Custom / Enterprise Setup",
                                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          "For multi-outlet restaurant chains needing customized franchise limits and dedicated consultation.",
                                          style: TextStyle(color: context.textSecondary, fontSize: 11),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),

                    // SECTION 3: EMAIL VERIFICATION (MANDATORY)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text("Email Address (Mandatory OTP Verification) *", style: TextStyle(color: context.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
                        if (_isEmailVerified)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF10B981).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: const Row(
                              children: [
                                Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF10B981)),
                                SizedBox(width: 4),
                                Text("Verified", style: TextStyle(color: Color(0xFF10B981), fontSize: 11, fontWeight: FontWeight.bold)),
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
                              hintText: "owner@restaurant.com",
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
                                backgroundColor: const Color(0xFF10B981),
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
                                  Text(
                                    _isFreeTrial ? "Start Free Trial & Open Store 🚀" : "Submit Enterprise Request",
                                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
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
