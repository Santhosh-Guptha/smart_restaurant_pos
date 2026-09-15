import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../core/classic_theme.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/responsive.dart';
import '../../providers/restaurant_auth_provider.dart';
import '../../providers/saas_session_provider.dart';
import '../../services/storage_migration_service.dart';
import '../counter_billing/fast_qsr_billing_screen.dart';

/// Shown instead of the home screen while the platform admin's storage-mode
/// request is pending.
///
/// The owner sees the four steps and a Start button; the run happens here, on
/// their device, and the mode flips only after the count check. Staff see a
/// short explanation and — rule 7 — a button that opens the till, because a
/// pending migration is never a reason a restaurant cannot bill.
class StorageMigrationGateScreen extends ConsumerStatefulWidget {
  const StorageMigrationGateScreen({super.key});

  @override
  ConsumerState<StorageMigrationGateScreen> createState() => _StorageMigrationGateScreenState();
}

class _StorageMigrationGateScreenState extends ConsumerState<StorageMigrationGateScreen> {
  String? _error;
  bool _busy = false;

  bool get _isOwner {
    final role = ref.read(saasSessionProvider).currentUser?.role.toUpperCase() ?? '';
    return role == 'OWNER' || role == 'CLIENT' || role == 'MASTER_ADMIN';
  }

  Future<http.Client?> _signIn() async {
    final auth = ref.read(restaurantAuthProvider.notifier);
    final existing = auth.authenticatedHttpClient;
    if (existing != null) return existing;
    final res = await auth.signInWithGoogle();
    if (res['success'] != true) return null;
    return auth.authenticatedHttpClient;
  }

  Future<void> _start() async {
    final session = ref.read(saasSessionProvider);
    final org = session.currentOrganization;
    if (org == null) return;
    final pending = org.pendingStorageChange;
    if (pending == null) return;

    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await StorageMigrationService.run(
      orgId: org.id,
      orgName: org.name.isNotEmpty ? org.name : org.appName,
      pending: pending,
      signIn: _signIn,
      existingClient: ref.read(restaurantAuthProvider.notifier).authenticatedHttpClient,
    );
    if (!mounted) return;
    if (err == null) {
      // The session refresh reads the flipped mode; main.dart then routes home.
      await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    await ref.read(saasSessionProvider.notifier).refreshSessionFromFirestore();
    if (mounted) setState(() => _busy = false);
  }

  void _openTill() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FastQsrBillingScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(saasSessionProvider);
    final org = session.currentOrganization;
    final pending = org?.pendingStorageChange ?? const <String, dynamic>{};
    final from = pending['from']?.toString() ?? org?.storageMode ?? '';
    final to = pending['to']?.toString() ?? '';
    final gutter = Responsive.gutter(context);
    final maxW = Responsive.isTablet(context) ? 620.0 : double.infinity;

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        automaticallyImplyLeading: false,
        title: Text('Store storage change',
            style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
        actions: [
          IconButton(
            tooltip: 'Check again',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: _busy ? null : () => ref.read(saasSessionProvider.notifier).clearSession(),
            icon: const Icon(Icons.logout_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.borderColor, height: 1),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxW),
          child: ListView(
            padding: EdgeInsets.all(gutter),
            children: [
              _modeCard(context, from, to),
              const SizedBox(height: DS.space4),
              if (_isOwner) ..._ownerBody(context, to) else ..._staffBody(context),
            ],
          ),
        ),
      ),
    );
  }

  Widget _modeCard(BuildContext context, String from, String to) {
    return Container(
      padding: const EdgeInsets.all(DS.space4),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Row(
        children: [
          Expanded(child: _modePill(context, 'Now', StorageModes.label(from), context.textSecondary)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: DS.space3),
            child: Icon(Icons.arrow_forward_rounded, color: ClassicTheme.primaryAccent),
          ),
          Expanded(child: _modePill(context, 'After', StorageModes.label(to), ClassicTheme.primaryAccent)),
        ],
      ),
    );
  }

  Widget _modePill(BuildContext context, String caption, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(caption, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
        const SizedBox(height: 2),
        Text(value,
            style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w700, color: color)),
      ],
    );
  }

  List<Widget> _ownerBody(BuildContext context, String to) {
    final toOffline = StorageModes.isOffline(to);
    return [
      Text(
        'Your platform administrator asked to move this store to ${StorageModes.label(to)}. '
        'The change runs here, on your device, and nothing switches over until every bill has been '
        'counted on both sides. Staff can keep billing on the current mode meanwhile.',
        style: TextStyle(fontSize: DS.fontBody, height: 1.5, color: context.textPrimary),
      ),
      const SizedBox(height: DS.space4),
      ValueListenableBuilder<MigrationProgress>(
        valueListenable: StorageMigrationService.progress,
        builder: (ctx, p, _) => _steps(ctx, p, toOffline),
      ),
      const SizedBox(height: DS.space4),
      if (_error != null)
        Container(
          padding: const EdgeInsets.all(DS.space3),
          margin: const EdgeInsets.only(bottom: DS.space3),
          decoration: BoxDecoration(
            color: ClassicTheme.dangerRed.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(DS.radiusMd),
            border: Border.all(color: ClassicTheme.dangerRed.withValues(alpha: 0.3)),
          ),
          child: Text(_error!, style: TextStyle(fontSize: DS.fontCaption, color: context.textPrimary, height: 1.4)),
        ),
      SizedBox(
        height: DS.tapTargetComfortable,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: ClassicTheme.primaryAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
          ),
          onPressed: _busy ? null : _start,
          icon: _busy
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Icon(Icons.play_arrow_rounded),
          label: Text(
            _busy ? 'Working…' : (_error == null ? 'Start the change' : 'Try again'),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      ),
      const SizedBox(height: DS.space3),
      OutlinedButton.icon(
        onPressed: _busy ? null : _openTill,
        icon: const Icon(Icons.point_of_sale_rounded),
        label: const Text('Bill in the meantime'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(DS.tapTargetMin),
          side: BorderSide(color: context.borderColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
        ),
      ),
      const SizedBox(height: DS.space4),
      Text(
        'Nothing on this device is deleted by the change. If a step fails, running again continues from the last finished step.',
        style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4),
      ),
    ];
  }

  Widget _steps(BuildContext context, MigrationProgress p, bool toOffline) {
    final steps = MigrationStep.values;
    final currentIdx = p.step == null ? (p.complete ? steps.length : -1) : steps.indexOf(p.step!);
    return Container(
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: BorderRadius.circular(DS.radiusLg),
        border: Border.all(color: context.borderColor),
      ),
      child: Column(
        children: [
          for (var i = 0; i < steps.length; i++)
            _stepRow(
              context,
              index: i,
              step: steps[i],
              skipped: toOffline && (steps[i] == MigrationStep.consent || steps[i] == MigrationStep.provision),
              state: p.complete
                  ? _StepState.done
                  : i < currentIdx
                      ? _StepState.done
                      : i == currentIdx
                          ? (p.failed ? _StepState.failed : _StepState.active)
                          : _StepState.todo,
              message: i == currentIdx ? p.message : null,
              fraction: i == currentIdx && steps[i] == MigrationStep.migrate ? p.fraction : null,
              last: i == steps.length - 1,
            ),
          if (p.complete)
            Padding(
              padding: const EdgeInsets.all(DS.space3),
              child: Text(p.message,
                  style: TextStyle(fontSize: DS.fontCaption, color: ClassicTheme.successEmerald, fontWeight: FontWeight.w600)),
            ),
        ],
      ),
    );
  }

  Widget _stepRow(
    BuildContext context, {
    required int index,
    required MigrationStep step,
    required bool skipped,
    required _StepState state,
    String? message,
    double? fraction,
    required bool last,
  }) {
    Color color;
    Widget icon;
    switch (state) {
      case _StepState.done:
        color = ClassicTheme.successEmerald;
        icon = const Icon(Icons.check_rounded, size: 16, color: Colors.white);
        break;
      case _StepState.active:
        color = ClassicTheme.primaryAccent;
        icon = const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white));
        break;
      case _StepState.failed:
        color = ClassicTheme.dangerRed;
        icon = const Icon(Icons.priority_high_rounded, size: 16, color: Colors.white);
        break;
      case _StepState.todo:
        color = context.textMuted;
        icon = Text('${index + 1}', style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: Colors.white));
        break;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(DS.space4, DS.space3, DS.space4, DS.space3),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: context.borderColor)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(radius: 13, backgroundColor: skipped ? context.textMuted : color, child: icon),
          const SizedBox(width: DS.space3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skipped ? '${step.label} — not needed for an offline store' : step.label,
                  style: TextStyle(
                    fontSize: DS.fontBody,
                    fontWeight: FontWeight.w600,
                    color: skipped ? context.textSecondary : context.textPrimary,
                  ),
                ),
                if (message != null && message.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(message, style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary, height: 1.4)),
                ],
                if (fraction != null) ...[
                  const SizedBox(height: DS.space2),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(DS.radiusPill),
                    child: LinearProgressIndicator(value: fraction, minHeight: 6, color: ClassicTheme.primaryAccent),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _staffBody(BuildContext context) {
    return [
      Container(
        padding: const EdgeInsets.all(DS.space4),
        decoration: BoxDecoration(
          color: context.surfaceColor,
          borderRadius: BorderRadius.circular(DS.radiusLg),
          border: Border.all(color: context.borderColor),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.hourglass_top_rounded, color: ClassicTheme.warningAmber, size: 28),
            const SizedBox(height: DS.space3),
            Text('The owner is moving the store',
                style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
            const SizedBox(height: DS.space2),
            Text(
              'Tables, kitchen and the other screens come back once the owner finishes the change on their device. '
              'You can keep billing at the counter as usual.',
              style: TextStyle(fontSize: DS.fontBody, height: 1.5, color: context.textSecondary),
            ),
          ],
        ),
      ),
      const SizedBox(height: DS.space4),
      SizedBox(
        height: DS.tapTargetComfortable,
        child: ElevatedButton.icon(
          style: ElevatedButton.styleFrom(
            backgroundColor: ClassicTheme.primaryAccent,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(DS.radiusMd)),
          ),
          onPressed: _openTill,
          icon: const Icon(Icons.point_of_sale_rounded),
          label: const Text('Continue billing', style: TextStyle(fontWeight: FontWeight.w700)),
        ),
      ),
    ];
  }
}

enum _StepState { todo, active, done, failed }
