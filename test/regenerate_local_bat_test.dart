import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/services/client_setup_package_generator.dart';
import 'package:smart_restaurant_pos/services/client_license_service.dart';

void main() {
  test('regenerate local setup bat and ps1 listener', () async {
    final appData = Platform.environment['APPDATA'] ?? '';
    final tokFile = File('$appData\\SmartBizz\\smartbizz_license.token');
    expect(tokFile.existsSync(), isTrue, reason: 'smartbizz_license.token must exist');

    final token = tokFile.readAsStringSync().trim();
    final payload = ClientLicenseService.verifyAndDecode(token);
    expect(payload, isNotNull, reason: 'Failed to verify and decode token');

    print('Decoded payload for: ${payload!.storeName} (${payload.orgId})');
    print('Tier: ${payload.tier}, Storage: ${payload.storageMode}');
    print('Allowed Roles: ${payload.allowedRoles}');
    print('kdsEnabled: ${payload.features['kdsEnabled']}');
    print('waiterOrdering: ${payload.features['waiterOrdering']}');

    // 1. Regenerate setup batch script in Downloads
    final batScript = ClientSetupPackageGenerator.generateBatchScript(payload, token);
    final batPath = 'C:\\Users\\santhosh\\Downloads\\SmartBizz_Setup_${payload.storeName.toLowerCase()}.bat';
    File(batPath).writeAsStringSync(batScript);
    print('Successfully regenerated $batPath (${batScript.length} bytes)');

    // 2. Regenerate active lan_hub_listener.ps1 in %APPDATA%\SmartBizz
    final ps1Script = ClientSetupPackageGenerator.generateLanHubListenerScript(token: token, port: 8085);
    final ps1Path = '$appData\\SmartBizz\\lan_hub_listener.ps1';
    File(ps1Path).writeAsStringSync(ps1Script);
    print('Successfully regenerated $ps1Path (${ps1Script.length} bytes)');

    expect(File(batPath).existsSync(), isTrue);
    expect(File(ps1Path).existsSync(), isTrue);
  });
}
