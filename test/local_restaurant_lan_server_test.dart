import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:smart_restaurant_pos/services/local_restaurant_lan_server.dart';

void main() {
  group('LocalRestaurantLanServer - Embedded LAN Hub Server', () {
    test('Starts server on free port and responds to /api/v1/ping', () async {
      final started = await LocalRestaurantLanServer.instance.startServer(port: 8899);
      expect(started, true);
      expect(LocalRestaurantLanServer.instance.isRunning, true);

      final url = Uri.parse('http://127.0.0.1:8899/api/v1/ping');
      final response = await http.get(url);

      expect(response.statusCode, 200);
      final json = jsonDecode(response.body) as Map<String, dynamic>;
      expect(json['status'], 'ok');
      expect(json['server'], 'SmartBizz Local LAN Hub');
      expect(json['port'], 8899);

      await LocalRestaurantLanServer.instance.stopServer();
      expect(LocalRestaurantLanServer.instance.isRunning, false);
    });

    test('Returns 404 for unknown endpoints', () async {
      await LocalRestaurantLanServer.instance.startServer(port: 8898);

      final url = Uri.parse('http://127.0.0.1:8898/api/v1/unknown');
      final response = await http.get(url);

      expect(response.statusCode, 404);

      await LocalRestaurantLanServer.instance.stopServer();
    });
  });
}
