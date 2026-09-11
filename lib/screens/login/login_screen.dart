import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';

// --- PREMIUM LOGIN SCREEN ---
// Displayed when the store operator is not authenticated.
// Provides sleek glassmorphism visuals, smooth transitions, and multi-channel login.
// Auto-resolves standard Google sign-in anomalies to fallback seamlessly to local mode.

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  bool _isLoading = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: Navigator.canPop(context)
            ? const BackButton(color: Colors.white)
            : null,
      ),
      extendBodyBehindAppBar: true,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0F172A), Color(0xFF1E3A8A), Color(0xFF1E1B4B)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Center(
          child: SingleChildScrollView(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(40),
              constraints: const BoxConstraints(maxWidth: 450),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.09),
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: Colors.white.withValues(alpha: 0.15), width: 1.5),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 25,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Brand Icon with glowing background
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.4), width: 1.5),
                    ),
                    child: const Icon(
                      Icons.storefront,
                      size: 68,
                      color: Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 24),

                  // Brand name
                  const Text(
                    'Smart Billing System',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Subtitle
                  Text(
                    'Unified store ledger, offline inventory & real-time cloud synchronization',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.7),
                      fontSize: 13,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 36),

                  if (_isLoading) ...[
                    const SizedBox(
                      height: 50,
                      width: 50,
                      child: CircularProgressIndicator(
                        strokeWidth: 3,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.orange),
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Securing cloud connection...',
                      style: TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                  ] else ...[
                    // Primary Cloud Sign In button
                    ElevatedButton.icon(
                      key: const Key('btn_google_signin'),
                      onPressed: _handleGoogleSignIn,
                      icon: const Icon(Icons.cloud_sync, size: 22),
                      label: const Text('Connect Google Cloud'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.orange,
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 52),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        elevation: 4,
                        shadowColor: Colors.orange.withValues(alpha: 0.4),
                        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Secondary Offline / local operator button
                    OutlinedButton.icon(
                      key: const Key('btn_offline_signin'),
                      onPressed: _handleOfflineSignIn,
                      icon: const Icon(Icons.wifi_off, size: 20),
                      label: const Text('Access Local Mode (Offline)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white70,
                        minimumSize: const Size(double.infinity, 50),
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
                        textStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],

                  const SizedBox(height: 24),
                  Divider(color: Colors.white.withValues(alpha: 0.1)),
                  const SizedBox(height: 12),

                  // Bottom info notice
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.shield_outlined, color: Colors.white.withValues(alpha: 0.4), size: 16),
                      const SizedBox(width: 8),
                      Text(
                        'Secure local sandbox protection',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.4),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _handleGoogleSignIn() async {
    setState(() => _isLoading = true);
    // Explicit delay for visual transition and instant user response
    await Future.delayed(const Duration(milliseconds: 400));
    try {
      await ref.read(authProvider.notifier).signIn();
    } catch (e) {
      debugPrint("Authentication flow failure: $e");
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleOfflineSignIn() async {
    // Show disclaimer modal before entering local mode
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1E293B),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 28),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'Local Mode — Important Disclaimer',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '⚠️ NO CLOUD BACKUP',
                    style: TextStyle(
                      color: Colors.amber,
                      fontWeight: FontWeight.bold,
                      fontSize: 13,
                    ),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'In Local Mode, all your data (products, bills, customers, expenses) is stored ONLY on this device.',
                    style: TextStyle(color: Colors.white70, fontSize: 12, height: 1.5),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'By continuing, you acknowledge that:',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 12),
            ),
            const SizedBox(height: 10),
            _buildDisclaimerPoint(Icons.cloud_off, 'No data will be synced to the cloud.'),
            const SizedBox(height: 6),
            _buildDisclaimerPoint(Icons.delete_forever, 'Uninstalling the app or clearing data will permanently delete everything.'),
            const SizedBox(height: 6),
            _buildDisclaimerPoint(Icons.phone_android, 'Data cannot be transferred to another device.'),
            const SizedBox(height: 6),
            _buildDisclaimerPoint(Icons.restore, 'There is no recovery or backup mechanism.'),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('btn_offline_cancel'),
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600),
            ),
          ),
          ElevatedButton.icon(
            key: const Key('btn_offline_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            icon: const Icon(Icons.check_circle_outline, size: 18),
            label: const Text(
              'I Understand, Continue',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      setState(() => _isLoading = true);
      await ref.read(authProvider.notifier).signInOffline();
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildDisclaimerPoint(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Colors.white38, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(color: Colors.white60, fontSize: 11, height: 1.4),
          ),
        ),
      ],
    );
  }
}
