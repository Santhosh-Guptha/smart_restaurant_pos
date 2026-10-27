import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../services/password_reset_service.dart';
import '../../utils/ui_feedback.dart';
import 'saas_login_screen.dart';

/// Password Reset Screen with mandatory Google Account Identity Verification.
///
/// Ensures only the legitimate owner of the registered Google email address
/// can reset the password for the account.
class PasswordResetScreen extends StatefulWidget {
  final String? token;
  final String? email;

  const PasswordResetScreen({
    super.key,
    this.token,
    this.email,
  });

  @override
  State<PasswordResetScreen> createState() => _PasswordResetScreenState();
}

class _PasswordResetScreenState extends State<PasswordResetScreen> {
  final _tokenController = TextEditingController();
  final _emailController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isCheckingToken = false;
  bool _isTokenValid = false;
  String? _tokenError;

  // Google Identity Verification State
  bool _isVerifyingGoogle = false;
  bool _isGoogleVerified = false;
  String? _googleVerifiedEmail;
  String? _googleVerificationError;

  // Password submission state
  bool _isSubmitting = false;
  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isSuccess = false;

  final GoogleSignIn _googleSignIn = GoogleSignIn(
    clientId: kIsWeb ? kGoogleClientId : null,
    serverClientId: kGoogleClientId,
    scopes: const ['email'],
  );

  @override
  void initState() {
    super.initState();
    String? initialToken = widget.token;
    String? initialEmail = widget.email;

    // On Web, check query parameters if not passed directly
    if (kIsWeb && (initialToken == null || initialToken.isEmpty)) {
      try {
        final uri = Uri.base;
        if (uri.queryParameters.containsKey('token')) {
          initialToken = uri.queryParameters['token'];
        }
        if (uri.queryParameters.containsKey('email')) {
          initialEmail = uri.queryParameters['email'];
        }
        // Also inspect URI fragment (e.g. #/reset-password?token=...)
        if (uri.hasFragment && uri.fragment.contains('token=')) {
          final fragUri = Uri.parse(uri.fragment.startsWith('/') ? uri.fragment : '/${uri.fragment}');
          if (fragUri.queryParameters.containsKey('token')) {
            initialToken = fragUri.queryParameters['token'];
          }
          if (fragUri.queryParameters.containsKey('email')) {
            initialEmail = fragUri.queryParameters['email'];
          }
        }
      } catch (_) {}
    }

    if (initialToken != null && initialToken.isNotEmpty) {
      _tokenController.text = initialToken;
    }
    if (initialEmail != null && initialEmail.isNotEmpty) {
      _emailController.text = initialEmail;
    }

    if (_tokenController.text.isNotEmpty) {
      _validateToken();
    }
  }

  @override
  void dispose() {
    _tokenController.dispose();
    _emailController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _validateToken() async {
    final token = _tokenController.text.trim();
    final email = _emailController.text.trim();
    if (token.isEmpty) {
      setState(() {
        _tokenError = "Please enter your security reset token.";
        _isTokenValid = false;
      });
      return;
    }

    setState(() {
      _isCheckingToken = true;
      _tokenError = null;
    });

    final res = await PasswordResetService.verifyResetToken(
      token: token,
      email: email.isNotEmpty ? email : null,
    );

    if (!mounted) return;

    setState(() {
      _isCheckingToken = false;
      if (res['valid'] == true) {
        _isTokenValid = true;
        final data = res['data'] as Map<String, dynamic>;
        if (_emailController.text.isEmpty && data['email'] != null) {
          _emailController.text = data['email'];
        }
      } else {
        _isTokenValid = false;
        _tokenError = res['error'] ?? "Invalid or expired reset token.";
      }
    });
  }

  Future<void> _handleGoogleVerification() async {
    final targetEmail = _emailController.text.trim().toLowerCase();
    if (targetEmail.isEmpty) {
      setState(() {
        _googleVerificationError = "Target email address is missing.";
      });
      return;
    }

    setState(() {
      _isVerifyingGoogle = true;
      _googleVerificationError = null;
    });

    try {
      if (await _googleSignIn.isSignedIn()) {
        await _googleSignIn.signOut();
      }

      final account = await _googleSignIn.signIn();

      if (!mounted) return;

      if (account == null) {
        // User cancelled popup
        setState(() {
          _isVerifyingGoogle = false;
          _googleVerificationError = "Google verification was cancelled.";
        });
        return;
      }

      final authedEmail = account.email.trim().toLowerCase();

      if (authedEmail == targetEmail) {
        setState(() {
          _isVerifyingGoogle = false;
          _isGoogleVerified = true;
          _googleVerifiedEmail = account.email;
          _googleVerificationError = null;
        });
        AppToast.showSuccess(
          context,
          "Identity confirmed with Google ($authedEmail)",
          subtitle: "Identity Verification Successful",
        );
      } else {
        await _googleSignIn.signOut();
        setState(() {
          _isVerifyingGoogle = false;
          _isGoogleVerified = false;
          _googleVerificationError =
              "Identity mismatch: You signed in as '$authedEmail', but this account requires '$targetEmail'. Please sign in with the matching Google account.";
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isVerifyingGoogle = false;
        _isGoogleVerified = false;
        _googleVerificationError = "Google authentication failed: $e";
      });
    }
  }

  Future<void> _handleSubmitNewPassword() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isGoogleVerified || _googleVerifiedEmail == null) {
      AppToast.showError(
        context,
        "Please complete Google identity verification before setting a new password.",
        title: "Verification Required",
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    final res = await PasswordResetService.completePasswordReset(
      token: _tokenController.text.trim(),
      email: _emailController.text.trim(),
      newPassword: _newPasswordController.text.trim(),
      googleVerifiedEmail: _googleVerifiedEmail!,
    );

    if (!mounted) return;

    setState(() {
      _isSubmitting = false;
    });

    if (res['success'] == true) {
      setState(() {
        _isSuccess = true;
      });
      AppToast.showSuccess(
        context,
        "Password has been reset successfully. Please log in with your new password.",
        subtitle: "Password Updated",
      );
    } else {
      AppToast.showError(
        context,
        res['error'] ?? "Failed to update password.",
        title: "Reset Failed",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.arrow_back_rounded, color: context.textPrimary),
          onPressed: () {
            if (Navigator.canPop(context)) {
              Navigator.pop(context);
            } else {
              Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const SaaSLoginScreen()));
            }
          },
        ),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: _isSuccess ? _buildSuccessView(context) : _buildMainCard(context),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainCard(BuildContext context) {
    final targetEmail = _emailController.text.trim();

    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.borderColor),
        boxShadow: ClassicTheme.cardShadow(context.isDark),
      ),
      padding: const EdgeInsets.all(28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Center(
            child: Column(
              children: [
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(Icons.password_rounded, color: ClassicTheme.primaryAccentIndigo, size: 30),
                ),
                const SizedBox(height: 14),
                Text(
                  "Password Recovery",
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary,
                    letterSpacing: -0.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  "Verify your Google identity to set a new password",
                  style: TextStyle(fontSize: 13, color: context.textSecondary),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // Token Verification Card (if not validated yet)
          if (!_isTokenValid) ...[
            Text(
              "Security Reset Token",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _tokenController,
              style: TextStyle(color: context.textPrimary, fontSize: 13.5, fontFamily: 'monospace'),
              decoration: ClassicTheme.inputDecorationFor(
                context,
                hintText: "Enter 32-character token from email",
                prefixIcon: Icon(Icons.key_rounded, color: context.textSecondary, size: 20),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              "Registered Email Address",
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary),
            ),
            const SizedBox(height: 6),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              style: TextStyle(color: context.textPrimary, fontSize: 13.5),
              decoration: ClassicTheme.inputDecorationFor(
                context,
                hintText: "e.g. owner@store.com",
                prefixIcon: Icon(Icons.email_outlined, color: context.textSecondary, size: 20),
              ),
            ),
            const SizedBox(height: 16),
            if (_tokenError != null) ...[
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: ClassicTheme.dangerRed.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline_rounded, color: ClassicTheme.dangerRed, size: 16),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _tokenError!,
                        style: const TextStyle(fontSize: 12, color: ClassicTheme.dangerRed, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccentIndigo,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: _isCheckingToken
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check_circle_outline_rounded, size: 16),
                label: Text(_isCheckingToken ? "Verifying Token..." : "Validate Token"),
                onPressed: _isCheckingToken ? null : _validateToken,
              ),
            ),
          ] else ...[
            // Account info banner
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.25)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.account_circle_outlined, color: ClassicTheme.infoBlue, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          "Account to Reset",
                          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold, color: ClassicTheme.infoBlue),
                        ),
                        Text(
                          targetEmail,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
                        ),
                      ],
                    ),
                  ),
                  const Icon(Icons.verified_rounded, color: ClassicTheme.successEmerald, size: 18),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Step 1: Google Identity Verification
            Text(
              "Step 1: Google Identity Verification",
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: context.textPrimary),
            ),
            const SizedBox(height: 6),
            Text(
              "Sign in with your registered Google account to prove ownership of $targetEmail.",
              style: TextStyle(fontSize: 12, color: context.textSecondary),
            ),
            const SizedBox(height: 12),

            if (_isGoogleVerified)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: ClassicTheme.successEmerald.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ClassicTheme.successEmerald.withValues(alpha: 0.3)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.check_circle_rounded, color: ClassicTheme.successEmerald, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            "Identity Confirmed via Google",
                            style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: ClassicTheme.successEmerald),
                          ),
                          Text(
                            _googleVerifiedEmail ?? targetEmail,
                            style: TextStyle(fontSize: 11.5, color: context.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              )
            else ...[
              if (_googleVerificationError != null) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: ClassicTheme.dangerRed.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_amber_rounded, color: ClassicTheme.dangerRed, size: 16),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _googleVerificationError!,
                          style: const TextStyle(fontSize: 11.5, color: ClassicTheme.dangerRed, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              SizedBox(
                width: double.infinity,
                height: 46,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    backgroundColor: context.surfaceColor,
                    foregroundColor: context.textPrimary,
                    side: BorderSide(color: context.borderColor),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  onPressed: _isVerifyingGoogle ? null : _handleGoogleVerification,
                  child: _isVerifyingGoogle
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              width: 22,
                              height: 22,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white,
                              ),
                              alignment: Alignment.center,
                              child: const Text("G", style: TextStyle(color: Colors.red, fontWeight: FontWeight.w900, fontSize: 14)),
                            ),
                            const SizedBox(width: 10),
                            const Text(
                              "Sign in with Google to Verify",
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                ),
              ),
            ],

            const SizedBox(height: 24),
            Divider(color: context.borderColor, height: 1),
            const SizedBox(height: 20),

            // Step 2: Set New Password Form
            Text(
              "Step 2: Set New Password",
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.bold,
                color: _isGoogleVerified ? context.textPrimary : context.textSecondary.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _isGoogleVerified
                  ? "Choose a strong password (minimum 6 characters)."
                  : "Complete Google verification above to unlock password fields.",
              style: TextStyle(fontSize: 12, color: context.textSecondary),
            ),
            const SizedBox(height: 14),

            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "New Password",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isGoogleVerified ? context.textSecondary : context.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _newPasswordController,
                    enabled: _isGoogleVerified,
                    obscureText: _obscureNew,
                    style: TextStyle(color: context.textPrimary, fontSize: 14),
                    decoration: ClassicTheme.inputDecorationFor(
                      context,
                      hintText: "Enter new password",
                      prefixIcon: Icon(Icons.lock_outline, color: context.textSecondary, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureNew ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: context.textSecondary, size: 20),
                        onPressed: () => setState(() => _obscureNew = !_obscureNew),
                      ),
                    ),
                    validator: (v) {
                      if (!_isGoogleVerified) return null;
                      if (v == null || v.trim().length < 6) {
                        return "Password must be at least 6 characters.";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 14),
                  Text(
                    "Confirm New Password",
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: _isGoogleVerified ? context.textSecondary : context.textSecondary.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 6),
                  TextFormField(
                    controller: _confirmPasswordController,
                    enabled: _isGoogleVerified,
                    obscureText: _obscureConfirm,
                    style: TextStyle(color: context.textPrimary, fontSize: 14),
                    decoration: ClassicTheme.inputDecorationFor(
                      context,
                      hintText: "Re-enter new password",
                      prefixIcon: Icon(Icons.lock_reset_rounded, color: context.textSecondary, size: 20),
                      suffixIcon: IconButton(
                        icon: Icon(_obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined, color: context.textSecondary, size: 20),
                        onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                      ),
                    ),
                    validator: (v) {
                      if (!_isGoogleVerified) return null;
                      if (v != _newPasswordController.text) {
                        return "Passwords do not match.";
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 22),

                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _isGoogleVerified ? ClassicTheme.primaryAccentIndigo : context.borderColor,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                      ),
                      onPressed: (_isGoogleVerified && !_isSubmitting) ? _handleSubmitNewPassword : null,
                      icon: _isSubmitting
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.save_rounded, size: 18),
                      label: Text(
                        _isSubmitting ? "Updating Password..." : "Save Password & Sign In",
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSuccessView(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: context.borderColor),
        boxShadow: ClassicTheme.cardShadow(context.isDark),
      ),
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.check_circle_rounded, color: ClassicTheme.successEmerald, size: 36),
          ),
          const SizedBox(height: 20),
          Text(
            "Password Reset Complete!",
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: context.textPrimary,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "Your password has been securely updated. You can now log into SmartBizz POS using your new password.",
            style: TextStyle(fontSize: 13.5, color: context.textSecondary, height: 1.45),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 28),
          SizedBox(
            width: double.infinity,
            height: 46,
            child: ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccentIndigo,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              icon: const Icon(Icons.login_rounded, size: 18),
              label: const Text("Go to Sign In", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
              onPressed: () {
                Navigator.pushAndRemoveUntil(
                  context,
                  MaterialPageRoute(builder: (_) => const SaaSLoginScreen()),
                  (route) => false,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
