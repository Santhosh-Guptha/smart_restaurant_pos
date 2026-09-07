import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../providers/saas_session_provider.dart';
import '../../providers/auth_provider.dart';
import '../../core/constants.dart';
import '../../utils/ui_feedback.dart';
import '../../services/smtp_email_service.dart';

class SaaSExpiredScreen extends ConsumerStatefulWidget {
  const SaaSExpiredScreen({super.key});

  @override
  ConsumerState<SaaSExpiredScreen> createState() => _SaaSExpiredScreenState();
}

class _SaaSExpiredScreenState extends ConsumerState<SaaSExpiredScreen> {
  bool _isRequesting = false;
  bool _requestSent = false;

  Future<void> _requestRenewal(String orgId, String orgName, String planTier) async {
    setState(() => _isRequesting = true);
    try {
      final now = FieldValue.serverTimestamp();
      final firestore = FirebaseFirestore.instance;

      // 1. Create or update renewal request
      await firestore.collection('renewal_requests').doc(orgId).set({
        'organizationId': orgId,
        'organizationName': orgName,
        'previousPlanTier': planTier,
        'requestedAt': now,
        'status': 'PENDING',
        'contactEmail': kAdminEmail,
      }, SetOptions(merge: true));

      // 2. Write high-priority audit log for Master Admin
      await firestore.collection('audit_logs').add({
        'actionType': 'RENEWAL_REQUEST',
        'organizationId': orgId,
        'organizationName': orgName,
        'details': 'Organization $orgName ($orgId) requested license renewal after plan/trial expiry.',
        'timestamp': now,
        'priority': 'HIGH',
      });

      // 3. Dispatch automated SMTP alert email to Master Admin
      try {
        final clientUser = ref.read(saasSessionProvider).currentUser;
        SmtpEmailService.sendRenewalRequestAlertEmail(
          orgId: orgId,
          orgName: orgName,
          planTier: planTier,
          clientEmail: clientUser?.email,
          clientPhone: clientUser?.phone,
        );
      } catch (_) {}

      setState(() {
        _isRequesting = false;
        _requestSent = true;
      });

      if (mounted) {
        AppToast.showSuccess(
          context,
          "Renewal Request Sent",
          subtitle: "Master Administrator has been notified. Services will resume immediately upon approval.",
        );
      }
    } catch (e) {
      setState(() => _isRequesting = false);
      if (mounted) {
        AppToast.showError(context, "Could not send request: $e");
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(saasSessionProvider);
    final orgName = session.currentOrganization?.name ?? 'Restaurant';
    final orgId = session.currentOrganization?.id ?? 'N/A';
    final license = session.currentLicense;
    final isTrial = license?.planTier.toUpperCase() == 'TRIAL';

    final title = isTrial ? "Free Trial Completed" : "Subscription Inactive";
    final expiryMsg = isTrial
        ? "Your complimentary trial period for $orgName has concluded. All dining records, menu configurations, and branch settings are safely preserved. Request a license renewal to continue seamless operations."
        : (license?.status == 'SUSPENDED'
            ? "Your restaurant's subscription has been suspended by the administrator. Please contact support to reactivate your services."
            : "Your organization's subscription license has expired. Please renew your plan to continue point-of-sale and kitchen operations.");

    return Scaffold(
      backgroundColor: const Color(0xFF0F172A),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24.0),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Card(
              color: const Color(0xFF1E293B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
              elevation: 16,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28.0, vertical: 36.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: (isTrial ? Colors.orangeAccent : Colors.redAccent).withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        isTrial ? Icons.hourglass_bottom_rounded : Icons.lock_outline_rounded,
                        color: isTrial ? Colors.orangeAccent : Colors.redAccent,
                        size: 52,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      title,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      expiryMsg,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.45),
                    ),
                    const SizedBox(height: 20),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.white10),
                      ),
                      child: Column(
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Organization ID", style: TextStyle(color: Colors.white60, fontSize: 12)),
                              Text(orgId, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Brand Name", style: TextStyle(color: Colors.white60, fontSize: 12)),
                              Text(orgName, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("Plan Tier", style: TextStyle(color: Colors.white60, fontSize: 12)),
                              Text(license?.planTier ?? 'TRIAL', style: TextStyle(color: isTrial ? Colors.orangeAccent : Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 24),
                    if (_requestSent)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        margin: const EdgeInsets.only(bottom: 12),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: Colors.green),
                        ),
                        child: const Row(
                          children: [
                            Icon(Icons.check_circle_outline, color: Colors.green, size: 20),
                            SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                "Renewal requested. Terminal will resume automatically when approved.",
                                style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        height: 48,
                        child: ElevatedButton.icon(
                          onPressed: _isRequesting ? null : () => _requestRenewal(orgId, orgName, license?.planTier ?? 'TRIAL'),
                          icon: _isRequesting
                              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.send_rounded, size: 18),
                          label: Text(
                            _isRequesting ? "Sending Request..." : "Request License Renewal",
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF2563EB),
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                        ),
                      ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore(),
                            icon: const Icon(Icons.refresh_rounded, size: 16),
                            label: const Text("Check Status", style: TextStyle(fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white24),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => ref.read(authProvider.notifier).signOut(),
                            icon: const Icon(Icons.logout_rounded, size: 16, color: Colors.redAccent),
                            label: const Text("Sign Out", style: TextStyle(color: Colors.redAccent, fontSize: 12)),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: Colors.redAccent,
                              side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.4)),
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
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
      ),
    );
  }
}
