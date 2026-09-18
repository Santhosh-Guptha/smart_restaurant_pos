import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/restaurant_models.dart';

/// Kitchen Display System (KDS) Voice Announcer & Audio Chime Service.
///
/// Announces new incoming orders audibly to kitchen staff so chefs and cooks
/// don't have to continuously look at the display screen while preparing food.
class KdsVoiceAnnouncer {
  KdsVoiceAnnouncer._();
  static final KdsVoiceAnnouncer instance = KdsVoiceAnnouncer._();

  FlutterTts? _tts;
  bool _isInitialized = false;
  bool _isSpeaking = false;
  final List<String> _speechQueue = [];

  static const String _kChimeKey = 'kds_audio_chime_enabled';
  static const String _kTtsKey = 'kds_voice_announcer_enabled';
  static const String _kSpeechRateKey = 'kds_tts_speech_rate';
  static const String _kVolumeKey = 'kds_tts_volume';

  /// Whether any audio alert (chime or TTS) is active
  bool get isVoiceOrChimeEnabled => isChimeEnabled || isTtsEnabled;

  /// Whether the audible bell chime is enabled (Default: true)
  bool get isChimeEnabled {
    try {
      if (!Hive.isBoxOpen('configBox')) return true;
      return Hive.box('configBox').get(_kChimeKey, defaultValue: true) as bool;
    } catch (_) {
      return true;
    }
  }

  set isChimeEnabled(bool value) {
    try {
      if (Hive.isBoxOpen('configBox')) {
        Hive.box('configBox').put(_kChimeKey, value);
      }
    } catch (_) {}
  }

  /// Whether Text-to-Speech order reading is enabled (Default: true)
  bool get isTtsEnabled {
    try {
      if (!Hive.isBoxOpen('configBox')) return true;
      return Hive.box('configBox').get(_kTtsKey, defaultValue: true) as bool;
    } catch (_) {
      return true;
    }
  }

  set isTtsEnabled(bool value) {
    try {
      if (Hive.isBoxOpen('configBox')) {
        Hive.box('configBox').put(_kTtsKey, value);
      }
    } catch (_) {}
  }

  /// Speech rate (0.3 to 1.0, default 0.85 for crisp comprehension)
  double get speechRate {
    try {
      if (!Hive.isBoxOpen('configBox')) return 0.85;
      final val = Hive.box('configBox').get(_kSpeechRateKey, defaultValue: 0.85);
      return (val as num).toDouble();
    } catch (_) {
      return 0.85;
    }
  }

  set speechRate(double value) {
    try {
      if (Hive.isBoxOpen('configBox')) {
        Hive.box('configBox').put(_kSpeechRateKey, value);
      }
      _tts?.setSpeechRate(value);
    } catch (_) {}
  }

  /// Speech volume (0.0 to 1.0, default 1.0)
  double get volume {
    try {
      if (!Hive.isBoxOpen('configBox')) return 1.0;
      final val = Hive.box('configBox').get(_kVolumeKey, defaultValue: 1.0);
      return (val as num).toDouble();
    } catch (_) {
      return 1.0;
    }
  }

  set volume(double value) {
    try {
      if (Hive.isBoxOpen('configBox')) {
        Hive.box('configBox').put(_kVolumeKey, value);
      }
      _tts?.setVolume(value);
    } catch (_) {}
  }

  /// Initializes the TTS engine lazily and safely
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;
    try {
      _tts = FlutterTts();
      await _tts?.setVolume(volume);
      await _tts?.setSpeechRate(speechRate);
      await _tts?.setPitch(1.0);

      try {
        final languages = await _tts?.getLanguages;
        if (languages is List && languages.contains('en-IN')) {
          await _tts?.setLanguage('en-IN');
        } else {
          await _tts?.setLanguage('en-US');
        }
      } catch (_) {}

      _tts?.setCompletionHandler(() {
        _isSpeaking = false;
        _processQueue();
      });

      _tts?.setErrorHandler((_) {
        _isSpeaking = false;
        _processQueue();
      });

      _isInitialized = true;
    } catch (e) {
      debugPrint('KdsVoiceAnnouncer: TTS init failed: $e');
    }
  }

  /// Plays the distinct acoustic chime / alert
  Future<void> playChime() async {
    if (!isChimeEnabled) return;
    try {
      await SystemSound.play(SystemSoundType.alert);
      await HapticFeedback.heavyImpact();
    } catch (_) {}
  }

  /// Formats a single KOT order into a natural, spoken kitchen utterance.
  /// Example: "New Order for Table 4. 2 Chicken Biryani, 1 Butter Naan."
  static String formatOrderUtterance(KotOrder order) {
    final table = order.tableName.trim();
    final isParcel = table.toLowerCase().contains('parcel') ||
        table.toLowerCase().contains('takeaway') ||
        table.toLowerCase().contains('counter') ||
        table.isEmpty;

    final prefix = isParcel
        ? 'New Takeaway order'
        : 'New Order for $table';

    final activeItems = order.items.where((i) => i.voidedQty < i.qty).toList();
    if (activeItems.isEmpty) return '$prefix received.';

    final itemPhrases = activeItems.map((item) {
      final effectiveQty = (item.qty - item.voidedQty).round();
      final qtyStr = effectiveQty <= 1 ? '1' : '$effectiveQty';
      final cleanName = item.name.replaceAll(RegExp(r'\(.*?\)|\[.*?\]'), '').trim();
      return '$qtyStr $cleanName';
    }).toList();

    return '$prefix. ${itemPhrases.join(', ')}.';
  }

  /// Announces a list of newly arrived KOT orders.
  /// Plays the acoustic chime first, then speaks the order details sequentially.
  Future<void> announceNewOrders(List<KotOrder> newOrders) async {
    if (newOrders.isEmpty) return;

    if (isChimeEnabled) {
      await playChime();
    }

    if (!isTtsEnabled) return;

    for (final order in newOrders) {
      final utterance = formatOrderUtterance(order);
      _speechQueue.add(utterance);
    }

    _processQueue();
  }

  Future<void> _processQueue() async {
    if (_isSpeaking || _speechQueue.isEmpty) return;
    await _ensureInitialized();
    if (_tts == null) return;

    _isSpeaking = true;
    final nextText = _speechQueue.removeAt(0);

    try {
      await _tts?.speak(nextText);
    } catch (e) {
      debugPrint('KdsVoiceAnnouncer: TTS speak error: $e');
      _isSpeaking = false;
      _processQueue();
    }
  }

  /// Cancels all speech and clears the queue
  Future<void> stop() async {
    _speechQueue.clear();
    _isSpeaking = false;
    try {
      await _tts?.stop();
    } catch (_) {}
  }
}
