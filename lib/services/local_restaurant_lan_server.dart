import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../core/restaurant_models.dart';
import 'customer_display_service.dart';
import 'kds_voice_announcer.dart';

/// Embedded Local LAN Server for Self-Hosted Restaurant Deployments.
///
/// Runs an in-process HTTP server on the primary POS till (Windows PC or Android terminal),
/// allowing Waiter Pads, Kitchen KDS screens, and Customer Displays on the local Wi-Fi
/// to exchange orders, table states, and ticket updates with 0ms WAN latency and
/// zero reliance on an active internet connection.
class LocalRestaurantLanServer {
  LocalRestaurantLanServer._();
  static final LocalRestaurantLanServer instance = LocalRestaurantLanServer._();

  HttpServer? _server;
  bool _isRunning = false;
  int _port = 8080;
  String? _localIpAddress;

  bool get isRunning => _isRunning;
  int get port => _port;
  String? get localIpAddress => _localIpAddress;
  String get serverUrl => 'http://${_localIpAddress ?? "localhost"}:$_port';

  /// Starts the embedded local LAN server on the master till.
  Future<bool> startServer({int port = 8080}) async {
    if (_isRunning) return true;
    _port = port;

    try {
      _localIpAddress = await _detectLocalIp();

      // Bind to all local interfaces (IPv4)
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _port,
        shared: true,
      );

      _isRunning = true;
      _server!.listen(_handleRequest, onError: (e) {
        debugPrint('LocalRestaurantLanServer error: $e');
      });

      debugPrint('LocalRestaurantLanServer running at $serverUrl');
      return true;
    } catch (e) {
      debugPrint('LocalRestaurantLanServer failed to start: $e');
      _isRunning = false;
      return false;
    }
  }

  /// Stops the local LAN server.
  Future<void> stopServer() async {
    if (!_isRunning || _server == null) return;
    try {
      await _server!.close(force: true);
    } catch (_) {}
    _server = null;
    _isRunning = false;
    debugPrint('LocalRestaurantLanServer stopped.');
  }

  // ---------------------------------------------------------------------------
  // Request Router
  // ---------------------------------------------------------------------------

  Future<void> _handleRequest(HttpRequest request) async {
    // Add CORS headers for web/tablet clients
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers.add(
      'Access-Control-Allow-Methods',
      'GET, POST, PUT, DELETE, OPTIONS',
    );
    request.response.headers.add(
      'Access-Control-Allow-Headers',
      'Content-Type, Authorization',
    );

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    final path = request.uri.path;

    try {
      if (path == '/api/v1/ping') {
        await _respondJson(request, {
          'status': 'ok',
          'server': 'SmartBizz Local LAN Hub',
          'version': '1.2.1',
          'ip': _localIpAddress,
          'port': _port,
          'timestamp': DateTime.now().toIso8601String(),
        });
      } else if (path == '/api/v1/tables' && request.method == 'GET') {
        await _handleGetTables(request);
      } else if (path == '/api/v1/kot' && request.method == 'POST') {
        await _handlePostKot(request);
      } else if (path == '/api/v1/kds/orders' && request.method == 'GET') {
        await _handleGetKdsOrders(request);
      } else if (path == '/api/v1/kds/status' && request.method == 'POST') {
        await _handleUpdateKdsStatus(request);
      } else if (path == '/api/v1/cfd' && request.method == 'GET') {
        await _respondJson(request, CustomerDisplayService.instance.snapshot.toMap());
      } else {
        request.response.statusCode = HttpStatus.notFound;
        await _respondJson(request, {'error': 'Endpoint not found'});
      }
    } catch (e) {
      debugPrint('LocalRestaurantLanServer request error: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      await _respondJson(request, {'error': e.toString()});
    }
  }

  // ---------------------------------------------------------------------------
  // Endpoint Handlers
  // ---------------------------------------------------------------------------

  Future<void> _handleGetTables(HttpRequest request) async {
    final list = <Map<String, dynamic>>[];
    if (Hive.isBoxOpen('restaurantTablesBox')) {
      final box = Hive.box('restaurantTablesBox');
      for (final key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          list.add(Map<String, dynamic>.from(val));
        }
      }
    }
    await _respondJson(request, {'tables': list});
  }

  Future<void> _handlePostKot(HttpRequest request) async {
    final bodyStr = await utf8.decodeStream(request);
    final map = jsonDecode(bodyStr) as Map<String, dynamic>;
    final order = KotOrder.fromMap(map, map['id']?.toString() ?? 'kot_${DateTime.now().millisecondsSinceEpoch}');

    // Persist to local Hive
    if (Hive.isBoxOpen('kotOrdersBox')) {
      final box = Hive.box('kotOrdersBox');
      await box.put(order.id, order.toMap());
    }

    // Trigger KDS acoustic chime and TTS announcement
    try {
      await KdsVoiceAnnouncer.instance.announceNewOrders([order]);
    } catch (_) {}

    await _respondJson(request, {
      'status': 'received',
      'kotNumber': order.kotNumber,
      'id': order.id,
    });
  }

  Future<void> _handleGetKdsOrders(HttpRequest request) async {
    final list = <Map<String, dynamic>>[];
    if (Hive.isBoxOpen('kotOrdersBox')) {
      final box = Hive.box('kotOrdersBox');
      for (final key in box.keys) {
        final val = box.get(key);
        if (val is Map) {
          list.add(Map<String, dynamic>.from(val));
        }
      }
    }
    await _respondJson(request, {'orders': list});
  }

  Future<void> _handleUpdateKdsStatus(HttpRequest request) async {
    final bodyStr = await utf8.decodeStream(request);
    final map = jsonDecode(bodyStr) as Map<String, dynamic>;
    final orderId = map['orderId']?.toString() ?? '';
    final newStatus = map['kitchenStatus']?.toString() ?? 'READY';

    if (Hive.isBoxOpen('kotOrdersBox') && orderId.isNotEmpty) {
      final box = Hive.box('kotOrdersBox');
      final existing = box.get(orderId);
      if (existing is Map) {
        final updated = Map<String, dynamic>.from(existing);
        updated['kitchenStatus'] = newStatus;
        if (newStatus == 'READY') {
          updated['readyAt'] = DateTime.now().toIso8601String();
        }
        await box.put(orderId, updated);
      }
    }

    await _respondJson(request, {'status': 'updated', 'orderId': orderId, 'kitchenStatus': newStatus});
  }

  Future<void> _respondJson(HttpRequest request, Map<String, dynamic> data) async {
    request.response.headers.contentType = ContentType.json;
    final jsonStr = jsonEncode(data);
    request.response.write(jsonStr);
    await request.response.close();
  }

  /// Detects the local LAN IPv4 address of the host machine (e.g. 192.168.1.x).
  Future<String> _detectLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback &&
              (addr.address.startsWith('192.168.') ||
                  addr.address.startsWith('10.') ||
                  addr.address.startsWith('172.'))) {
            return addr.address;
          }
        }
      }
    } catch (_) {}
    return '127.0.0.1';
  }
}
