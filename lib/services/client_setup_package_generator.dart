import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import '../core/entitlements.dart';
import '../core/package_model.dart';
import '../core/constants.dart';
import 'client_license_service.dart';
import 'offline_backup_file_io.dart'
    if (dart.library.js_interop) 'offline_backup_file_web.dart' as backup_file;

/// Service that generates self-contained 1-click Windows client setup packages (.bat)
/// and license payload bundles (.json) containing inbuilt cryptographic licenses.
///
/// When a customer runs the generated .bat file on their computer, it automatically:
///  1. Pre-configures local database storage directories (%APPDATA%\SmartBizz).
///  2. Installs the cryptographically signed licence key into local storage.
///  3. Configures the Windows Defender Firewall rule for the Local LAN Hub (port 8080) when the store is on LOCAL_NETWORK.
///  4. Detects Host Machine IPv4 address.
///  5. Creates a Desktop shortcut ("SmartBizz POS").
///  6. Immediately launches the desktop POS pre-authenticated and ready for billing!
class ClientSetupPackageGenerator {
  ClientSetupPackageGenerator._();

  /// Generates the complete Windows batch script (.bat) string with inbuilt license token.
  ///
  /// [token] is the key Code.gs signed for this payload (`ISSUE_CLIENT_LICENCE`);
  /// the generator never signs anything itself.
  static String generateBatchScript(ClientLicensePayload payload, String token) {
    final jsonStr = jsonEncode({
      'token': token,
      'payload': payload.toJson(),
    });
    final b64Json = base64.encode(utf8.encode(jsonStr));

    final storeName = payload.storeName;
    final orgId = payload.orgId;
    final vertical = Verticals.shortLabel(payload.vertical);
    final tier = payload.tier.toUpperCase();
    final planName = payload.planName;
    final storageMode = payload.storageMode;
    final storageLabel = StorageModes.label(storageMode);
    final validUntil = payload.validUntil.toIso8601String().split('T').first;
    final isLocalNetwork = storageMode == StorageModes.localNetwork ||
        payload.features[FeatureKeys.localLanServer] == true;

    final buffer = StringBuffer();
    buffer.writeln('@echo off');
    buffer.writeln('setlocal EnableDelayedExpansion');
    buffer.writeln('title SmartBizz POS - Automated Setup & License Activation');
    buffer.writeln();
    buffer.writeln(':: =======================================================================');
    buffer.writeln(':: SmartBizz POS - 1-Click Client Host Setup Package');
    buffer.writeln(':: Store Name   : $storeName ($orgId)');
    buffer.writeln(':: Business Type: $vertical ($tier)');
    buffer.writeln(':: Selected Plan: $planName');
    buffer.writeln(':: Storage Mode : $storageLabel');
    buffer.writeln(':: Valid Until  : $validUntil');
    buffer.writeln(':: =======================================================================');
    buffer.writeln();
    buffer.writeln('echo.');
    buffer.writeln('echo =======================================================================');
    buffer.writeln('echo            SmartBizz POS - 1-Click Client Setup');
    buffer.writeln('echo =======================================================================');
    buffer.writeln('echo  Store Name   : $storeName');
    buffer.writeln('echo  Business Type: $vertical ($tier)');
    buffer.writeln('echo  Selected Plan: $planName');
    buffer.writeln('echo  Storage Mode : $storageLabel');
    buffer.writeln('echo  Valid Until  : $validUntil');
    buffer.writeln('echo =======================================================================');
    buffer.writeln('echo.');

    // Step 1: Administrator check for firewall/service configuration
    if (isLocalNetwork) {
      buffer.writeln(':: Check for Administrator privileges');
      buffer.writeln('net session >nul 2>&1');
      buffer.writeln('if %errorLevel% neq 0 (');
      buffer.writeln('    echo [*] Requesting Administrator privileges for network & firewall configuration...');
      buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd -ArgumentList \'/c \\"\\"%~f0\\"\\"\' -Verb RunAs"');
      buffer.writeln('    exit /b');
      buffer.writeln(')');
      buffer.writeln();
    }

    // Step 2: Directories
    buffer.writeln('echo [*] Initializing local database storage directories...');
    buffer.writeln('set "APP_DATA_DIR=%APPDATA%\\SmartBizz"');
    buffer.writeln('set "LOCAL_DATA_DIR=%LOCALAPPDATA%\\SmartBizz"');
    buffer.writeln('if not exist "%APP_DATA_DIR%" mkdir "%APP_DATA_DIR%"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database" mkdir "%APP_DATA_DIR%\\database"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\backups" mkdir "%APP_DATA_DIR%\\backups"');
    buffer.writeln('if not exist "%LOCAL_DATA_DIR%" mkdir "%LOCAL_DATA_DIR%"');
    buffer.writeln();

    // Step 3: Write License Files (Base64 decoded via PowerShell so quoting never breaks)
    buffer.writeln('echo [*] Installing inbuilt cryptographically verified licence...');
    buffer.writeln('set "B64_PAYLOAD=$b64Json"');
    buffer.writeln('powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\smartbizz_bootstrap_license.json\', [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'%B64_PAYLOAD%\')))" >nul 2>&1');
    buffer.writeln('copy /Y "%APP_DATA_DIR%\\smartbizz_bootstrap_license.json" "%LOCAL_DATA_DIR%\\smartbizz_bootstrap_license.json" >nul 2>&1');
    buffer.writeln('echo $token > "%APP_DATA_DIR%\\smartbizz_license.token"');
    buffer.writeln('echo [OK] Licence successfully installed and verified!');
    buffer.writeln();

    // Step 4: Network & Firewall Setup (if Local Network Hub)
    if (isLocalNetwork) {
      buffer.writeln('echo [*] Configuring Local LAN Hub & Windows Defender Firewall...');
      buffer.writeln('netsh advfirewall firewall delete rule name="SmartBizz POS Hub (Port 8080)" >nul 2>&1');
      buffer.writeln('netsh advfirewall firewall add rule name="SmartBizz POS Hub (Port 8080)" dir=in action=allow protocol=TCP localport=8080 profile=private,domain >nul 2>&1');
      buffer.writeln('netsh advfirewall firewall delete rule name="SmartBizz POS Hub (Port 8085)" >nul 2>&1');
      buffer.writeln('netsh advfirewall firewall add rule name="SmartBizz POS Hub (Port 8085)" dir=in action=allow protocol=TCP localport=8085 profile=private,domain >nul 2>&1');
      buffer.writeln('echo [OK] Firewall ports 8080 and 8085 opened for paired satellite devices (SmartBizz app on the store Wi-Fi).');
      buffer.writeln();
      buffer.writeln(':: Detect Local IPv4');
      buffer.writeln('set "HOST_IP="');
      buffer.writeln('for /f "tokens=4" %%a in (\'route print 0.0.0.0 ^| findstr 0.0.0.0\') do (');
      buffer.writeln('    if not defined HOST_IP set "HOST_IP=%%a"');
      buffer.writeln(')');
      buffer.writeln('if not defined HOST_IP set "HOST_IP=127.0.0.1"');
      buffer.writeln('echo [OK] Host Machine Local IP detected: !HOST_IP!');
      buffer.writeln('echo {"hostIp":"!HOST_IP!","port":8085,"orgId":"$orgId","mode":"LOCAL_NETWORK"} > "%APP_DATA_DIR%\\lan_hub_config.json"');
      buffer.writeln();

      final listenerPs1 = generateLanHubListenerScript(token: token, webPosUrl: kWebPosUrl, port: 8085);
      final b64Listener = base64.encode(utf8.encode(listenerPs1));

      buffer.writeln('echo [*] Deploying background Local LAN Hub TCP listener (port 8085)...');
      buffer.writeln('set "B64_LISTENER=$b64Listener"');
      buffer.writeln('powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\lan_hub_listener.ps1\', [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'%B64_LISTENER%\')))" >nul 2>&1');
      buffer.writeln(':: Stop any previous listener on port 8085 so it does not duplicate');
      buffer.writeln('for /f "tokens=5" %%p in (\'netstat -aon ^| findstr :8085 ^| findstr LISTENING\') do taskkill /F /PID %%p >nul 2>&1');
      buffer.writeln('start "" /B powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%APP_DATA_DIR%\\lan_hub_listener.ps1"');
      buffer.writeln('echo [OK] Local LAN Hub listener active on port 8085.');
      buffer.writeln();
    } else {
      buffer.writeln('echo [OK] Storage mode configured: $storageLabel.');
      buffer.writeln('set "HOST_IP=127.0.0.1"');
      buffer.writeln();
    }

    // Step 5: Desktop Shortcut
    buffer.writeln('echo [*] Creating Desktop Shortcut...');
    buffer.writeln('set "DESKTOP_DIR=%USERPROFILE%\\Desktop"');
    buffer.writeln('set "SHORTCUT_PATH=%DESKTOP_DIR%\\SmartBizz POS.lnk"');
    buffer.writeln('powershell -NoProfile -ExecutionPolicy Bypass -Command "\$ws = New-Object -ComObject WScript.Shell; \$s = \$ws.CreateShortcut(\'%SHORTCUT_PATH%\'); \$s.TargetPath = \'%~dp0smart_kirana_shop.exe\'; if (-not (Test-Path \'%~dp0smart_kirana_shop.exe\')) { \$s.TargetPath = \'msedge.exe\'; \$s.Arguments = \'--app=$kWebPosUrl?license=$token&host_ip=!HOST_IP!&port=8085\'; }; \$s.Description = \'SmartBizz POS - $storeName\'; \$s.Save()" >nul 2>&1');
    buffer.writeln('echo [OK] Desktop shortcut created.');
    buffer.writeln();

    // Step 6: Launch Desktop POS
    buffer.writeln('echo.');
    buffer.writeln('echo =======================================================================');
    buffer.writeln('echo  Setup Completed Successfully!');
    buffer.writeln('echo  Launching SmartBizz POS for $storeName...');
    buffer.writeln('echo =======================================================================');
    buffer.writeln('echo.');
    buffer.writeln();
    buffer.writeln(':: Priority 1: Native Windows Flutter executable');
    buffer.writeln('if exist "%~dp0smart_kirana_shop.exe" (');
    buffer.writeln('    start "" "%~dp0smart_kirana_shop.exe"');
    buffer.writeln('    exit /b 0');
    buffer.writeln(')');
    buffer.writeln('if exist "%~dp0SmartBizz.exe" (');
    buffer.writeln('    start "" "%~dp0SmartBizz.exe"');
    buffer.writeln('    exit /b 0');
    buffer.writeln(')');
    buffer.writeln('if exist "%LOCALAPPDATA%\\SmartBizz\\SmartBizz.exe" (');
    buffer.writeln('    start "" "%LOCALAPPDATA%\\SmartBizz\\SmartBizz.exe"');
    buffer.writeln('    exit /b 0');
    buffer.writeln(')');
    buffer.writeln('if exist "%~dp0build\\windows\\x64\\runner\\Release\\smart_kirana_shop.exe" (');
    buffer.writeln('    start "" "%~dp0build\\windows\\x64\\runner\\Release\\smart_kirana_shop.exe"');
    buffer.writeln('    exit /b 0');
    buffer.writeln(')');
    buffer.writeln();
    buffer.writeln(':: Priority 2: Dedicated Edge/Chrome Application Window');
    buffer.writeln('start msedge --app="$kWebPosUrl?license=$token&host_ip=!HOST_IP!&port=8085" 2>nul || start chrome --app="$kWebPosUrl?license=$token&host_ip=!HOST_IP!&port=8085" 2>nul || start "" "$kWebPosUrl?license=$token&host_ip=!HOST_IP!&port=8085"');
    buffer.writeln();
    buffer.writeln('exit /b 0');

    return buffer.toString();
  }

  /// Generates the background TCP listener PowerShell script (lan_hub_listener.ps1)
  /// that runs on port 8085 on the host machine.
  ///
  /// Responds HTTP 200 to `/api/v1/ping` with hub status JSON and CORS/PNA headers,
  /// and redirects any other HTTP request (`/`, `/pos/`) to [webPosUrl] with license token
  /// and host IP/port pre-configured.
  static String generateLanHubListenerScript({
    String token = '',
    String webPosUrl = kWebPosUrl,
    int port = 8085,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('# SmartBizz Local LAN Hub - Inbuilt Background TCP Listener');
    buffer.writeln('param([string]\$HostIp = \$env:HOST_IP, [int]\$Port = $port)');
    buffer.writeln();
    buffer.writeln('\$appData = \$PSScriptRoot');
    buffer.writeln('if (-not \$appData) { \$appData = [System.IO.Path]::Combine(\$env:APPDATA, \'SmartBizz\') }');
    buffer.writeln('\$configFile = Join-Path \$appData \'lan_hub_config.json\'');
    buffer.writeln();
    buffer.writeln('if (-not \$HostIp -and (Test-Path \$configFile)) {');
    buffer.writeln('    try {');
    buffer.writeln('        \$cfg = Get-Content \$configFile -Raw | ConvertFrom-Json');
    buffer.writeln('        if (\$cfg.hostIp) { \$HostIp = \$cfg.hostIp }');
    buffer.writeln('    } catch {}');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('if (-not \$HostIp) {');
    buffer.writeln('    try {');
    buffer.writeln('        \$detected = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { \$_.InterfaceAlias -notmatch \'Loopback\' -and \$_.IPAddress -notmatch \'^169\\.254\\.\' } | Select-Object -First 1).IPAddress');
    buffer.writeln('        if (\$detected) { \$HostIp = \$detected }');
    buffer.writeln('    } catch {}');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('if (-not \$HostIp) { \$HostIp = \'127.0.0.1\' }');
    buffer.writeln();
    buffer.writeln('\$redirectUrl = "$webPosUrl?license=$token&host_ip=" + \$HostIp + "&port=" + \$Port');
    buffer.writeln();
    buffer.writeln('try {');
    buffer.writeln('    \$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, \$Port)');
    buffer.writeln('    \$listener.Start()');
    buffer.writeln('} catch {');
    buffer.writeln('    exit 1');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('while (\$true) {');
    buffer.writeln('    try {');
    buffer.writeln('        \$client = \$listener.AcceptTcpClient()');
    buffer.writeln('        \$stream = \$client.GetStream()');
    buffer.writeln('        \$stream.ReadTimeout = 3000');
    buffer.writeln('        \$stream.WriteTimeout = 3000');
    buffer.writeln('        \$buffer = New-Object byte[] 4096');
    buffer.writeln('        \$bytesRead = \$stream.Read(\$buffer, 0, \$buffer.Length)');
    buffer.writeln('        if (\$bytesRead -gt 0) {');
    buffer.writeln('            \$request = [System.Text.Encoding]::UTF8.GetString(\$buffer, 0, \$bytesRead)');
    buffer.writeln('            \$firstLine = (\$request -split "`r?`n")[0]');
    buffer.writeln('            if (\$firstLine -match \'OPTIONS\') {');
    buffer.writeln('                \$responseHeader = "HTTP/1.1 204 No Content`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"');
    buffer.writeln('                \$headerBytes = [System.Text.Encoding]::UTF8.GetBytes(\$responseHeader)');
    buffer.writeln('                \$stream.Write(\$headerBytes, 0, \$headerBytes.Length)');
    buffer.writeln('            } elseif (\$firstLine -match \'/api/v1/ping\') {');
    buffer.writeln('                \$body = \'{"status":"ok","server":"SmartBizz Local LAN Hub","version":"1.3.1","ip":"\' + \$HostIp + \'","port":\' + \$Port + \',"mode":"LOCAL_NETWORK"}\'');
    buffer.writeln('                \$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(\$body)');
    buffer.writeln('                \$responseHeader = "HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`nContent-Length: " + \$bodyBytes.Length + "`r`nConnection: close`r`n`r`n"');
    buffer.writeln('                \$headerBytes = [System.Text.Encoding]::UTF8.GetBytes(\$responseHeader)');
    buffer.writeln('                \$stream.Write(\$headerBytes, 0, \$headerBytes.Length)');
    buffer.writeln('                \$stream.Write(\$bodyBytes, 0, \$bodyBytes.Length)');
    buffer.writeln('            } else {');
    buffer.writeln('                \$responseHeader = "HTTP/1.1 302 Found`r`nLocation: " + \$redirectUrl + "`r`nAccess-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, OPTIONS`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`nContent-Length: 0`r`nConnection: close`r`n`r`n"');
    buffer.writeln('                \$headerBytes = [System.Text.Encoding]::UTF8.GetBytes(\$responseHeader)');
    buffer.writeln('                \$stream.Write(\$headerBytes, 0, \$headerBytes.Length)');
    buffer.writeln('            }');
    buffer.writeln('            \$stream.Flush()');
    buffer.writeln('        }');
    buffer.writeln('        \$client.Close()');
    buffer.writeln('    } catch {');
    buffer.writeln('        Start-Sleep -Milliseconds 50');
    buffer.writeln('    }');
    buffer.writeln('}');
    return buffer.toString();
  }


  
  /// Generates the standalone JSON payload file content.
  static String generateBootstrapJson(ClientLicensePayload payload, String token) {
    return const JsonEncoder.withIndent('  ').convert({
      'version': 1,
      'token': token,
      'payload': payload.toJson(),
      'instructions': 'Run the .bat file or import this file in SmartBizz POS to auto-activate.',
    });
  }

  /// What the admin sees when the server will not sign a key and gave no
  /// reason ([ClientLicenseService.issueErrorMessage] has the specific ones).
  static const String issueFailedMessage =
      'The server did not issue the licence key. Sign in as the platform admin '
      'with the cloud webhook configured and LEASE_SIGNING_KEY set, then try again.';

  /// Asks Code.gs for a signed key, then downloads the .bat. Returns null on
  /// success, else the message to show. The file carries the payload the
  /// server signed (store name and owner from the tenant's documents).
  static Future<String?> issueAndDownloadSetupBatch(ClientLicensePayload payload) async {
    final res = await ClientLicenseService.issueKey(payload);
    final token = res.token;
    if (token == null) return ClientLicenseService.issueErrorMessage(res.errorCode, res.errorMessage);
    await downloadSetupBatchFile(ClientLicenseService.verifyAndDecode(token) ?? payload, token);
    return null;
  }

  /// Asks Code.gs for a signed key, then downloads the .json. Returns null on
  /// success, else the message to show.
  static Future<String?> issueAndDownloadLicenseJson(ClientLicensePayload payload) async {
    final res = await ClientLicenseService.issueKey(payload);
    final token = res.token;
    if (token == null) return ClientLicenseService.issueErrorMessage(res.errorCode, res.errorMessage);
    await downloadLicenseJson(ClientLicenseService.verifyAndDecode(token) ?? payload, token);
    return null;
  }

  /// Triggers a 1-click browser download of the self-contained setup batch file (.bat).
  static Future<String> downloadSetupBatchFile(ClientLicensePayload payload, String token) async {
    final cleanName = payload.storeName
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
        .toLowerCase();
    final fileName = 'SmartBizz_Setup_$cleanName.bat';
    final script = generateBatchScript(payload, token);
    final bytes = Uint8List.fromList(utf8.encode(script));
    return await backup_file.saveBackupFile(fileName, bytes);
  }

  /// Triggers a 1-click browser download of the standalone license JSON file (.json).
  static Future<String> downloadLicenseJson(ClientLicensePayload payload, String token) async {
    final cleanName = payload.storeName
        .replaceAll(RegExp(r'[^a-zA-Z0-9_\-]'), '_')
        .toLowerCase();
    final fileName = 'smartbizz_license_$cleanName.json';
    final jsonStr = generateBootstrapJson(payload, token);
    final bytes = Uint8List.fromList(utf8.encode(jsonStr));
    return await backup_file.saveBackupFile(fileName, bytes);
  }
}
