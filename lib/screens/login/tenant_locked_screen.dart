import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/design_tokens.dart';
import '../../core/responsive.dart';
import '../../providers/saas_session_provider.dart';
import '../counter_billing/fast_qsr_billing_screen.dart';

/// Shown when the platform admin has paused or closed the store.
///
/// The organisation listener already pushes `status` changes to every signed-in
/// device, so this appears within seconds of the admin acting — no polling, no
/// webhook call, no sign-out required.
///
/// Rule 7: **the till stays reachable.** A restaurant mid-service does not stop
/// billing because an invoice is unpaid; the rest of the app is withheld, the
/// bills queue locally, and everything is there when access returns.
class TenantLockedScreen extends ConsumerStatefulWidget {
  const TenantLockedScreen({super.key});

  @override
  ConsumerState<TenantLockedScreen> createState() => _TenantLockedScreenState();
}

class _TenantLockedScreenState extends ConsumerState<TenantLockedScreen> {
  bool _busy = false;

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(saasSessionProvider);
    final org = session.currentOrganization;
    final closed = org?.isDeleted == true;
    final reason = org?.statusReason?.trim() ?? '';
    final gutter = Responsive.gutter(context);
    final accent = closed ? ClassicTheme.dangerRed : ClassicTheme.warningAmber;

    return Scaffold(
      backgroundColor: context.canvasColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: Responsive.isTablet(context) ? 560 : double.infinity,
            ),
            child: ListView(
              padding: EdgeInsets.all(gutter),
              shrinkWrap: true,
              children: [
                Container(
                  padding: const EdgeInsets.all(DS.space5),
                  decoration: BoxDecoration(
                    color: context.surfaceColor,
                    borderRadius: BorderRadius.circular(DS.radiusXl),
                    border: Border.all(color: context.borderColor),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(DS.space3),
                        decoration: BoxDecoration(
                          color: accent.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(DS.radiusMd),
                        ),
                        child: Icon(
                          closed ? Icons.lock_outline_rounded : Icons.pause_circle_outline_rounded,
                          color: accent,
                          size: 28,
                        ),
                      ),
                      const SizedBox(height: DS.space4),
                      Text(
                        closed ? 'This store is closed' : 'Access is paused',
                        style: TextStyle(
                          fontSize: DS.fontHeadline,
                          fontWeight: FontWeight.w800,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: DS.space2),
                      Text(
                        closed
                            ? 'Your platform administrator has closed this store. '
                                'Your bills stay on this device and can still be '
                                'exported from Settings.'
                            : 'Your platform administrator has paused access to '
                                'this store. Everything you have billed is safe on '
                                'this device and will sync when access returns.',
                        style: TextStyle(
                          fontSize: DS.fontBody,
                          height: 1.55,
                          color: context.textSecondary,
                        ),
                      ),
                      if (reason.isNotEmpty) ...[
                        const SizedBox(height: DS.space4),
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.all(DS.space3),
                          decoration: BoxDecoration(
                            color: context.sunkenSurface,
                            borderRadius: BorderRadius.circular(DS.radiusMd),
                            border: Border.all(color: context.borderColor),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('REASON GIVEN',
                                  style: TextStyle(
                                    fontSize: DS.fontMicro,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.6,
                                    color: context.textSecondary,
                                  )),
                              const SizedBox(height: 4),
                              Text(reason,
                                  style: TextStyle(
                                      fontSize: DS.fontCaption,
                                      color: context.textPrimary,
                                      height: 1.45)),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: DS.space5),

                      // Rule 7. A paused account is a commercial matter; a
                      // restaurant with guests in it is not.
                      SizedBox(
                        height: DS.tapTargetComfortable,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ClassicTheme.primaryAccent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(DS.radiusMd)),
                          ),
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()),
                          ),
                          icon: const Icon(Icons.point_of_sale_rounded),
                          label: const Text('Keep billing',
                              style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: DS.space3),
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy ? null : _refresh,
                              icon: _busy
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(strokeWidth: 2))
                                  : const Icon(Icons.refresh_rounded, size: 18),
                              label: const Text('Check again'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(DS.tapTargetMin),
                                side: BorderSide(color: context.borderColor),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(DS.radiusMd)),
                              ),
                            ),
                          ),
                          const SizedBox(width: DS.space2),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () =>
                                      ref.read(saasSessionProvider.notifier).clearSession(),
                              icon: const Icon(Icons.logout_rounded, size: 18),
                              label: const Text('Sign out'),
                              style: OutlinedButton.styleFrom(
                                minimumSize: const Size.fromHeight(DS.tapTargetMin),
                                side: BorderSide(color: context.borderColor),
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(DS.radiusMd)),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: DS.space4),
                      Row(
                        children: [
                          Icon(Icons.mail_outline_rounded, size: 16, color: context.textSecondary),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              kAdminEmail,
                              style: TextStyle(
                                fontSize: DS.fontCaption,
                                fontWeight: FontWeight.w600,
                                color: context.textPrimary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
