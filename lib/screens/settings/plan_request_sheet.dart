import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/responsive.dart';
import '../../providers/saas_session_provider.dart';
import '../../utils/ui_feedback.dart';
import '../admin/widgets/tenant_package_editor.dart';

/// The owner asks for a different plan; the platform admin decides.
///
/// Uses the same [TenantPackageEditor] the console uses, with the limits
/// locked — the owner says what they want to be able to do, not how many
/// devices they are entitled to. Nothing here changes the tenant's plan: it
/// writes one `renewal_requests/{orgId}` document and says so plainly, because
/// a request that looks like a purchase is a support ticket waiting to happen.
///
/// No price is shown or implied anywhere (FEATURE_MASTER_PLAN.md D5) — what it
/// costs is a conversation with the administrator, not a number in the app.
class PlanRequestSheet extends ConsumerStatefulWidget {
  /// RENEWAL when the plan has run out, UPGRADE when they want more.
  final String type;

  const PlanRequestSheet({super.key, this.type = 'UPGRADE'});

  static Future<bool?> show(BuildContext context, {String type = 'UPGRADE'}) =>
      showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => PlanRequestSheet(type: type),
      );

  @override
  ConsumerState<PlanRequestSheet> createState() => _PlanRequestSheetState();
}

class _PlanRequestSheetState extends ConsumerState<PlanRequestSheet> {
  late TenantPackageSelection _selection;
  final TextEditingController _noteCtrl = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    final session = ref.read(saasSessionProvider);
    final licence = session.currentLicense;

    // Start from what they have, so the sheet reads as "change this" rather
    // than "choose from scratch".
    final current = PlanProfile.byId(licence?.planProfile ?? licence?.planTier);
    // A package and a plan now, not a profile plus ticked extras. The editor
    // loads both lists and snaps this to the matching documents once it has
    // them; until then the starter of their current profile stands in.
    _selection = TenantPackageSelection.forProfile(current, validityDays: 365);
  }

  @override
  void dispose() {
    _noteCtrl.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final session = ref.read(saasSessionProvider);
    final org = session.currentOrganization;
    final user = session.currentUser;
    if (org == null) return;

    setState(() => _sending = true);
    try {
      final now = FieldValue.serverTimestamp();
      final fs = FirebaseFirestore.instance;

      await fs.collection('renewal_requests').doc(org.id).set({
        'organizationId': org.id,
        'organizationName': org.name,
        'type': widget.type,
        'status': 'PENDING',
        // The two ids are what the console's approval card reads. The older
        // fields stay so a console build that predates packages still shows
        // something sensible.
        'requestedPackageId': _selection.packageId,
        'requestedPlanId': _selection.planId,
        'requestedPackageName': _selection.package.name,
        'requestedPlanName': _selection.planId.isEmpty ? '' : _selection.plan.name,
        'requestedProfile': _selection.profile.id,
        'requestedStorageMode': _selection.storageMode,
        'requestedAddOns': _selection.addOns.keys.toList()..sort(),
        'requestedValidityDays': _selection.validityDays,
        'note': _noteCtrl.text.trim(),
        'requestedBy': user?.id,
        'requestedByEmail': user?.email,
        'requestedAt': now,
        'contactEmail': kAdminEmail,
      }, SetOptions(merge: true));

      await fs.collection('audit_logs').add({
        'action': 'PLAN_REQUESTED',
        'actionType': 'PLAN_REQUESTED',
        'targetOrgId': org.id,
        'organizationId': org.id,
        'organizationName': org.name,
        'details': '${widget.type} requested: ${_selection.package.name}'
            '${_selection.planId.isEmpty ? '' : ' \u00b7 ${_selection.plan.name}'}',
        'by': user?.email ?? 'owner',
        'priority': 'HIGH',
        'timestamp': now,
      });

      if (mounted) setState(() => _sent = true);
    } catch (e) {
      if (mounted) AppToast.showError(context, e, title: 'Could not send the request');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final gutter = Responsive.gutter(context);
    final maxH = MediaQuery.of(context).size.height * 0.9;

    return Container(
      constraints: BoxConstraints(maxHeight: maxH),
      decoration: BoxDecoration(
        color: context.surfaceColor,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(DS.radiusXl)),
      ),
      child: SafeArea(
        top: false,
        child: _sent ? _confirmation(context, gutter) : _form(context, gutter),
      ),
    );
  }

  Widget _confirmation(BuildContext context, double gutter) => Padding(
        padding: EdgeInsets.all(gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: DS.space4),
            Icon(Icons.mark_email_read_outlined,
                size: 40, color: ClassicTheme.successEmerald),
            const SizedBox(height: DS.space3),
            Text('Sent to your administrator',
                style: TextStyle(
                    fontSize: DS.fontHeadline,
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary)),
            const SizedBox(height: DS.space2),
            Text(
              'Your plan has not changed. An administrator reviews what you asked '
              'for and confirms the final plan with you — you will see it here '
              'once it is applied.',
              style: TextStyle(
                  fontSize: DS.fontBody, height: 1.55, color: context.textSecondary),
            ),
            const SizedBox(height: DS.space5),
            SizedBox(
              height: DS.tapTargetComfortable,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DS.radiusMd)),
                ),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(height: DS.space3),
          ],
        ),
      );

  Widget _form(BuildContext context, double gutter) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, DS.space4, gutter, DS.space2),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.type == 'RENEWAL' ? 'Renew your plan' : 'Ask for more',
                        style: TextStyle(
                            fontSize: DS.fontHeadline,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text('Your administrator confirms the final plan.',
                          style: TextStyle(
                              fontSize: DS.fontCaption, color: context.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          Flexible(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(gutter, 0, gutter, DS.space4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TenantPackageEditor(
                    value: _selection,
                    onChanged: (v) => setState(() => _selection = v),
                    limitsReadOnly: true,
                    showValidity: false,
                  ),
                  const SizedBox(height: DS.space4),
                  TextField(
                    controller: _noteCtrl,
                    maxLines: 3,
                    style: TextStyle(color: context.textPrimary, fontSize: DS.fontBody),
                    decoration: InputDecoration(
                      labelText: 'Anything to add? (optional)',
                      labelStyle: TextStyle(color: context.textSecondary),
                      hintText: 'e.g. we are opening a second counter next month',
                      hintStyle: TextStyle(
                          color: context.textMuted, fontSize: DS.fontCaption),
                      filled: true,
                      fillColor: context.inputFill,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        borderSide: BorderSide(color: context.borderColor),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(DS.radiusMd),
                        borderSide: BorderSide(color: context.borderColor),
                      ),
                    ),
                  ),
                  const SizedBox(height: DS.space3),
                  Container(
                    padding: const EdgeInsets.all(DS.space3),
                    decoration: BoxDecoration(
                      color: context.sunkenSurface,
                      borderRadius: BorderRadius.circular(DS.radiusMd),
                      border: Border.all(color: context.borderColor),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline_rounded,
                            size: 16, color: context.textSecondary),
                        const SizedBox(width: DS.space2),
                        Expanded(
                          child: Text(
                            'This sends a request. Nothing about your plan changes until '
                            'your administrator applies it, and they may adjust what you '
                            'asked for.',
                            style: TextStyle(
                                fontSize: DS.fontMicro,
                                color: context.textSecondary,
                                height: 1.45),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, DS.space2, gutter, DS.space4),
            child: SizedBox(
              width: double.infinity,
              height: DS.tapTargetComfortable,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: ClassicTheme.primaryAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DS.radiusMd)),
                ),
                onPressed: _sending ? null : _send,
                icon: _sending
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send_rounded, size: 18),
                label: Text(_sending ? 'Sending…' : 'Send request',
                    style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            ),
          ),
        ],
      );
}
