import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'entitlements.dart';
import '../providers/entitlements_provider.dart';

/// Second line of defence for a screen that belongs to a feature.
///
/// The first line is that the card or button leading here is absent when the
/// feature is off. But a screen can still be reached — a stale route, a deep
/// link, a saved navigation stack from before the plan changed — and if it
/// starts its pollers against a feature that is not there, rule 4 is broken.
/// So the screen guards itself: call [guardFeature] from `initState` and the
/// screen pops back with a one-line message before its first frame settles.
///
/// Also exposes [featureOn] for the same screen to decide whether to start
/// optional background work (a poller that only matters with the cloud on).
mixin FeatureRouteGuard<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  bool _guardTripped = false;

  /// True once the guard has decided this screen must leave. Pollers and
  /// loaders check it so nothing starts on a screen that is on its way out.
  bool get guardTripped => _guardTripped;

  bool featureOn(String key) => ref.read(entitlementsProvider).isEnabled(key);

  void guardFeature(String key, {String? label}) {
    final ent = ref.read(entitlementsProvider);
    if (ent.isEnabled(key)) return;
    _guardTripped = true;
    final name = label ?? FeatureCatalog.find(key)?.label ?? key;
    final why = ent.explain(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final messenger = ScaffoldMessenger.maybeOf(context);
      Navigator.of(context).maybePop();
      messenger?.showSnackBar(SnackBar(
        content: Text('$name is not switched on for this store. $why'),
        duration: const Duration(seconds: 4),
      ));
    });
  }
}
