import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/classic_theme.dart';
import '../providers/restaurant_ledger_provider.dart';
import '../providers/saas_session_provider.dart';
import '../services/restaurant_ledger.dart';

/// One-line status strip for a paired satellite, shown above the kitchen
/// display, the floor plan and the waiter pad.
///
/// Nothing is drawn on the host or on a device that is not a satellite.
/// On a satellite it shows, in order of severity:
/// - the pairing was removed by the host (401): a button to pair again;
/// - the host cannot be reached: how many changes are waiting locally;
/// - otherwise nothing (connected).
class LanHubStatusBanner extends ConsumerWidget {
  const LanHubStatusBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feed = ref.watch(lanHubFeedProvider);
    if (feed == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([feed, LanWriteQueue.instance]),
      builder: (context, _) {
        if (feed.needsPairing) {
          return _Strip(
            color: ClassicTheme.dangerRed,
            icon: Icons.link_off_rounded,
            text: 'The host removed this device. Pair it again from the host screen PIN.',
            action: TextButton(
              onPressed: () => ref.read(saasSessionProvider.notifier).clearSession(),
              child: const Text('Pair again', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
            ),
          );
        }
        if (!feed.connected) {
          final n = feed.pendingWrites;
          final waiting = n == 0
              ? 'Showing the last copy from the host.'
              : '$n change${n == 1 ? '' : 's'} saved here and sent when the host is back.';
          return _Strip(
            color: ClassicTheme.warningAmber,
            icon: Icons.wifi_off_rounded,
            text: 'Host unreachable. $waiting',
          );
        }
        return const SizedBox.shrink();
      },
    );
  }
}

class _Strip extends StatelessWidget {
  const _Strip({required this.color, required this.icon, required this.text, this.action});

  final Color color;
  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(icon, color: Colors.white, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
            ),
          ),
          if (action != null) action!,
        ],
      ),
    );
  }
}
