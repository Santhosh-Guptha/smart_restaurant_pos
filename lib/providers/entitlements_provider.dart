import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/entitlements.dart';
import 'saas_session_provider.dart';

/// The tenant's resolved entitlements, derived from the active session.
///
/// Read this rather than poking at `currentLicense.features` directly: it
/// applies the offline hard-constraints, the dependency rules and the
/// fail-closed default in one place, and it rebuilds automatically when the
/// platform admin changes the tenant's plan.
final entitlementsProvider = Provider<Entitlements>((ref) {
  final session = ref.watch(saasSessionProvider);
  final role = (session.currentUser?.role ?? '').toUpperCase();
  final isPlatformAdmin = role == 'MASTER_ADMIN';

  return Entitlements.fromLicense(
    session.currentLicense,
    isMasterAdmin: isPlatformAdmin,
    // Offline is a property of the organisation's storage mode, not a
    // feature flag. The legacy flag is still honoured inside fromLicense.
    storageMode: session.currentOrganization?.storageMode,
  );
});

/// Convenience for a single key, so a widget can watch just the one feature it
/// cares about instead of rebuilding on every licence field.
final featureEnabledProvider = Provider.family<bool, String>((ref, key) {
  return ref.watch(entitlementsProvider).isEnabled(key);
});

/// How many devices this tenant may register. One for any offline tenant.
final maxDevicesProvider = Provider<int>(
    (ref) => ref.watch(entitlementsProvider).maxDevices);

/// True when the tenant runs as a single offline till: no cloud calls, no
/// second-device features, no network-dependent prompts.
final isPureOfflineProvider = Provider<bool>(
    (ref) => ref.watch(entitlementsProvider).isPureOffline);
