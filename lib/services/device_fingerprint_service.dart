import 'dart:convert';
import 'dart:io' show Platform;
import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';

import 'client_license_service.dart';

/// Result of a machine-binding verification check.
class MachineBindValidationResult {
  final bool isValid;
  final String? errorMessage;
  final String machineId;
  final String? expectedMachineId;

  const MachineBindValidationResult({
    required this.isValid,
    required this.machineId,
    this.errorMessage,
    this.expectedMachineId,
  });

  factory MachineBindValidationResult.success(String machineId) =>
      MachineBindValidationResult(isValid: true, machineId: machineId);

  factory MachineBindValidationResult.mismatch({
    required String currentMachineId,
    required String expectedMachineId,
  }) =>
      MachineBindValidationResult(
        isValid: false,
        machineId: currentMachineId,
        expectedMachineId: expectedMachineId,
        errorMessage:
            "This licence key is locked to Machine ID: $expectedMachineId.\n"
            "Current device Machine ID: $currentMachineId.\n"
            "Licences cannot be transferred or reused across different machines.",
      );

  factory MachineBindValidationResult.alreadyBoundOtherMachine({
    required String currentMachineId,
    required String boundMachineId,
  }) =>
      MachineBindValidationResult(
        isValid: false,
        machineId: currentMachineId,
        expectedMachineId: boundMachineId,
        errorMessage:
            "This licence was previously activated on Machine: $boundMachineId.\n"
            "Hardware binding violation detected.",
      );
}

/// Service that computes a deterministic, persistent hardware fingerprint (Machine ID)
/// and enforces machine-level license binding to prevent token reuse across machines.
class DeviceFingerprintService {
  DeviceFingerprintService._();

  static const String _boxName = 'configBox';
  static const String _machineIdKey = '_sbz_device_machine_id';
  static const String _boundLicensesPrefix = '_sbz_bound_lic_';

  static String? _cachedMachineId;

  /// Retrieves or generates a stable, unique Machine ID for this device.
  /// Format: `SBZ-MCH-XXXX-XXXX`
  static Future<String> getMachineId() async {
    if (_cachedMachineId != null && _cachedMachineId!.isNotEmpty) {
      return _cachedMachineId!;
    }

    try {
      final box = Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : await Hive.openBox(_boxName);
      final storedId = box.get(_machineIdKey);
      if (storedId is String && storedId.trim().isNotEmpty) {
        _cachedMachineId = storedId.trim();
        return _cachedMachineId!;
      }

      // Compute hardware seed
      final rawHardwareSeed = await _fetchRawHardwareSeed();
      final digest = sha256.convert(utf8.encode(rawHardwareSeed)).toString().toUpperCase();
      
      // Format into 16-character grouped ID: SBZ-MCH-XXXX-XXXX
      final part1 = digest.substring(0, 4);
      final part2 = digest.substring(4, 8);
      final part3 = digest.substring(8, 12);
      final formattedId = "SBZ-MCH-$part1-$part2-$part3";

      await box.put(_machineIdKey, formattedId);
      _cachedMachineId = formattedId;
      return formattedId;
    } catch (e) {
      debugPrint("DeviceFingerprintService: fallback uuid error: $e");
      final fallback = "SBZ-MCH-GEN-${const Uuid().v4().substring(0, 8).toUpperCase()}";
      _cachedMachineId = fallback;
      return fallback;
    }
  }

  /// Extracts low-level hardware or OS identifiers.
  static Future<String> _fetchRawHardwareSeed() async {
    final deviceInfo = DeviceInfoPlugin();

    if (kIsWeb) {
      // For web till instances, combine userAgent and random persistent salt
      return "WEB_${const Uuid().v4()}_${DateTime.now().microsecondsSinceEpoch}";
    }

    try {
      if (Platform.isWindows) {
        final win = await deviceInfo.windowsInfo;
        final deviceId = win.deviceId.replaceAll(RegExp(r'[{}]'), '').trim();
        return "WIN_${win.computerName}_$deviceId";
      } else if (Platform.isMacOS) {
        final mac = await deviceInfo.macOsInfo;
        return "MAC_${mac.computerName}_${mac.systemGUID ?? mac.model}";
      } else if (Platform.isLinux) {
        final lin = await deviceInfo.linuxInfo;
        return "LIN_${lin.name}_${lin.machineId ?? lin.id}";
      } else if (Platform.isAndroid) {
        final and = await deviceInfo.androidInfo;
        return "AND_${and.brand}_${and.model}_${and.id}";
      } else if (Platform.isIOS) {
        final ios = await deviceInfo.iosInfo;
        return "IOS_${ios.name}_${ios.identifierForVendor ?? ios.model}";
      }
    } catch (e) {
      debugPrint("DeviceFingerprintService: error inspecting hardware: $e");
    }

    return "DEV_${const Uuid().v4()}";
  }

  /// Verifies if the provided licence payload is authorized to run on this machine.
  static Future<MachineBindValidationResult> validateBinding(ClientLicensePayload payload) async {
    final currentMachineId = await getMachineId();

    // 1. Strict Target Machine ID check (if token was pre-baked for a specific machine)
    final targetMachineId = payload.machineId.trim();
    if (targetMachineId.isNotEmpty && targetMachineId != 'ANY') {
      if (targetMachineId.toUpperCase() != currentMachineId.toUpperCase()) {
        return MachineBindValidationResult.mismatch(
          currentMachineId: currentMachineId,
          expectedMachineId: targetMachineId,
        );
      }
    }

    // 2. Check local binding cache (to prevent moving an activated licence DB to another hardware)
    try {
      final box = Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : await Hive.openBox(_boxName);
      final boundMachine = box.get('$_boundLicensesPrefix${payload.orgId}');
      if (boundMachine is String && boundMachine.isNotEmpty) {
        if (boundMachine.toUpperCase() != currentMachineId.toUpperCase()) {
          return MachineBindValidationResult.alreadyBoundOtherMachine(
            currentMachineId: currentMachineId,
            boundMachineId: boundMachine,
          );
        }
      }
    } catch (_) {}

    return MachineBindValidationResult.success(currentMachineId);
  }

  /// Locks and binds the activated license to the current machine.
  /// Checks whether this machine is authorized to run the previously activated license for [orgId].
  /// Returns false if a hardware mismatch is detected (e.g. copied database / cloned storage).
  static Future<bool> isCurrentMachineAuthorized(String orgId) async {
    try {
      final box = Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : await Hive.openBox(_boxName);
      final boundMachine = box.get('');
      if (boundMachine is String && boundMachine.isNotEmpty) {
        final currentMachine = await getMachineId();
        return boundMachine.toUpperCase() == currentMachine.toUpperCase();
      }
      return true; // Not yet bound or non-offline org
    } catch (e) {
      debugPrint('DeviceFingerprintService.isCurrentMachineAuthorized error: ');
      return false;
    }
  }

  static Future<void> recordActivationBinding(ClientLicensePayload payload) async {
    final currentMachineId = await getMachineId();
    try {
      final box = Hive.isBoxOpen(_boxName) ? Hive.box(_boxName) : await Hive.openBox(_boxName);
      await box.put('$_boundLicensesPrefix${payload.orgId}', currentMachineId);
      await box.put('_sbz_active_machine_id', currentMachineId);
      debugPrint("🔒 DeviceFingerprintService: License ${payload.orgId} bound to $currentMachineId");
    } catch (e) {
      debugPrint("DeviceFingerprintService: binding error: $e");
    }
  }

  /// Resets cached machine ID (useful for tests or device resets).
  @visibleForTesting
  static void resetCache() {
    _cachedMachineId = null;
  }
}
