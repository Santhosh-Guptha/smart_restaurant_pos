import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/license_lease.dart';
import '../../core/responsive.dart';
import '../../providers/saas_session_provider.dart';

/// Shown when this device has gone too long without checking its licence
/// online, or its clock has been moved back (see [LicenseLease]).
///
/// Everything billed is still on the device. Connecting once — Wi-Fi or a
/// phone hotspot for a few seconds — renews the lease and the till reopens.
class LicenseRevalidateScreen extends ConsumerStatefulWidget {
  final LeaseCheck lease;
  const LicenseRevalidateScreen({super.key, required this.lease});

  @override
  ConsumerState<LicenseRevalidateScreen> createState() => _LicenseRevalidateScreenState();
}

class _LicenseRevalidateScreenState extends ConsumerState<LicenseRevalidateScreen> {
  bool _busy = false;
  String? _result;

  Future<void> _check() async {
    setState(() {
      _busy = true;
      _result = null;
    });
    await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();
    if (!mounted) return;
    final org = ref.read(saasSessionProvider).currentOrganization;
    final now = LicenseLease.check(orgId: org?.id ?? '', storageMode: org?.storageMode);
    setState(() {
      _busy = false;
      _result = now.blocked
          ? 'Still could not reach the licence server. Check the internet connection and try again.'
          : null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final rolledBack = widget.lease.state == LeaseState.clockRolledBack;
    final gutter = Responsive.gutter(context);
    final accent = rolledBack ? ClassicTheme.dangerRed : ClassicTheme.warningAmber;
    final last = widget.lease.validatedAt?.toLocal();
    final lastText = last == null
        ? ''
        : ' The last check was on ${last.day.toString().padLeft(2, '0')}/'
            '${last.month.toString().padLeft(2, '0')}/${last.year}.';

    return Scaffold(
      backgroundColor: context.canvasColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: Responsive.isTablet(context) ? 560 : double.infinity),
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
                        child: Icon(rolledBack ? Icons.schedule_rounded : Icons.wifi_rounded, color: accent, size: 28),
                      ),
                      const SizedBox(height: DS.space4),
                      Text(
                        rolledBack ? 'Check the date and time' : 'Connect once to continue',
                        style: TextStyle(fontSize: DS.fontHeadline, fontWeight: FontWeight.w800, color: context.textPrimary),
                      ),
                      const SizedBox(height: DS.space2),
                      Text(
                        rolledBack
                            ? 'This device\'s clock is earlier than a time it has already recorded. '
                                'Set the correct date and time, then connect to the internet once so the licence can be checked.'
                            : 'SmartBizz works without internet, but the licence has to be confirmed online at least '
                                'once every ${widget.lease.graceDays} days.$lastText Connect to Wi-Fi or a phone hotspot '
                                'for a few seconds and tap Check now. Your bills are safe on this device.',
                        style: TextStyle(fontSize: DS.fontBody, height: 1.55, color: context.textSecondary),
                      ),
                      if (_result != null) ...[
                        const SizedBox(height: DS.space3),
                        Text(_result!, style: const TextStyle(fontSize: DS.fontCaption, color: ClassicTheme.dangerRed)),
                      ],
                      const SizedBox(height: DS.space5),
                      SizedBox(
                        height: DS.tapTargetComfortable,
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: ClassicTheme.primaryAccent,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                          ),
                          onPressed: _busy ? null : _check,
                          icon: _busy
                              ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.refresh_rounded),
                          label: const Text('Check now', style: TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                      const SizedBox(height: DS.space3),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : () => ref.read(saasSessionProvider.notifier).clearSession(),
                        icon: const Icon(Icons.logout_rounded, size: 18),
                        label: const Text('Sign out'),
                        style: OutlinedButton.styleFrom(
                          minimumSize: const Size.fromHeight(DS.tapTargetMin),
                          side: BorderSide(color: context.borderColor),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
                        ),
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
