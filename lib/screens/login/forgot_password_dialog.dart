import 'package:flutter/material.dart';
import '../../core/classic_theme.dart';
import '../../services/password_reset_service.dart';
import '../../utils/ui_feedback.dart';
import 'password_reset_screen.dart';

/// Modal dialog for requesting a password reset.
///
/// Validates if the user is registered in the database.
/// If not registered, alerts the user and does NOT dispatch an email.
class ForgotPasswordDialog extends StatefulWidget {
  final String? initialEmail;

  const ForgotPasswordDialog({super.key, this.initialEmail});

  static Future<void> show(BuildContext context, {String? initialEmail}) {
    return showDialog(
      context: context,
      builder: (_) => ForgotPasswordDialog(initialEmail: initialEmail),
    );
  }

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _controller = TextEditingController();

  bool _isLoading = false;
  String? _errorMessage;
  PasswordResetResult? _successResult;

  @override
  void initState() {
    super.initState();
    if (widget.initialEmail != null && widget.initialEmail!.isNotEmpty) {
      _controller.text = widget.initialEmail!;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final result = await PasswordResetService.requestPasswordReset(_controller.text.trim());

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (result.success) {
        _successResult = result;
      } else {
        _errorMessage = result.errorMessage ?? "User not registered or an error occurred.";
      }
    });

    if (result.success) {
      AppToast.showSuccess(
        context,
        "Reset link sent to ${result.email}",
        subtitle: "Check your inbox and spam folder",
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: context.surfaceColor,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 440),
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: _successResult != null ? _buildSuccessView(context) : _buildRequestView(context),
        ),
      ),
    );
  }

  Widget _buildRequestView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: ClassicTheme.primaryAccentIndigo.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.lock_reset_rounded, color: ClassicTheme.primaryAccentIndigo, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "Forgot Password?",
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    "Enter your registered account email",
                    style: TextStyle(fontSize: 12.5, color: context.textSecondary),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: Icon(Icons.close_rounded, color: context.textSecondary, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 18),
        Text(
          "We will verify your email in our database and send a secure password reset link. Identity verification with Google is required on the reset screen.",
          style: TextStyle(fontSize: 13, color: context.textSecondary, height: 1.45),
        ),
        const SizedBox(height: 18),

        if (_errorMessage != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: ClassicTheme.dangerRed.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.error_outline_rounded, color: ClassicTheme.dangerRed, size: 18),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _errorMessage!,
                    style: const TextStyle(fontSize: 12.5, color: ClassicTheme.dangerRed, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],

        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Registered Email or Username",
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: context.textSecondary),
              ),
              const SizedBox(height: 6),
              TextFormField(
                controller: _controller,
                keyboardType: TextInputType.emailAddress,
                style: TextStyle(color: context.textPrimary, fontSize: 14),
                decoration: ClassicTheme.inputDecorationFor(
                  context,
                  hintText: "e.g. owner@store.com",
                  prefixIcon: Icon(Icons.email_outlined, color: context.textSecondary, size: 20),
                ),
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return "Email or username is required.";
                  return null;
                },
                onFieldSubmitted: (_) => _handleSubmit(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),

        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _isLoading ? null : () => Navigator.pop(context),
              child: Text("Cancel", style: TextStyle(color: context.textSecondary)),
            ),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(
                backgroundColor: ClassicTheme.primaryAccentIndigo,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
              onPressed: _isLoading ? null : _handleSubmit,
              icon: _isLoading
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.send_rounded, size: 16),
              label: Text(_isLoading ? "Verifying..." : "Send Reset Link"),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildSuccessView(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: ClassicTheme.successEmerald.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.mark_email_read_rounded, color: ClassicTheme.successEmerald, size: 32),
        ),
        const SizedBox(height: 16),
        Text(
          "Reset Link Dispatched!",
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: context.textPrimary),
        ),
        const SizedBox(height: 8),
        Text(
          "We sent a password reset link to ${_successResult?.email}. Please check your inbox and spam folder.",
          style: TextStyle(fontSize: 13, color: context.textSecondary, height: 1.45),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ClassicTheme.infoBlue.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ClassicTheme.infoBlue.withValues(alpha: 0.25)),
          ),
          child: Row(
            children: [
              const Icon(Icons.verified_user_rounded, color: ClassicTheme.infoBlue, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  "On the reset screen, you will sign in with your Google account to confirm identity.",
                  style: TextStyle(fontSize: 12, color: context.textPrimary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => Navigator.pop(context),
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text("Close"),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccentIndigo,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                ),
                icon: const Icon(Icons.open_in_browser_rounded, size: 16),
                label: const Text("Reset Now"),
                onPressed: () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => PasswordResetScreen(
                        token: _successResult?.token,
                        email: _successResult?.email,
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ],
    );
  }
}
