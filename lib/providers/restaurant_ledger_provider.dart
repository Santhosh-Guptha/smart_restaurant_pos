import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../core/constants.dart';
import '../services/lan_hub_client.dart';
import '../services/restaurant_ledger.dart';
import 'saas_session_provider.dart';

/// The one switch between "this device is the ledger" and "the host is the
/// ledger". Screens write orders and tables through this; reads stay on the
/// local Hive keys, which the [LanHubFeed] keeps mirrored on a satellite.
final restaurantLedgerProvider = Provider<RestaurantLedger>((ref) {
  final session = ref.watch(saasSessionProvider);
  if (isSatelliteSession()) {
    final orgId = resolveOutletId(
      userOrgId: session.currentUser?.organizationId,
      sessionOrgId: session.currentOrganization?.id,
      hiveBox: Hive.isBoxOpen('configBox') ? Hive.box('configBox') : null,
    );
    final ledger = LanHubLedger(client: LanHubClient.instance, mirrorOrgId: orgId);
    ref.onDispose(() => ledger.feed.stop());
    return ledger;
  }
  return LocalHiveLedger();
});

/// The satellite's live feed, or null on the host / an unpaired device.
final lanHubFeedProvider = Provider<LanHubFeed?>((ref) {
  final ledger = ref.watch(restaurantLedgerProvider);
  return ledger is LanHubLedger ? ledger.feed : null;
});
