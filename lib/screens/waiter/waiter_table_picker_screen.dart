import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../core/classic_theme.dart';
import '../../core/constants.dart';
import '../../core/design_tokens.dart';
import '../../core/entitlements.dart';
import '../../core/feature_route_guard.dart';
import '../../core/responsive.dart';
import '../../core/restaurant_models.dart';
import '../../providers/saas_session_provider.dart';
import 'waiter_order_taking_screen.dart';

/// The waiter's front door: pick a table, start the order.
///
/// A waiter does not need the whole floor-management screen (move, merge,
/// block, QR standees). They need to know which tables are free or already
/// eating, and to get to the order pad in one tap. Owned by
/// [FeatureKeys.waiterOrdering]; tables come from the same Hive key the floor
/// screen writes, so both views always agree.
class WaiterTablePickerScreen extends ConsumerStatefulWidget {
  const WaiterTablePickerScreen({super.key});

  @override
  ConsumerState<WaiterTablePickerScreen> createState() => _WaiterTablePickerScreenState();
}

class _WaiterTablePickerScreenState extends ConsumerState<WaiterTablePickerScreen>
    with FeatureRouteGuard<WaiterTablePickerScreen> {
  List<RestaurantTable> _tables = [];
  String _section = 'All';

  @override
  void initState() {
    super.initState();
    guardFeature(FeatureKeys.waiterOrdering);
    if (!guardTripped) _load();
  }

  String _orgId() {
    final s = ref.read(saasSessionProvider);
    return resolveOutletId(
      userOrgId: s.currentUser?.organizationId,
      sessionOrgId: s.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
  }

  void _load() {
    try {
      final box = Hive.box('configBox');
      final raw = box.get('restaurant_tables_${_orgId()}');
      if (raw is List) {
        _tables = raw
            .whereType<Map>()
            .map((m) => RestaurantTable.fromMap(Map<String, dynamic>.from(m), m['id']?.toString() ?? ''))
            .toList()
          ..sort((a, b) => a.tableNumber.compareTo(b.tableNumber));
      }
    } catch (_) {
      _tables = [];
    }
    if (mounted) setState(() {});
  }

  Color _statusColor(TableStatus s) {
    switch (s) {
      case TableStatus.vacant:
        return ClassicTheme.successEmerald;
      case TableStatus.seated:
        return ClassicTheme.infoBlue;
      case TableStatus.occupied:
      case TableStatus.billed:
        return ClassicTheme.warningAmber;
      case TableStatus.reserved:
        return ClassicTheme.secondaryAccent;
      case TableStatus.cleaning:
        return ClassicTheme.warningAmber;
      case TableStatus.blocked:
        return Colors.grey;
    }
  }

  String _statusLabel(TableStatus s) {
    switch (s) {
      case TableStatus.vacant:
        return 'Free';
      case TableStatus.seated:
        return 'Seated';
      case TableStatus.occupied:
        return 'Eating';
      case TableStatus.billed:
        return 'Billed';
      case TableStatus.reserved:
        return 'Reserved';
      case TableStatus.cleaning:
        return 'Cleaning';
      case TableStatus.blocked:
        return 'Blocked';
    }
  }

  @override
  Widget build(BuildContext context) {
    final sections = <String>{'All', ..._tables.map((t) => t.section).where((s) => s.isNotEmpty)}.toList();
    final visible = _section == 'All' ? _tables : _tables.where((t) => t.section == _section).toList();
    final gutter = Responsive.gutter(context);
    final cols = Responsive.isExpanded(context) ? 6 : Responsive.isMedium(context) ? 4 : 3;

    return Scaffold(
      backgroundColor: context.canvasColor,
      appBar: AppBar(
        backgroundColor: context.surfaceColor,
        foregroundColor: context.textPrimary,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Waiter Pad',
                style: TextStyle(fontSize: DS.fontTitle, fontWeight: FontWeight.w700, color: context.textPrimary)),
            Text('Tap a table to take the order',
                style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
          ],
        ),
        actions: [
          IconButton(tooltip: 'Reload tables', onPressed: _load, icon: const Icon(Icons.refresh_rounded)),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(color: context.borderColor, height: 1),
        ),
      ),
      body: _tables.isEmpty
          ? _empty(context)
          : Column(
              children: [
                if (sections.length > 2)
                  SizedBox(
                    height: 52,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      padding: EdgeInsets.symmetric(horizontal: gutter, vertical: 8),
                      itemCount: sections.length,
                      separatorBuilder: (_, __) => const SizedBox(width: DS.space2),
                      itemBuilder: (ctx, i) {
                        final s = sections[i];
                        final sel = s == _section;
                        return ChoiceChip(
                          label: Text(s, style: TextStyle(fontSize: DS.fontMicro, color: sel ? Colors.white : context.textPrimary)),
                          selected: sel,
                          selectedColor: ClassicTheme.primaryAccent,
                          backgroundColor: context.surfaceColor,
                          side: BorderSide(color: context.borderColor),
                          onSelected: (_) => setState(() => _section = s),
                        );
                      },
                    ),
                  ),
                Expanded(
                  child: GridView.builder(
                    padding: EdgeInsets.all(gutter),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      mainAxisSpacing: DS.space3,
                      crossAxisSpacing: DS.space3,
                      childAspectRatio: 1,
                    ),
                    itemCount: visible.length,
                    itemBuilder: (ctx, i) => _tile(ctx, visible[i]),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _empty(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(DS.space8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.table_restaurant_rounded, size: 48, color: context.textMuted),
            const SizedBox(height: DS.space3),
            Text('No tables yet',
                style: TextStyle(fontSize: DS.fontBodyLg, fontWeight: FontWeight.w600, color: context.textPrimary)),
            const SizedBox(height: DS.space1),
            Text('Ask the owner to add tables under Tables & Floor.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: DS.fontCaption, color: context.textSecondary)),
          ],
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, RestaurantTable t) {
    final color = _statusColor(t.status);
    final blocked = t.status == TableStatus.blocked || t.status == TableStatus.cleaning;
    return Material(
      color: context.surfaceColor,
      borderRadius: BorderRadius.circular(DS.radiusLg),
      child: InkWell(
        borderRadius: BorderRadius.circular(DS.radiusLg),
        onTap: blocked
            ? null
            : () async {
                await Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => WaiterOrderTakingScreen(table: t)),
                );
                _load();
              },
        child: Container(
          padding: const EdgeInsets.all(DS.space3),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(DS.radiusLg),
            border: Border.all(color: t.status == TableStatus.vacant ? context.borderColor : color, width: 1.5),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  CircleAvatar(radius: 4, backgroundColor: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(_statusLabel(t.status),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: DS.fontMicro, fontWeight: FontWeight.w700, color: color)),
                  ),
                ],
              ),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text('T${t.tableNumber}',
                    style: TextStyle(fontSize: DS.fontHeadline, fontWeight: FontWeight.w800, color: context.textPrimary)),
              ),
              Text('${t.capacity} seats${t.section.isNotEmpty ? ' • ${t.section}' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: DS.fontMicro, color: context.textSecondary)),
            ],
          ),
        ),
      ),
    );
  }
}
