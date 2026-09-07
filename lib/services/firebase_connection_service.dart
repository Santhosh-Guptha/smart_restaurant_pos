import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:encrypt/encrypt.dart' as enc;

class FirebaseConnectionService {
  static const String _appSalt = "SmartBizFranchisePlatform2026S"; // 32 characters

  // ── Internal state ────────────────────────────────────────────────────
  // _connectionCounter is static so it increments across hot-restarts and
  // guarantees a unique Firebase app name on every init cycle. Firebase
  // heartbeat DataStore files are keyed by (appName + appId), so reusing
  // the same name after app.delete() causes "multiple DataStores on same
  // file" crash. A counter suffix sidesteps this entirely.
  static int _connectionCounter = 0;

  FirebaseApp? _customerApp;
  FirebaseFirestore? _customerFirestore;
  FirebaseStorage? _customerStorage;
  String? _connectedOrgId; // tracks which org is currently connected

  // Guard: prevents concurrent initialise/disconnect calls from overlapping.
  bool _isTransitioning = false;

  // ── Public accessors ─────────────────────────────────────────────────

  /// Returns the Master Firestore instance (the default Firebase app)
  FirebaseFirestore get masterFirestore => FirebaseFirestore.instance;

  /// Returns the Customer Firestore instance if initialized and the app is
  /// still alive. Returns null if the app has been deleted or is in the
  /// middle of a transition.
  FirebaseFirestore? get customerFirestore {
    if (_customerApp == null || _isTransitioning) return null;
    try {
      // Accessing app.name throws StateError if the app was deleted.
      final _ = _customerApp!.name;
      return _customerFirestore;
    } catch (_) {
      // App was deleted externally — clean up references.
      _customerApp = null;
      _customerFirestore = null;
      _customerStorage = null;
      return null;
    }
  }

  /// Returns the Customer Storage instance if initialized
  FirebaseStorage? get customerStorage {
    if (_customerApp == null || _isTransitioning) return null;
    try {
      final _ = _customerApp!.name;
      return _customerStorage;
    } catch (_) {
      _customerApp = null;
      _customerFirestore = null;
      _customerStorage = null;
      return null;
    }
  }

  /// Returns true if a customer Firebase app is currently connected
  bool get isCustomerConnected => customerFirestore != null;

  /// Returns the Project ID of the currently connected customer Firebase app
  String? get connectedProjectId {
    if (_customerApp == null || _isTransitioning) return null;
    try {
      return _customerApp!.options.projectId;
    } catch (_) {
      return null;
    }
  }

  /// Returns the Org ID currently connected
  String? get connectedOrgId => _connectedOrgId;

  // ── Encryption helpers ───────────────────────────────────────────────

  /// Derives a 32-byte key from the organizationId and our static salt
  String _deriveKey(String orgId) {
    final raw = "$orgId$_appSalt";
    if (raw.length >= 32) return raw.substring(0, 32);
    return raw.padRight(32, 'X');
  }

  /// Encrypts the customer Firebase config map into an encrypted string + IV
  Map<String, String> encryptConfig(String orgId, Map<String, String> config) {
    try {
      final plainText = jsonEncode(config);
      final key = enc.Key.fromUtf8(_deriveKey(orgId));
      final iv = enc.IV.fromLength(16);
      final encrypter = enc.Encrypter(enc.AES(key));
      final encrypted = encrypter.encrypt(plainText, iv: iv);
      return {'encrypted': encrypted.base64, 'iv': iv.base64};
    } catch (e) {
      debugPrint("Encryption failed: $e");
      rethrow;
    }
  }

  /// Decrypts the customer Firebase config
  Map<String, String> decryptConfig(
      String orgId, String encryptedBase64, String ivBase64) {
    try {
      final key = enc.Key.fromUtf8(_deriveKey(orgId));
      final iv = enc.IV.fromBase64(ivBase64);
      final encrypter = enc.Encrypter(enc.AES(key));
      final decrypted = encrypter.decrypt64(encryptedBase64, iv: iv);
      final decoded = jsonDecode(decrypted) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    } catch (e) {
      debugPrint("Decryption failed: $e");
      rethrow;
    }
  }

  // ── App lifecycle ────────────────────────────────────────────────────

  /// Dynamically initialises the Customer Firebase App.
  ///
  /// A fresh unique name (cust_conn_N) is used on every new connection so
  /// Firebase never tries to open the same heartbeat DataStore file twice.
  /// If the same org is already connected, this is a no-op.
  Future<void> initializeCustomerApp(
      String orgId, Map<String, String> config) async {

    // Already connected to this exact org — reuse the existing app.
    if (!_isTransitioning &&
        _connectedOrgId == orgId &&
        _customerApp != null) {
      debugPrint("Customer app already connected for org: $orgId");
      return;
    }

    // Prevent concurrent calls from overlapping.
    if (_isTransitioning) {
      debugPrint("Customer app transition already in progress — skipping.");
      return;
    }

    _isTransitioning = true;
    try {
      // Tear down the old connection first (nulls refs before delete).
      await _deleteCurrentApp();

      // Small settling delay so the OS can release channel resources.
      await Future.delayed(const Duration(milliseconds: 400));

      // ── KEY FIX ──────────────────────────────────────────────────────
      // Increment the counter to get a guaranteed-unique app name.
      // Firebase heartbeat DataStore filenames are derived from (appName +
      // appId). Reusing the same name after delete() causes a fatal
      // "multiple DataStores active for same file" crash. A new name = a
      // new file = no conflict.
      _connectionCounter++;
      final name = "cust_conn_$_connectionCounter";

      final options = FirebaseOptions(
        apiKey: config['apiKey'] ?? '',
        appId: config['appId'] ?? '',
        projectId: config['projectId'] ?? '',
        storageBucket: config['storageBucket'] ?? '',
        messagingSenderId: config['messagingSenderId'] ?? '',
      );

      _customerApp =
          await Firebase.initializeApp(name: name, options: options);

      _customerFirestore =
          FirebaseFirestore.instanceFor(app: _customerApp!);
      _customerStorage =
          FirebaseStorage.instanceFor(app: _customerApp!);

      // Disable offline persistence for the customer app.
      // It is used for live analytics queries by Master Admin — no need
      // for a local SQLite cache, and persistence would open more file
      // handles that conflict on reconnect.
      _customerFirestore!.settings = const Settings(
        persistenceEnabled: false,
      );

      _connectedOrgId = orgId;

      debugPrint(
          "Connected to Customer Firebase: ${options.projectId} (slot: $name)");
    } catch (e) {
      debugPrint("Error initializing customer Firebase app: $e");
      _customerApp = null;
      _customerFirestore = null;
      _customerStorage = null;
      _connectedOrgId = null;
      rethrow;
    } finally {
      _isTransitioning = false;
    }
  }

  /// Disconnects the current customer Firebase App gracefully.
  Future<void> disconnectCustomerApp() async {
    if (_isTransitioning) return;
    _isTransitioning = true;
    try {
      await _deleteCurrentApp();
    } finally {
      _isTransitioning = false;
    }
  }

  /// Internal teardown helper — nulls references before deleting the app
  /// so concurrent readers get null rather than hitting a deleted app.
  Future<void> _deleteCurrentApp() async {
    if (_customerApp == null) return;

    // Null out the public references FIRST so callers stop using them.
    final appToDelete = _customerApp;
    _customerApp = null;
    _customerFirestore = null;
    _customerStorage = null;

    try {
      // Avoid calling appToDelete!.delete() directly as it can cause the native Firebase SDK
      // to invalidate the default FirebaseApp instance or detach platform channels,
      // leading to "FirebaseApp was deleted" exceptions on the master database.
      // Keeping the old named app references in memory is lightweight and safe.
      // await appToDelete!.delete();
    } catch (e) {
      debugPrint("Error deleting customer Firebase app: $e");
      // Non-fatal — the app might already be deleted.
    }
  }

  // ── Connection test ──────────────────────────────────────────────────

  /// Verifies connectivity to a customer Firebase project with a temporary
  /// write/read/delete cycle using a throwaway app instance.
  ///
  /// Returns `null` on success, or a descriptive error string on failure.
  Future<String?> testCustomerConnection(
    String projectId,
    String apiKey,
    String appId,
    String storageBucket,
  ) async {
    _connectionCounter++;
    final tempName = "temp_conn_test_$_connectionCounter";
    final options = FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      projectId: projectId,
      storageBucket: storageBucket,
      messagingSenderId: '',
    );

    FirebaseApp? tempApp;
    try {
      tempApp = await Firebase.initializeApp(name: tempName, options: options);
      final firestore = FirebaseFirestore.instanceFor(app: tempApp);

      final testRef = firestore.collection('_conn_test').doc('ping');
      await testRef
          .set({'timestamp': FieldValue.serverTimestamp(), 'success': true})
          .timeout(const Duration(seconds: 8));

      final snapshot =
          await testRef.get().timeout(const Duration(seconds: 8));
      final success =
          snapshot.exists && snapshot.data()?['success'] == true;

      try {
        await testRef.delete();
      } catch (_) {}

      return success ? null : 'Read-back verification failed. The document was not found after writing.';
    } on FirebaseException catch (e) {
      debugPrint("Connection test Firebase error for project $projectId: [${e.code}] ${e.message}");
      if (e.code == 'permission-denied' || e.code == 'PERMISSION_DENIED') {
        return 'PERMISSION_DENIED: Your Firebase project\'s Firestore security rules are '
            'blocking read/write access. Please go to your Firebase Console → '
            'Firestore Database → Rules, and set:\n\n'
            'rules_version = \'2\';\n'
            'service cloud.firestore {\n'
            '  match /databases/{database}/documents {\n'
            '    match /{document=**} {\n'
            '      allow read, write: if true;\n'
            '    }\n'
            '  }\n'
            '}\n\n'
            'Then click "Publish" and retry.';
      } else if (e.code == 'not-found') {
        return 'Project not found. Please verify the Firebase Project ID is correct.';
      } else if (e.code == 'unavailable') {
        return 'Firebase service is temporarily unavailable. Please check your internet connection and try again.';
      }
      return 'Firebase error: [${e.code}] ${e.message}';
    } catch (e) {
      debugPrint("Connection test failed for project $projectId: $e");
      final errStr = e.toString().toLowerCase();
      if (errStr.contains('timeout') || errStr.contains('deadline')) {
        return 'Connection timed out. Please verify the Project ID and API Key, and check your internet connection.';
      } else if (errStr.contains('invalid') || errStr.contains('api key')) {
        return 'Invalid API Key or App ID. Please double-check your Firebase credentials.';
      }
      return 'Connection failed: ${e.toString()}';
    } finally {
      // DO NOT call tempApp.delete() here as it invalidates the default FirebaseApp channel
      // and causes "FirebaseApp was deleted" exceptions on the master database.
    }
  }
}

// ── Provider ─────────────────────────────────────────────────────────────

final firebaseConnectionServiceProvider =
    Provider<FirebaseConnectionService>((ref) {
  return FirebaseConnectionService();
});
