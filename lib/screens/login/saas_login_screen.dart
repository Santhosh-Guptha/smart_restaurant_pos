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

  bool _isLoggingIn = false;
  bool _obscurePassword = true;
  bool _rememberMe = false;
  String? _errorMessage;

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
    super.dispose();
  }

  Future<void> _handleLogin() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoggingIn = true;
      _errorMessage = null;
    });

    final error = await ref.read(authProvider.notifier).loginSaaS(
          _emailController.text.trim(),
          _passwordController.text,
          rememberMe: _rememberMe,
        );

    if (mounted) {
      setState(() {
        _isLoggingIn = false;
        if (error != null) {
          _errorMessage = error;
          AppToast.showError(context, error, title: "Login Failed");
        }
      });
    }
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
                    child: const Icon(
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
                    child: Column(
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

                  // Client Self-Registration Link
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
}
