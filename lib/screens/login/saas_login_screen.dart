import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/classic_theme.dart';
import '../../providers/auth_provider.dart';
import '../../utils/ui_feedback.dart';
import '../../providers/theme_provider.dart';
import 'client_signup_screen.dart';

class SaaSLoginScreen extends ConsumerStatefulWidget {
  const SaaSLoginScreen({super.key});

  @override
  ConsumerState<SaaSLoginScreen> createState() => _SaaSLoginScreenState();
}

class _SaaSLoginScreenState extends ConsumerState<SaaSLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _otpController = TextEditingController();

  bool _isLoggingIn = false;
  bool _isVerifyingOtp = false;
  bool _isResendingOtp = false;
  bool _obscurePassword = true;
  bool _rememberMe = false;
  String? _errorMessage;

  // 2MFA State
  bool _isMfaStep = false;
  String _mfaEmail = '';
  int _resendCooldown = 0;
  Timer? _cooldownTimer;

  @override
  void initState() {
    super.initState();
    final box = Hive.box('configBox');
    _rememberMe = box.get('saas_remember_me', defaultValue: false);
    final savedEmail = box.get('saas_last_email') as String?;
    if (savedEmail != null && savedEmail.isNotEmpty) {
      _emailController.text = savedEmail;
    }
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _otpController.dispose();
    _cooldownTimer?.cancel();
    super.dispose();
  }

  void _startResendCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendCooldown = 30);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (_resendCooldown <= 1) {
        timer.cancel();
        setState(() => _resendCooldown = 0);
      } else {
        setState(() => _resendCooldown--);
      }
    });
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoggingIn = true;
      _errorMessage = null;
    });

    final res = await ref.read(authProvider.notifier).loginSaaS(
          _emailController.text.trim(),
          _passwordController.text,
          rememberMe: _rememberMe,
        );

    if (mounted) {
      if (res != null && res.startsWith('MFA_REQUIRED:')) {
        final email = res.substring('MFA_REQUIRED:'.length).trim();
        setState(() {
          _isLoggingIn = false;
          _isMfaStep = true;
          _mfaEmail = email;
          _errorMessage = null;
          _otpController.clear();
        });
        _startResendCooldown();
        AppToast.showSuccess(
          context,
          "Security code dispatched to $email",
          subtitle: "Two-Step Verification",
        );
      } else {
        setState(() {
          _isLoggingIn = false;
          if (res != null) {
            _errorMessage = res;
            AppToast.showError(context, res, title: "Login Failed");
          }
        });
      }
    }
  }

  Future<void> _handleVerifyMfa() async {
    final code = _otpController.text.trim();
    if (code.length != 6) {
      setState(() => _errorMessage = "Please enter the complete 6-digit security code");
      return;
    }

    setState(() {
      _isVerifyingOtp = true;
      _errorMessage = null;
    });

    final res = await ref.read(authProvider.notifier).loginSaaS(
          _emailController.text.trim(),
          _passwordController.text,
          rememberMe: _rememberMe,
          mfaCode: code,
        );

    if (mounted) {
      setState(() {
        _isVerifyingOtp = false;
        if (res != null) {
          _errorMessage = res;
          AppToast.showError(context, res, title: "Verification Failed");
        }
      });
    }
  }

  Future<void> _handleResendMfa() async {
    if (_resendCooldown > 0 || _isResendingOtp) return;

    setState(() {
      _isResendingOtp = true;
      _errorMessage = null;
    });

    final res = await ref.read(authProvider.notifier).resendMfaCode(_mfaEmail);

    if (mounted) {
      setState(() {
        _isResendingOtp = false;
      });
      if (res['success'] == true) {
        _startResendCooldown();
        AppToast.showSuccess(
          context,
          "A new security code was sent to $_mfaEmail",
          subtitle: "Code Resent",
        );
      } else {
        final err = res['message'] ?? 'Failed to resend code';
        setState(() => _errorMessage = err);
        AppToast.showError(context, err, title: "Resend Failed");
      }
    }
  }

  void _cancelMfa() {
    _cooldownTimer?.cancel();
    setState(() {
      _isMfaStep = false;
      _errorMessage = null;
      _otpController.clear();
      _resendCooldown = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
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
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 10.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // App Branding Header
                  Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
                    ),
                    child: Icon(
                      Icons.storefront_rounded,
                      size: 34,
                      color: ClassicTheme.primaryAccent,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    "SmartDine POS",
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "Zero-Cost Cloud & Offline Multi-Outlet Billing",
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 28),

                  // Main Login Card
                  Container(
                    decoration: BoxDecoration(
                      color: context.surfaceColor,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: context.borderColor),
                      boxShadow: ClassicTheme.cardShadow(context.isDark),
                    ),
                    padding: const EdgeInsets.all(24.0),
                    child: _isMfaStep
                        ? _buildMfaView(context)
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              if (_errorMessage != null) ...[
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: ClassicTheme.dangerRed.withValues(alpha: 0.15),
                                    border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.4)),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Row(
                                    children: [
                                      const Icon(Icons.error_outline, color: ClassicTheme.dangerRed, size: 20),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text(
                                          _errorMessage!,
                                          style: const TextStyle(color: ClassicTheme.textPrimary, fontSize: 13),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 18),
                              ],

                              if (_isLoggingIn)
                                const Center(
                                  child: Padding(
                                    padding: EdgeInsets.symmetric(vertical: 36.0),
                                    child: CircularProgressIndicator(color: ClassicTheme.primaryAccent),
                                  ),
                                )
                              else
                                Form(
                                  key: _formKey,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        "Username or Email",
                                        style: TextStyle(
                                          color: context.textSecondary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      TextFormField(
                                        controller: _emailController,
                                        keyboardType: TextInputType.text,
                                        style: TextStyle(color: context.textPrimary, fontSize: 14),
                                        decoration: ClassicTheme.inputDecorationFor(
                                          context,
                                          hintText: "Enter username or email",
                                          prefixIcon: Icon(Icons.person_outline_rounded, color: context.textSecondary, size: 20),
                                        ),
                                        validator: (v) => v == null || v.trim().isEmpty ? "Username or email is required" : null,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        "Password",
                                        style: TextStyle(
                                          color: context.textSecondary,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      TextFormField(
                                        controller: _passwordController,
                                        obscureText: _obscurePassword,
                                        style: TextStyle(color: context.textPrimary, fontSize: 14),
                                        decoration: ClassicTheme.inputDecorationFor(
                                          context,
                                          hintText: "Enter your password",
                                          prefixIcon: Icon(Icons.lock_outline, color: context.textSecondary, size: 20),
                                          suffixIcon: IconButton(
                                            icon: Icon(
                                              _obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                                              color: context.textSecondary,
                                              size: 20,
                                            ),
                                            onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                                          ),
                                        ),
                                        validator: (v) => v == null || v.isEmpty ? "Password is required" : null,
                                      ),
                                      const SizedBox(height: 14),
                                      Row(
                                        children: [
                                          SizedBox(
                                            height: 20,
                                            width: 20,
                                            child: Checkbox(
                                              value: _rememberMe,
                                              activeColor: ClassicTheme.primaryAccent,
                                              checkColor: Colors.black,
                                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                                              onChanged: (v) => setState(() => _rememberMe = v ?? false),
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Text(
                                            "Stay signed in",
                                            style: TextStyle(color: context.textSecondary, fontSize: 13),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 20),
                                      SizedBox(
                                        width: double.infinity,
                                        height: 48,
                                        child: ElevatedButton(
                                          onPressed: _handleLogin,
                                          style: ElevatedButton.styleFrom(
                                            backgroundColor: ClassicTheme.primaryAccent,
                                            foregroundColor: Colors.white,
                                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                          ),
                                          child: const Text(
                                            "Sign In",
                                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 16),

                  // Footer Actions
                  if (_isMfaStep)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.lock_outline_rounded, size: 14, color: context.textSecondary),
                          const SizedBox(width: 6),
                          Text(
                            "Secured with Two-Factor Authentication",
                            style: TextStyle(color: context.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    )
                  else
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          "New retail business? ",
                          style: TextStyle(color: context.textSecondary, fontSize: 13),
                        ),
                        GestureDetector(
                          onTap: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(builder: (_) => const ClientSignUpScreen()),
                            );
                          },
                          child: Text(
                            "Register Store",
                            style: TextStyle(
                              color: ClassicTheme.primaryAccent,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMfaView(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Center(
          child: Container(
            width: 58,
            height: 58,
            decoration: BoxDecoration(
              color: ClassicTheme.primaryAccent.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: ClassicTheme.primaryAccent.withValues(alpha: 0.3)),
            ),
            child: Icon(
              Icons.verified_user_rounded,
              size: 30,
              color: ClassicTheme.primaryAccent,
            ),
          ),
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            "2-Step Verification",
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            "Enter the 6-digit security code sent to:",
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: context.isDark ? Colors.white.withValues(alpha: 0.06) : Colors.black.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.borderColor),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.mail_outline_rounded, size: 14, color: ClassicTheme.primaryAccent),
                const SizedBox(width: 6),
                Text(
                  _mfaEmail,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),

        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ClassicTheme.dangerRed.withValues(alpha: 0.15),
              border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.4)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                const Icon(Icons.error_outline, color: ClassicTheme.dangerRed, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(color: ClassicTheme.textPrimary, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        // Monospace 6-digit OTP field
        TextFormField(
          controller: _otpController,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          textAlign: TextAlign.center,
          autofocus: true,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 26,
            letterSpacing: 10,
            fontWeight: FontWeight.w800,
            fontFamily: 'monospace',
          ),
          decoration: InputDecoration(
            hintText: "••••••",
            hintStyle: TextStyle(
              color: context.textSecondary.withValues(alpha: 0.4),
              letterSpacing: 10,
              fontSize: 24,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: context.borderColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: context.borderColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: ClassicTheme.primaryAccent, width: 2),
            ),
            filled: true,
            fillColor: context.isDark ? Colors.grey[900] : Colors.grey[50],
          ),
          onFieldSubmitted: (_) => _handleVerifyMfa(),
        ),
        const SizedBox(height: 18),

        // Verify button
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            onPressed: _isVerifyingOtp ? null : _handleVerifyMfa,
            style: ElevatedButton.styleFrom(
              backgroundColor: ClassicTheme.primaryAccent,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: _isVerifyingOtp
                ? const SizedBox(
                    width: 22,
                    height: 22,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                  )
                : const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.lock_open_rounded, size: 18),
                      SizedBox(width: 8),
                      Text("Verify & Sign In", style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    ],
                  ),
          ),
        ),
        const SizedBox(height: 14),

        // Resend & Back Row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            TextButton.icon(
              onPressed: _isVerifyingOtp ? null : _cancelMfa,
              icon: const Icon(Icons.arrow_back, size: 16),
              label: const Text("Back to Login", style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(foregroundColor: context.textSecondary),
            ),
            TextButton(
              onPressed: (_resendCooldown > 0 || _isResendingOtp || _isVerifyingOtp) ? null : _handleResendMfa,
              child: Text(
                _resendCooldown > 0
                    ? "Resend in ${_resendCooldown}s"
                    : _isResendingOtp
                        ? "Sending..."
                        : "Resend Code",
                style: TextStyle(
                  color: _resendCooldown > 0 ? context.textSecondary : ClassicTheme.primaryAccent,
                  fontWeight: FontWeight.w700,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
