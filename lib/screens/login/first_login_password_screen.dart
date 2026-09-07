import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:bcrypt/bcrypt.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../core/classic_theme.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/theme_provider.dart';
import '../../utils/ui_feedback.dart';

class FirstLoginPasswordScreen extends ConsumerStatefulWidget {
  const FirstLoginPasswordScreen({super.key});

  @override
  ConsumerState<FirstLoginPasswordScreen> createState() => _FirstLoginPasswordScreenState();
}

class _FirstLoginPasswordScreenState extends ConsumerState<FirstLoginPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _obscureNew = true;
  bool _obscureConfirm = true;
  bool _isSaving = false;

  @override
  void dispose() {
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> _handleSavePassword() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSaving = true);

    try {
      final session = ref.read(saasSessionProvider);
      final user = session.currentUser;

      if (user == null) {
        throw Exception("User session not found. Please log in again.");
      }

      final newPassword = _newPasswordController.text.trim();
      final newHash = BCrypt.hashpw(newPassword, BCrypt.gensalt());

      // 1. Update Firestore users doc
      await FirebaseFirestore.instance.collection('users').doc(user.id).update({
        'passwordHash': newHash,
        'mustChangePassword': false,
        'passwordChangedAt': FieldValue.serverTimestamp(),
      });

      // 2. Update local Hive cache
      final box = Hive.box('configBox');
      final emailKey = user.email.trim().toLowerCase();
      await box.put('saas_password_hash_$emailKey', newHash);

      // 3. Refresh user session in state
      await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();

      if (mounted) {
        setState(() => _isSaving = false);
        AppToast.showSuccess(
          context,
          "Password Updated Successfully",
          subtitle: "Welcome to your store dashboard!",
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSaving = false);
        AppToast.showError(context, e.toString(), title: "Password Update Failed");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(saasSessionProvider);
    final user = session.currentUser;
    final org = session.currentOrganization;
    final primaryAccent = context.isDark ? const Color(0xFF60A5FA) : const Color(0xFF2563EB);

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(
          "Account Setup",
          style: TextStyle(color: context.textPrimary, fontWeight: FontWeight.bold, fontSize: 16),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout_rounded, color: ClassicTheme.dangerRed),
            tooltip: "Log Out",
            onPressed: () => ref.read(saasSessionProvider.notifier).clearSession(),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24.0, vertical: 16.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Form(
                key: _formKey,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Security Icon
                    Center(
                      child: Container(
                        width: 70,
                        height: 70,
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981).withOpacity(0.12),
                          shape: BoxShape.circle,
                          border: Border.all(color: const Color(0xFF10B981).withOpacity(0.3), width: 2),
                        ),
                        child: const Icon(Icons.lock_reset_rounded, size: 38, color: Color(0xFF10B981)),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Title & Instructions
                    Text(
                      "Set Your Permanent Password",
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                        color: context.textPrimary,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      "Welcome to Smart POS! For your account security, please create your own new password to replace the temporary default password.",
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 13, color: context.textSecondary, height: 1.4),
                    ),
                    const SizedBox(height: 24),

                    // Store / Account Info Badge
                    if (user != null) ...[
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: context.surfaceColor,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: context.borderColor),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.storefront_rounded, size: 18, color: primaryAccent),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    org?.name ?? "Store Account",
                                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: context.textPrimary),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              "Login Email: ${user.email}",
                              style: TextStyle(fontSize: 12, color: context.textSecondary),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 20),
                    ],

                    // New Password Input
                    Text("NEW PASSWORD", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _newPasswordController,
                      obscureText: _obscureNew,
                      style: TextStyle(color: context.textPrimary),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "Enter new password (min 6 chars)",
                        prefixIcon: const Icon(Icons.lock_outline_rounded),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureNew ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, color: context.textSecondary),
                          onPressed: () => setState(() => _obscureNew = !_obscureNew),
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) return "Please enter a new password.";
                        if (val.trim().length < 6) return "Password must be at least 6 characters.";
                        return null;
                      },
                    ),
                    const SizedBox(height: 18),

                    // Confirm Password Input
                    Text("CONFIRM NEW PASSWORD", style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: context.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 6),
                    TextFormField(
                      controller: _confirmPasswordController,
                      obscureText: _obscureConfirm,
                      style: TextStyle(color: context.textPrimary),
                      decoration: ClassicTheme.inputDecorationFor(
                        context,
                        hintText: "Re-enter new password",
                        prefixIcon: const Icon(Icons.shield_outlined),
                        suffixIcon: IconButton(
                          icon: Icon(_obscureConfirm ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 20, color: context.textSecondary),
                          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                        ),
                      ),
                      validator: (val) {
                        if (val == null || val.trim().isEmpty) return "Please confirm your new password.";
                        if (val.trim() != _newPasswordController.text.trim()) return "Passwords do not match.";
                        return null;
                      },
                    ),
                    const SizedBox(height: 28),

                    // Submit Button
                    SizedBox(
                      height: 50,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _handleSavePassword,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF10B981),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        ),
                        child: _isSaving
                            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
                            : const Text("Save Password & Enter Dashboard", style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
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
