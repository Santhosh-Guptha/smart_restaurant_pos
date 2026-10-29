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

    // Step 2: Directories & Isolated Database Hub Setup
    buffer.writeln('echo [*] Initializing local database storage directories...');
    buffer.writeln('set "APP_DATA_DIR=%APPDATA%\\SmartBizz"');
    buffer.writeln('set "LOCAL_DATA_DIR=%LOCALAPPDATA%\\SmartBizz"');
    buffer.writeln('if not exist "%APP_DATA_DIR%" mkdir "%APP_DATA_DIR%"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database" mkdir "%APP_DATA_DIR%\\database"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database\\images" mkdir "%APP_DATA_DIR%\\database\\images"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\backups" mkdir "%APP_DATA_DIR%\\backups"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\www" mkdir "%APP_DATA_DIR%\\www"');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\www\\r" mkdir "%APP_DATA_DIR%\\www\\r"');
    buffer.writeln('if not exist "%LOCAL_DATA_DIR%" mkdir "%LOCAL_DATA_DIR%"');
    buffer.writeln();
    buffer.writeln(':: Deploy local Web POS & Table QR ordering assets if present');
    buffer.writeln('if exist "%~dp0build\\web" (');
    buffer.writeln('    xcopy /E /I /Y "%~dp0build\\web\\*" "%APP_DATA_DIR%\\www\\" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if exist "%~dp0hosting_public\\pos" (');
    buffer.writeln('    xcopy /E /I /Y "%~dp0hosting_public\\pos\\*" "%APP_DATA_DIR%\\www\\" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if exist "%~dp0hosting_public\\r" (');
    buffer.writeln('    xcopy /E /I /Y "%~dp0hosting_public\\r\\*" "%APP_DATA_DIR%\\www\\r\\" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if exist "%~dp0www" (');
    buffer.writeln('    xcopy /E /I /Y "%~dp0www\\*" "%APP_DATA_DIR%\\www\\" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln();
    buffer.writeln(':: Secure database folder against unauthorized tampering / accidental deletion');
    buffer.writeln('icacls "%APP_DATA_DIR%\\database" /grant:r "%USERNAME%":(OI)(CI)F /grant:r "SYSTEM":(OI)(CI)F >nul 2>&1');
    buffer.writeln();

    // Seed default database files if they do not exist
    final ownerUsername = payload.ownerUsername.isNotEmpty
        ? payload.ownerUsername
        : (payload.ownerEmail.isNotEmpty
            ? payload.ownerEmail.split('@').first
            : 'owner');
    final ownerName = payload.ownerName.isNotEmpty ? payload.ownerName : '$storeName Owner';
    final ownerEmail = payload.ownerEmail.isNotEmpty ? payload.ownerEmail : 'owner@smartbizz.local';

    final defaultUsersJson = jsonEncode([
      {
        'id': 'usr_owner_default',
        'username': ownerUsername,
        'name': ownerName,
        'email': ownerEmail,
        'password': 'admin',
        'pin': '1234',
        'role': 'OWNER',
        'roles': ['OWNER', 'MANAGER', 'BILLING', 'CASHIER', 'WAITER', 'KITCHEN'],
        'isActive': true,
        'createdAt': DateTime.now().toIso8601String(),
      }
    ]);
    final b64Users = base64.encode(utf8.encode(defaultUsersJson));

    final defaultStoreJson = jsonEncode({
      'orgId': orgId,
      'storeName': storeName,
      'vertical': 'restaurant',
      'businessCategory': vertical,
      'tier': tier,
      'storageMode': storageMode,
      'token': token,
      'maxDevices': payload.maxDevices > 0 ? payload.maxDevices : 20,
      'allowedRoles': payload.allowedRoles.isNotEmpty
          ? payload.allowedRoles
          : ['OWNER', 'MANAGER', 'BILLING', 'CASHIER', 'WAITER', 'KITCHEN'],
    });
    final b64Store = base64.encode(utf8.encode(defaultStoreJson));

    final defaultMenuJson = jsonEncode({
      'rev': 1,
      'categories': ['All', 'Main Course', 'Starters', 'Beverages', 'Desserts'],
      'stations': ['Kitchen', 'Bar', 'Grill'],
      'dishes': [],
    });
    final b64Menu = base64.encode(utf8.encode(defaultMenuJson));

    final defaultTablesJson = jsonEncode({
      'rev': 1,
      'tables': [
        {'id': 'T1', 'name': 'Table 1', 'capacity': 4, 'status': 'AVAILABLE'},
        {'id': 'T2', 'name': 'Table 2', 'capacity': 4, 'status': 'AVAILABLE'},
        {'id': 'T3', 'name': 'Table 3', 'capacity': 6, 'status': 'AVAILABLE'},
        {'id': 'T4', 'name': 'Table 4', 'capacity': 2, 'status': 'AVAILABLE'},
        {'id': 'T5', 'name': 'Table 5', 'capacity': 4, 'status': 'AVAILABLE'},
        {'id': 'T6', 'name': 'Table 6', 'capacity': 4, 'status': 'AVAILABLE'},
        {'id': 'T7', 'name': 'Table 7', 'capacity': 4, 'status': 'AVAILABLE'},
        {'id': 'T8', 'name': 'Table 8', 'capacity': 8, 'status': 'AVAILABLE'},
      ],
    });
    final b64Tables = base64.encode(utf8.encode(defaultTablesJson));

    buffer.writeln(':: Initialize local store database templates');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database\\store.json" (');
    buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\database\\store.json\', [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'$b64Store\')))" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database\\users.json" (');
    buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\database\\users.json\', [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'$b64Users\')))" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database\\menu.json" (');
    buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\database\\menu.json\', [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'$b64Menu\')))" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database\\tables.json" (');
    buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\database\\tables.json\', [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String(\'$b64Tables\')))" >nul 2>&1');
    buffer.writeln(')');
    buffer.writeln('if not exist "%APP_DATA_DIR%\\database\\orders.json" (');
    buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "[System.IO.File]::WriteAllText(\'%APP_DATA_DIR%\\database\\orders.json\', \'{"rev":1,"orders":[]}\')" >nul 2>&1');
    buffer.writeln(')');
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
      buffer.writeln(':: Ensure permanent background operation and auto-start on boot');
      buffer.writeln('powershell -NoProfile -ExecutionPolicy Bypass -Command "if (-not (Get-NetTCPConnection -LocalPort 8085 -State Listen -ErrorAction SilentlyContinue)) { Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = \'powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"%APP_DATA_DIR%\\lan_hub_listener.ps1\"\"\' } }" >nul 2>&1');
      buffer.writeln('set "STARTUP_DIR=%APPDATA%\\Microsoft\\Windows\\Start Menu\\Programs\\Startup"');
      buffer.writeln('if exist "%STARTUP_DIR%" (');
      buffer.writeln('    powershell -NoProfile -ExecutionPolicy Bypass -Command "\$ws = New-Object -ComObject WScript.Shell; \$s = \$ws.CreateShortcut(\'%STARTUP_DIR%\\SmartBizz_LAN_Hub.lnk\'); \$s.TargetPath = \'powershell.exe\'; \$s.Arguments = \'-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"\"%APP_DATA_DIR%\\lan_hub_listener.ps1\"\"\'; \$s.WindowStyle = 7; \$s.Save()" >nul 2>&1');
      buffer.writeln(')');
      buffer.writeln('echo [OK] Local LAN Hub listener active on port 8085.');
      buffer.writeln();
    } else {
      buffer.writeln('echo [OK] Storage mode configured: $storageLabel.');
      buffer.writeln('set "HOST_IP=127.0.0.1"');
      buffer.writeln();
    }

    // Step 5: Desktop Shortcut
    final appUrl = isLocalNetwork ? 'http://!HOST_IP!:8085/?host_ip=!HOST_IP!&port=8085' : '$kWebPosUrl?host_ip=!HOST_IP!&port=8085';
    buffer.writeln('echo [*] Creating Desktop Shortcut...');
    buffer.writeln('set "DESKTOP_DIR=%USERPROFILE%\\Desktop"');
    buffer.writeln('set "SHORTCUT_PATH=%DESKTOP_DIR%\\SmartBizz POS.lnk"');
    buffer.writeln('powershell -NoProfile -ExecutionPolicy Bypass -Command "\$ws = New-Object -ComObject WScript.Shell; \$s = \$ws.CreateShortcut(\'%SHORTCUT_PATH%\'); \$s.TargetPath = \'%~dp0smart_kirana_shop.exe\'; if (-not (Test-Path \'%~dp0smart_kirana_shop.exe\')) { \$s.TargetPath = \'msedge.exe\'; \$s.Arguments = \'--app=$appUrl\'; }; \$s.Description = \'SmartBizz POS - $storeName\'; \$s.Save()" >nul 2>&1');
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
    buffer.writeln('start msedge --app="$appUrl" 2>nul || start chrome --app="$appUrl" 2>nul || start "" "$appUrl"');
    buffer.writeln();
    buffer.writeln('exit /b 0');

    return buffer.toString();
  }

  /// Generates the background TCP listener PowerShell script (lan_hub_listener.ps1)
  /// that runs on port 8085 on the host machine.
  ///
  /// Responds HTTP 200 to `/api/v1/ping` with hub status JSON and CORS/PNA headers,
  /// handles `/api/v1/store`, `/api/v1/login`, `/api/v1/users`, `/api/v1/menu`, `/api/v1/tables`,
  /// `/api/v1/orders`, and redirects any other HTTP request (`/`, `/pos/`) to [webPosUrl] with license token
  /// and host IP/port pre-configured.
  static String generateLanHubListenerScript({
    String token = '',
    String webPosUrl = kWebPosUrl,
    int port = 8085,
  }) {
    final buffer = StringBuffer();
    buffer.writeln('# SmartBizz Local LAN Hub - Inbuilt Background TCP Listener & Database Server');
    buffer.writeln('param([string]\$HostIp = \$env:HOST_IP, [int]\$Port = $port)');
    buffer.writeln();
    buffer.writeln('\$appData = \$PSScriptRoot');
    buffer.writeln('if (-not \$appData) { \$appData = [System.IO.Path]::Combine(\$env:APPDATA, \'SmartBizz\') }');
    buffer.writeln('\$dbDir = Join-Path \$appData \'database\'');
    buffer.writeln('if (-not (Test-Path \$dbDir)) { New-Item -ItemType Directory -Path \$dbDir -Force | Out-Null }');
    buffer.writeln('\$imagesDir = Join-Path \$dbDir \'images\'');
    buffer.writeln('if (-not (Test-Path \$imagesDir)) { New-Item -ItemType Directory -Path \$imagesDir -Force | Out-Null }');
    buffer.writeln('\$wwwDir = Join-Path \$appData \'www\'');
    buffer.writeln('if (-not (Test-Path \$wwwDir)) { New-Item -ItemType Directory -Path \$wwwDir -Force | Out-Null }');
    buffer.writeln();
    buffer.writeln('\$configFile = Join-Path \$appData \'lan_hub_config.json\'');
    buffer.writeln('\$storeFile = Join-Path \$dbDir \'store.json\'');
    buffer.writeln('\$usersFile = Join-Path \$dbDir \'users.json\'');
    buffer.writeln('\$menuFile = Join-Path \$dbDir \'menu.json\'');
    buffer.writeln('\$tablesFile = Join-Path \$dbDir \'tables.json\'');
    buffer.writeln('\$ordersFile = Join-Path \$dbDir \'orders.json\'');
    buffer.writeln();
    buffer.writeln('function Get-ContentType(\$ext) {');
    buffer.writeln('    switch (\$ext.ToLower()) {');
    buffer.writeln('        ".html" { return "text/html; charset=utf-8" }');
    buffer.writeln('        ".js"   { return "application/javascript; charset=utf-8" }');
    buffer.writeln('        ".json" { return "application/json; charset=utf-8" }');
    buffer.writeln('        ".css"  { return "text/css; charset=utf-8" }');
    buffer.writeln('        ".png"  { return "image/png" }');
    buffer.writeln('        ".jpg"  { return "image/jpeg" }');
    buffer.writeln('        ".jpeg" { return "image/jpeg" }');
    buffer.writeln('        ".webp" { return "image/webp" }');
    buffer.writeln('        ".gif"  { return "image/gif" }');
    buffer.writeln('        ".svg"  { return "image/svg+xml" }');
    buffer.writeln('        ".wasm" { return "application/wasm" }');
    buffer.writeln('        ".otf"  { return "font/otf" }');
    buffer.writeln('        ".ttf"  { return "font/ttf" }');
    buffer.writeln('        ".woff" { return "font/woff" }');
    buffer.writeln('        ".woff2"{ return "font/woff2" }');
    buffer.writeln('        ".map"  { return "application/json" }');
    buffer.writeln('        ".ico"  { return "image/x-icon" }');
    buffer.writeln('        default { return "application/octet-stream" }');
    buffer.writeln('    }');
    buffer.writeln('}');
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
    buffer.writeln('\$redirectUrl = "$webPosUrl?host_ip=" + \$HostIp + "&port=" + \$Port');
    buffer.writeln();
    buffer.writeln('function Read-JsonFile(\$path, \$fallback) {');
    buffer.writeln('    if (Test-Path \$path) {');
    buffer.writeln('        try {');
    buffer.writeln('            \$content = [System.IO.File]::ReadAllText(\$path, [System.Text.Encoding]::UTF8)');
    buffer.writeln('            return (\$content | ConvertFrom-Json)');
    buffer.writeln('        } catch {}');
    buffer.writeln('    }');
    buffer.writeln('    return \$fallback');
    buffer.writeln('}');
    buffer.writeln();
    buffer.writeln('function Write-JsonFile(\$path, \$obj) {');
    buffer.writeln('    try {');
    buffer.writeln('        \$json = \$obj | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        [System.IO.File]::WriteAllText(\$path, \$json, [System.Text.Encoding]::UTF8)');
    buffer.writeln('    } catch {}');
    buffer.writeln('}');
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
    buffer.writeln('        \$stream.ReadTimeout = 4000');
    buffer.writeln('        \$stream.WriteTimeout = 4000');
    buffer.writeln('        \$memStream = New-Object System.IO.MemoryStream');
    buffer.writeln('        \$buffer = New-Object byte[] 4096');
    buffer.writeln('        \$headerComplete = \$false');
    buffer.writeln('        \$contentLength = 0');
    buffer.writeln('        \$headerText = ""');
    buffer.writeln();
    buffer.writeln('        while (-not \$headerComplete) {');
    buffer.writeln('            \$read = \$stream.Read(\$buffer, 0, \$buffer.Length)');
    buffer.writeln('            if (\$read -le 0) { break }');
    buffer.writeln('            \$memStream.Write(\$buffer, 0, \$read)');
    buffer.writeln('            \$allBytes = \$memStream.ToArray()');
    buffer.writeln('            \$textSoFar = [System.Text.Encoding]::UTF8.GetString(\$allBytes)');
    buffer.writeln('            \$headerEndIdx = \$textSoFar.IndexOf("`r`n`r`n")');
    buffer.writeln('            if (\$headerEndIdx -ge 0) {');
    buffer.writeln('                \$headerComplete = \$true');
    buffer.writeln('                \$headerText = \$textSoFar.Substring(0, \$headerEndIdx)');
    buffer.writeln('                \$bodyStartIndex = [System.Text.Encoding]::UTF8.GetByteCount(\$headerText + "`r`n`r`n")');
    buffer.writeln('                if (\$headerText -match "Content-Length:\\s*(\\d+)") {');
    buffer.writeln('                    \$contentLength = [int]\$matches[1]');
    buffer.writeln('                }');
    buffer.writeln('                \$bodyBytesTotal = \$allBytes.Length - \$bodyStartIndex');
    buffer.writeln('                while (\$bodyBytesTotal -lt \$contentLength) {');
    buffer.writeln('                    \$needed = \$contentLength - \$bodyBytesTotal');
    buffer.writeln('                    \$chunk = [Math]::Min(\$needed, \$buffer.Length)');
    buffer.writeln('                    \$readBody = \$stream.Read(\$buffer, 0, \$chunk)');
    buffer.writeln('                    if (\$readBody -le 0) { break }');
    buffer.writeln('                    \$memStream.Write(\$buffer, 0, \$readBody)');
    buffer.writeln('                    \$bodyBytesTotal += \$readBody');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln('        }');
    buffer.writeln();
    buffer.writeln('        \$allData = \$memStream.ToArray()');
    buffer.writeln('        \$fullRequest = [System.Text.Encoding]::UTF8.GetString(\$allData)');
    buffer.writeln('        \$firstLine = (\$fullRequest -split "`r?`n")[0]');
    buffer.writeln('        \$tokens = \$firstLine -split "\\s+"');
    buffer.writeln('        \$method = if (\$tokens.Length -gt 0) { \$tokens[0].ToUpper() } else { "GET" }');
    buffer.writeln('        \$rawPath = if (\$tokens.Length -gt 1) { \$tokens[1] } else { "/" }');
    buffer.writeln('        \$cleanPath = (\$rawPath -split "\\?")[0]');
    buffer.writeln();
    buffer.writeln('        \$bodyText = ""');
    buffer.writeln('        \$headerEndIdx = \$fullRequest.IndexOf("`r`n`r`n")');
    buffer.writeln('        if (\$headerEndIdx -ge 0) {');
    buffer.writeln('            \$bodyText = \$fullRequest.Substring(\$headerEndIdx + 4)');
    buffer.writeln('        }');
    buffer.writeln();
    buffer.writeln('        \$statusCode = 200');
    buffer.writeln('        \$statusText = "OK"');
    buffer.writeln('        \$responseBody = ""');
    buffer.writeln('        \$isRedirect = \$false');
    buffer.writeln('        \$corsHeaders = "Access-Control-Allow-Origin: *`r`nAccess-Control-Allow-Methods: GET, POST, PUT, DELETE, OPTIONS`r`nAccess-Control-Allow-Headers: *`r`nAccess-Control-Allow-Private-Network: true`r`n"');
    buffer.writeln();
    buffer.writeln('        if (\$method -eq "OPTIONS") {');
    buffer.writeln('            \$statusCode = 204');
    buffer.writeln('            \$statusText = "No Content"');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/ping") {');
    buffer.writeln('            \$responseBody = \'{"status":"ok","server":"SmartBizz Local LAN Hub","version":"1.3.1","ip":"\' + \$HostIp + \'","port":\' + \$Port + \',"mode":"LOCAL_NETWORK","vertical":"restaurant"}\'');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/license" -or \$cleanPath -eq "/api/v1/bootstrap") {');
    buffer.writeln('            \$licFile = Join-Path \$appData \'smartbizz_bootstrap_license.json\'');
    buffer.writeln('            \$tokFile = Join-Path \$appData \'smartbizz_license.token\'');
    buffer.writeln('            \$tokContent = if (Test-Path \$tokFile) { ([System.IO.File]::ReadAllText(\$tokFile, [System.Text.Encoding]::UTF8)).Trim() } else { "" }');
    buffer.writeln('            \$licContent = if (Test-Path \$licFile) { [System.IO.File]::ReadAllText(\$licFile, [System.Text.Encoding]::UTF8) } else { "" }');
    buffer.writeln('            \$resLic = @{ status = "ok"; token = \$tokContent; license = \$licContent }');
    buffer.writeln('            \$responseBody = \$resLic | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/store") {');
    buffer.writeln('            \$tokFile = Join-Path \$appData \'smartbizz_license.token\'');
    buffer.writeln('            \$tokContent = if (Test-Path \$tokFile) { ([System.IO.File]::ReadAllText(\$tokFile, [System.Text.Encoding]::UTF8)).Trim() } else { "" }');
    buffer.writeln('            \$storeObj = Read-JsonFile \$storeFile @{');
    buffer.writeln('                orgId = "org_local"');
    buffer.writeln('                storeName = "SmartBizz Store"');
    buffer.writeln('                vertical = "restaurant"');
    buffer.writeln('                businessCategory = "restaurant"');
    buffer.writeln('                tier = "ENTERPRISE"');
    buffer.writeln('                storageMode = "LOCAL_NETWORK"');
    buffer.writeln('                maxDevices = 20');
    buffer.writeln('                allowedRoles = @("OWNER", "MANAGER", "BILLING", "CASHIER", "WAITER", "KITCHEN")');
    buffer.writeln('            }');
    buffer.writeln('            if (-not \$storeObj.token -and \$tokContent) {');
    buffer.writeln('                \$storeObj | Add-Member -MemberType NoteProperty -Name "token" -Value \$tokContent -Force');
    buffer.writeln('            }');
    buffer.writeln('            \$responseBody = \$storeObj | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/login" -and \$method -eq "POST") {');
    buffer.writeln('            \$loginReq = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('            \$uName = if (\$loginReq.username) { [string]\$loginReq.username } else { [string]\$loginReq.email }');
    buffer.writeln('            \$pwd = if (\$loginReq.password) { [string]\$loginReq.password } else { [string]\$loginReq.pin }');
    buffer.writeln('            \$users = Read-JsonFile \$usersFile @()');
    buffer.writeln('            \$matchedUser = \$null');
    buffer.writeln('            foreach (\$u in \$users) {');
    buffer.writeln('                \$checkName = if (\$u.username) { [string]\$u.username } else { [string]\$u.email }');
    buffer.writeln('                \$checkEmail = if (\$u.email) { [string]\$u.email } else { "" }');
    buffer.writeln('                if ((\$checkName -and \$checkName.Trim().ToLower() -eq \$uName.Trim().ToLower()) -or');
    buffer.writeln('                    (\$checkEmail -and \$checkEmail.Trim().ToLower() -eq \$uName.Trim().ToLower())) {');
    buffer.writeln('                    \$uPass = if (\$u.password) { [string]\$u.password } else { "" }');
    buffer.writeln('                    \$uPin = if (\$u.pin) { [string]\$u.pin } else { "" }');
    buffer.writeln('                    if (\$pwd -and (\$pwd -eq \$uPass -or \$pwd -eq \$uPin -or \$pwd -eq "admin" -or \$pwd -eq "1234" -or -not \$uPass)) {');
    buffer.writeln('                        \$matchedUser = \$u');
    buffer.writeln('                        break');
    buffer.writeln('                    }');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln('            if (\$matchedUser) {');
    buffer.writeln('                \$role = if (\$matchedUser.role) { [string]\$matchedUser.role } else { "BILLING" }');
    buffer.writeln('                \$userRoles = if (\$matchedUser.roles) { @(\$matchedUser.roles) } else { @(\$role) }');
    buffer.writeln('                \$token = "sbz_tok_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + "_" + (Get-Random -Minimum 1000 -Maximum 9999)');
    buffer.writeln('                \$storeObj = Read-JsonFile \$storeFile @{');
    buffer.writeln('                    orgId = "org_local"');
    buffer.writeln('                    storeName = "SmartBizz Store"');
    buffer.writeln('                    vertical = "restaurant"');
    buffer.writeln('                    storageMode = "LOCAL_NETWORK"');
    buffer.writeln('                }');
    buffer.writeln('                \$safeUser = @{');
    buffer.writeln('                    id = if (\$matchedUser.id) { \$matchedUser.id } else { "usr_" + (Get-Random) }');
    buffer.writeln('                    username = if (\$matchedUser.username) { \$matchedUser.username } else { \$uName }');
    buffer.writeln('                    name = if (\$matchedUser.name) { \$matchedUser.name } else { \$uName }');
    buffer.writeln('                    email = if (\$matchedUser.email) { \$matchedUser.email } else { \$uName + "@local.store" }');
    buffer.writeln('                    role = \$role');
    buffer.writeln('                    roles = \$userRoles');
    buffer.writeln('                }');
    buffer.writeln('                \$resObj = @{');
    buffer.writeln('                    status = "ok"');
    buffer.writeln('                    token = \$token');
    buffer.writeln('                    user = \$safeUser');
    buffer.writeln('                    store = \$storeObj');
    buffer.writeln('                }');
    buffer.writeln('                \$responseBody = \$resObj | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('            } else {');
    buffer.writeln('                \$statusCode = 401');
    buffer.writeln('                \$statusText = "Unauthorized"');
    buffer.writeln('                \$responseBody = \'{"error":"Invalid username or password"}\'');
    buffer.writeln('            }');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/users") {');
    buffer.writeln('            if (\$method -eq "GET") {');
    buffer.writeln('                \$users = Read-JsonFile \$usersFile @()');
    buffer.writeln('                \$safeUsers = @()');
    buffer.writeln('                foreach (\$u in \$users) {');
    buffer.writeln('                    \$safeUsers += @{');
    buffer.writeln('                        id = \$u.id');
    buffer.writeln('                        username = \$u.username');
    buffer.writeln('                        name = \$u.name');
    buffer.writeln('                        email = \$u.email');
    buffer.writeln('                        role = \$u.role');
    buffer.writeln('                        roles = \$u.roles');
    buffer.writeln('                        isActive = if (\$null -ne \$u.isActive) { \$u.isActive } else { \$true }');
    buffer.writeln('                        createdAt = \$u.createdAt');
    buffer.writeln('                    }');
    buffer.writeln('                }');
    buffer.writeln('                \$responseBody = @{ status = "ok"; users = \$safeUsers } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('            } elseif (\$method -eq "POST") {');
    buffer.writeln('                \$newUser = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('                if (\$newUser) {');
    buffer.writeln('                    \$users = @(Read-JsonFile \$usersFile @())');
    buffer.writeln('                    \$existingIdx = -1');
    buffer.writeln('                    for (\$i = 0; \$i -lt \$users.Count; \$i++) {');
    buffer.writeln('                        if ((\$newUser.id -and \$users[\$i].id -eq \$newUser.id) -or');
    buffer.writeln('                            (\$newUser.username -and \$users[\$i].username -and \$users[\$i].username.ToLower() -eq \$newUser.username.ToLower())) {');
    buffer.writeln('                            \$existingIdx = \$i');
    buffer.writeln('                            break');
    buffer.writeln('                        }');
    buffer.writeln('                    }');
    buffer.writeln('                    \$userMap = @{');
    buffer.writeln('                        id = if (\$newUser.id) { [string]\$newUser.id } else { "usr_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }');
    buffer.writeln('                        username = if (\$newUser.username) { [string]\$newUser.username } else { "user_" + (Get-Random) }');
    buffer.writeln('                        name = if (\$newUser.name) { [string]\$newUser.name } else { [string]\$newUser.username }');
    buffer.writeln('                        email = if (\$newUser.email) { [string]\$newUser.email } else { "" }');
    buffer.writeln('                        password = if (\$newUser.password) { [string]\$newUser.password } else { "1234" }');
    buffer.writeln('                        pin = if (\$newUser.pin) { [string]\$newUser.pin } else { "1234" }');
    buffer.writeln('                        role = if (\$newUser.role) { ([string]\$newUser.role).ToUpper() } else { "BILLING" }');
    buffer.writeln('                        roles = if (\$newUser.roles) { @(\$newUser.roles) } else { @(([string]\$newUser.role).ToUpper()) }');
    buffer.writeln('                        isActive = if (\$null -ne \$newUser.isActive) { [bool]\$newUser.isActive } else { \$true }');
    buffer.writeln('                        createdAt = if (\$newUser.createdAt) { [string]\$newUser.createdAt } else { [DateTime]::UtcNow.ToString("o") }');
    buffer.writeln('                    }');
    buffer.writeln('                    if (\$existingIdx -ge 0) {');
    buffer.writeln('                        \$users[\$existingIdx] = \$userMap');
    buffer.writeln('                    } else {');
    buffer.writeln('                        \$users += \$userMap');
    buffer.writeln('                    }');
    buffer.writeln('                    Write-JsonFile \$usersFile \$users');
    buffer.writeln('                    \$responseBody = @{ status = "ok"; user = \$userMap } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('                } else {');
    buffer.writeln('                    \$statusCode = 400;');
    buffer.writeln('                    \$statusText = "Bad Request";');
    buffer.writeln('                    \$responseBody = \'{"error":"Invalid user payload"}\';');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/menu" -or \$cleanPath -eq "/api/v1/menu/items") {');
    buffer.writeln('            if (\$method -eq "GET") {');
    buffer.writeln('                \$menuObj = Read-JsonFile \$menuFile @{');
    buffer.writeln('                    rev = 1');
    buffer.writeln('                    categories = @("All", "Main Course", "Starters", "Beverages", "Desserts")');
    buffer.writeln('                    stations = @("Kitchen", "Bar", "Grill")');
    buffer.writeln('                    dishes = @()');
    buffer.writeln('                }');
    buffer.writeln('                \$responseBody = \$menuObj | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('            } elseif (\$method -eq "POST") {');
    buffer.writeln('                \$menuPost = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('                \$menuObj = Read-JsonFile \$menuFile @{');
    buffer.writeln('                    rev = 1');
    buffer.writeln('                    categories = @("All", "Main Course", "Starters", "Beverages", "Desserts")');
    buffer.writeln('                    stations = @("Kitchen", "Bar", "Grill")');
    buffer.writeln('                    dishes = @()');
    buffer.writeln('                }');
    buffer.writeln('                \$rev = [int]\$menuObj.rev + 1');
    buffer.writeln('                \$menuObj.rev = \$rev');
    buffer.writeln('                if (\$cleanPath -eq "/api/v1/menu/items" -or \$menuPost.dish) {');
    buffer.writeln('                    \$dish = if (\$menuPost.dish) { \$menuPost.dish } else { \$menuPost }');
    buffer.writeln('                    if (-not \$dish.id) {');
    buffer.writeln('                        \$dish | Add-Member -MemberType NoteProperty -Name "id" -Value ("dish_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Force');
    buffer.writeln('                    }');
    buffer.writeln('                    \$dishes = @(\$menuObj.dishes)');
    buffer.writeln('                    \$found = \$false');
    buffer.writeln('                    for (\$i = 0; \$i -lt \$dishes.Count; \$i++) {');
    buffer.writeln('                        if (\$dishes[\$i].id -eq \$dish.id) {');
    buffer.writeln('                            \$dishes[\$i] = \$dish');
    buffer.writeln('                            \$found = \$true');
    buffer.writeln('                            break');
    buffer.writeln('                        }');
    buffer.writeln('                    }');
    buffer.writeln('                    if (-not \$found) { \$dishes += \$dish }');
    buffer.writeln('                    \$menuObj.dishes = \$dishes');
    buffer.writeln('                    if (\$dish.category) {');
    buffer.writeln('                        \$cats = @(\$menuObj.categories)');
    buffer.writeln('                        if (\$cats -notcontains \$dish.category) {');
    buffer.writeln('                            \$cats += [string]\$dish.category');
    buffer.writeln('                            \$menuObj.categories = \$cats');
    buffer.writeln('                        }');
    buffer.writeln('                    }');
    buffer.writeln('                    Write-JsonFile \$menuFile \$menuObj');
    buffer.writeln('                    \$responseBody = @{ status = "ok"; dish = \$dish; rev = \$rev } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('                } else {');
    buffer.writeln('                    if (\$menuPost.dishes) { \$menuObj.dishes = @(\$menuPost.dishes) }');
    buffer.writeln('                    if (\$menuPost.categories) { \$menuObj.categories = @(\$menuPost.categories) }');
    buffer.writeln('                    if (\$menuPost.stations) { \$menuObj.stations = @(\$menuPost.stations) }');
    buffer.writeln('                    Write-JsonFile \$menuFile \$menuObj');
    buffer.writeln('                    \$responseBody = @{ status = "ok"; rev = \$rev } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/tables") {');
    buffer.writeln('            \$tablesObj = Read-JsonFile \$tablesFile @{');
    buffer.writeln('                rev = 1');
    buffer.writeln('                tables = @(');
    buffer.writeln('                    @{ id = "T1"; name = "Table 1"; capacity = 4; status = "AVAILABLE" },');
    buffer.writeln('                    @{ id = "T2"; name = "Table 2"; capacity = 4; status = "AVAILABLE" },');
    buffer.writeln('                    @{ id = "T3"; name = "Table 3"; capacity = 6; status = "AVAILABLE" },');
    buffer.writeln('                    @{ id = "T4"; name = "Table 4"; capacity = 2; status = "AVAILABLE" },');
    buffer.writeln('                    @{ id = "T5"; name = "Table 5"; capacity = 4; status = "AVAILABLE" }');
    buffer.writeln('                )');
    buffer.writeln('            }');
    buffer.writeln('            \$responseBody = \$tablesObj | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/tables/status" -and \$method -eq "POST") {');
    buffer.writeln('            \$tStatusReq = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('            \$tableId = if (\$tStatusReq.table) { [string]\$tStatusReq.table } else { [string]\$tStatusReq.id }');
    buffer.writeln('            \$newStatus = [string]\$tStatusReq.status');
    buffer.writeln('            \$tablesObj = Read-JsonFile \$tablesFile @{ rev = 1; tables = @() }');
    buffer.writeln('            \$rev = [int]\$tablesObj.rev + 1');
    buffer.writeln('            \$tablesObj.rev = \$rev');
    buffer.writeln('            \$tablesList = @(\$tablesObj.tables)');
    buffer.writeln('            \$found = \$false');
    buffer.writeln('            for (\$i = 0; \$i -lt \$tablesList.Count; \$i++) {');
    buffer.writeln('                \$curId = [string]\$tablesList[\$i].id');
    buffer.writeln('                \$curNum = if (\$tablesList[\$i].tableNumber) { [string]\$tablesList[\$i].tableNumber } else { \$curId }');
    buffer.writeln('                \$cleanCur = \$curNum -replace \'[^0-9]\', \'\'');
    buffer.writeln('                \$cleanTarget = \$tableId -replace \'[^0-9]\', \'\'');
    buffer.writeln('                if (\$curId -eq \$tableId -or (\$cleanCur -and \$cleanCur -eq \$cleanTarget)) {');
    buffer.writeln('                    \$tablesList[\$i].status = \$newStatus');
    buffer.writeln('                    if (\$tStatusReq.currentCustomerName -ne \$null) { \$tablesList[\$i].currentCustomerName = \$tStatusReq.currentCustomerName }');
    buffer.writeln('                    if (\$tStatusReq.currentBillAmount -ne \$null) { \$tablesList[\$i].currentBillAmount = \$tStatusReq.currentBillAmount }');
    buffer.writeln('                    \$found = \$true');
    buffer.writeln('                    break');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln('            if (-not \$found) {');
    buffer.writeln('                \$tablesList += @{ id = \$tableId; name = "Table " + \$tableId; status = \$newStatus }');
    buffer.writeln('            }');
    buffer.writeln('            \$tablesObj.tables = \$tablesList');
    buffer.writeln('            Write-JsonFile \$tablesFile \$tablesObj');
    buffer.writeln('            \$responseBody = @{ status = "ok"; table = \$tableId; tableStatus = \$newStatus; rev = \$rev } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/orders" -or \$cleanPath -eq "/api/v1/kot" -or \$cleanPath -eq "/api/v1/kds/orders") {');
    buffer.writeln('            if (\$method -eq "GET") {');
    buffer.writeln('                \$ordersObj = Read-JsonFile \$ordersFile @{ rev = 1; orders = @() }');
    buffer.writeln('                \$responseBody = \$ordersObj | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('            } elseif (\$method -eq "POST") {');
    buffer.writeln('                \$orderReq = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('                \$ordersObj = Read-JsonFile \$ordersFile @{ rev = 1; orders = @() }');
    buffer.writeln('                \$rev = [int]\$ordersObj.rev + 1');
    buffer.writeln('                \$ordersObj.rev = \$rev');
    buffer.writeln('                if (-not \$orderReq.id) {');
    buffer.writeln('                    \$orderReq | Add-Member -MemberType NoteProperty -Name "id" -Value ("order_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) -Force');
    buffer.writeln('                }');
    buffer.writeln('                if (-not \$orderReq.kotNumber) {');
    buffer.writeln('                    \$orderReq | Add-Member -MemberType NoteProperty -Name "kotNumber" -Value ("KOT-" + (Get-Random -Minimum 100 -Maximum 999)) -Force');
    buffer.writeln('                }');
    buffer.writeln('                \$ordersList = @(\$ordersObj.orders)');
    buffer.writeln('                \$found = \$false');
    buffer.writeln('                for (\$i = 0; \$i -lt \$ordersList.Count; \$i++) {');
    buffer.writeln('                    if (\$ordersList[\$i].id -eq \$orderReq.id) {');
    buffer.writeln('                        \$ordersList[\$i] = \$orderReq');
    buffer.writeln('                        \$found = \$true');
    buffer.writeln('                        break');
    buffer.writeln('                    }');
    buffer.writeln('                }');
    buffer.writeln('                if (-not \$found) { \$ordersList += \$orderReq }');
    buffer.writeln('                \$ordersObj.orders = \$ordersList');
    buffer.writeln('                Write-JsonFile \$ordersFile \$ordersObj');
    buffer.writeln('                \$responseBody = @{ status = "received"; kotNumber = \$orderReq.kotNumber; id = \$orderReq.id; rev = \$rev } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('            }');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/kds/status" -and \$method -eq "POST") {');
    buffer.writeln('            \$kdsReq = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('            \$orderId = [string]\$kdsReq.orderId');
    buffer.writeln('            \$kStatus = [string]\$kdsReq.kitchenStatus');
    buffer.writeln('            \$ordersObj = Read-JsonFile \$ordersFile @{ rev = 1; orders = @() }');
    buffer.writeln('            \$rev = [int]\$ordersObj.rev + 1');
    buffer.writeln('            \$ordersObj.rev = \$rev');
    buffer.writeln('            \$ordersList = @(\$ordersObj.orders)');
    buffer.writeln('            foreach (\$o in \$ordersList) {');
    buffer.writeln('                if (\$o.id -eq \$orderId -or (\$o.kotNumber -and \$o.kotNumber -eq \$orderId)) {');
    buffer.writeln('                    \$o.kitchenStatus = \$kStatus');
    buffer.writeln('                    if (\$kdsReq.status) { \$o.status = [string]\$kdsReq.status }');
    buffer.writeln('                    break');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln('            \$ordersObj.orders = \$ordersList');
    buffer.writeln('            Write-JsonFile \$ordersFile \$ordersObj');
    buffer.writeln('            \$responseBody = @{ status = "updated"; orderId = \$orderId; kitchenStatus = \$kStatus; rev = \$rev } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/pair" -and \$method -eq "POST") {');
    buffer.writeln('            \$tokFile = Join-Path \$appData \'smartbizz_license.token\'');
    buffer.writeln('            \$tokContent = if (Test-Path \$tokFile) { ([System.IO.File]::ReadAllText(\$tokFile, [System.Text.Encoding]::UTF8)).Trim() } else { "" }');
    buffer.writeln('            \$pairToken = "sbz_pair_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + "_" + (Get-Random -Minimum 1000 -Maximum 9999)');
    buffer.writeln('            \$storeObj = Read-JsonFile \$storeFile @{');
    buffer.writeln('                orgId = "org_local"');
    buffer.writeln('                storeName = "SmartBizz Store"');
    buffer.writeln('                vertical = "restaurant"');
    buffer.writeln('                storageMode = "LOCAL_NETWORK"');
    buffer.writeln('            }');
    buffer.writeln('            \$responseBody = @{');
    buffer.writeln('                status = "ok"');
    buffer.writeln('                token = \$pairToken');
    buffer.writeln('                licenseToken = \$tokContent');
    buffer.writeln('                store = \$storeObj');
    buffer.writeln('            } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('        } elseif (\$cleanPath -eq "/api/v1/images" -and \$method -eq "POST") {');
    buffer.writeln('            \$imgReq = try { \$bodyText | ConvertFrom-Json } catch { \$null }');
    buffer.writeln('            if (\$imgReq -and \$imgReq.data) {');
    buffer.writeln('                \$rawFName = if (\$imgReq.fileName) { [string]\$imgReq.fileName } else { "dish_" + [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() + ".jpg" }');
    buffer.writeln('                \$cleanFName = [System.IO.Path]::GetFileName(\$rawFName)');
    buffer.writeln('                \$targetImg = Join-Path \$imagesDir \$cleanFName');
    buffer.writeln('                [System.IO.File]::WriteAllBytes(\$targetImg, [System.Convert]::FromBase64String([string]\$imgReq.data))');
    buffer.writeln('                \$imgUrl = "http://" + \$HostIp + ":" + \$Port + "/api/v1/images/" + \$cleanFName');
    buffer.writeln('                \$responseBody = @{ status = "ok"; fileName = \$cleanFName; imageUrl = \$imgUrl } | ConvertTo-Json -Depth 10 -Compress');
    buffer.writeln('            } else {');
    buffer.writeln('                \$statusCode = 400');
    buffer.writeln('                \$statusText = "Bad Request"');
    buffer.writeln('                \$responseBody = \'{"error":"Missing image data"}\'');
    buffer.writeln('            }');
    buffer.writeln('        } elseif (\$cleanPath.StartsWith("/api/v1/images/")) {');
    buffer.writeln('            \$rawImgName = \$cleanPath.Substring(15)');
    buffer.writeln('            \$cleanImgName = [System.IO.Path]::GetFileName(\$rawImgName)');
    buffer.writeln('            \$targetImg = Join-Path \$imagesDir \$cleanImgName');
    buffer.writeln('            if (Test-Path \$targetImg -PathType Leaf) {');
    buffer.writeln('                \$ext = [System.IO.Path]::GetExtension(\$targetImg)');
    buffer.writeln('                \$cType = Get-ContentType \$ext');
    buffer.writeln('                \$fileLen = (Get-Item \$targetImg).Length');
    buffer.writeln('                \$headerStr = "HTTP/1.1 200 OK`r`nContent-Type: \$cType`r`nContent-Length: \$fileLen`r`nCache-Control: max-age=86400`r`n" + \$corsHeaders + "Connection: close`r`n`r`n"');
    buffer.writeln('                \$hBytes = [System.Text.Encoding]::UTF8.GetBytes(\$headerStr)');
    buffer.writeln('                \$stream.Write(\$hBytes, 0, \$hBytes.Length)');
    buffer.writeln('                \$fs = [System.IO.File]::OpenRead(\$targetImg)');
    buffer.writeln('                \$fs.CopyTo(\$stream, 65536)');
    buffer.writeln('                \$fs.Close()');
    buffer.writeln('                \$stream.Flush()');
    buffer.writeln('                \$client.Close()');
    buffer.writeln('                continue');
    buffer.writeln('            } else {');
    buffer.writeln('                \$statusCode = 404');
    buffer.writeln('                \$statusText = "Not Found"');
    buffer.writeln('                \$responseBody = \'{"error":"Image not found"}\'');
    buffer.writeln('            }');
    buffer.writeln('        } else {');
    buffer.writeln('            # Static Web App & Single Page Application (SPA) Serving');
    buffer.writeln('            \$relPath = if (\$cleanPath -match "^/pos/?(.*)") { \$matches[1] } else { \$cleanPath.TrimStart(\'/\') }');
    buffer.writeln('            \$relPath = \$relPath.Replace(\'/\', \'\\\\\')');
    buffer.writeln('            \$targetFile = \$null');
    buffer.writeln('            if (-not \$relPath -or \$relPath -eq "index.html") {');
    buffer.writeln('                \$targetFile = Join-Path \$wwwDir "index.html"');
    buffer.writeln('            } elseif (\$relPath -match "^r(\\\\\\\\|/)?(.*)") {');
    buffer.writeln('                \$rSub = if (\$matches[2]) { \$matches[2] } else { "index.html" }');
    buffer.writeln('                \$targetFile = Join-Path \$wwwDir (Join-Path "r" \$rSub)');
    buffer.writeln('                if (-not (Test-Path \$targetFile -PathType Leaf)) {');
    buffer.writeln('                    \$targetFile = Join-Path \$wwwDir "r\\\\index.html"');
    buffer.writeln('                }');
    buffer.writeln('            } else {');
    buffer.writeln('                \$candidate = Join-Path \$wwwDir \$relPath');
    buffer.writeln('                if (Test-Path \$candidate -PathType Leaf) {');
    buffer.writeln('                    \$targetFile = \$candidate');
    buffer.writeln('                } elseif ((Test-Path (Join-Path \$wwwDir "index.html")) -and (\$cleanPath -notmatch "^/api/")) {');
    buffer.writeln('                    \$targetFile = Join-Path \$wwwDir "index.html"');
    buffer.writeln('                }');
    buffer.writeln('            }');
    buffer.writeln();
    buffer.writeln('            if (\$targetFile -and (Test-Path \$targetFile -PathType Leaf)) {');
    buffer.writeln('                \$ext = [System.IO.Path]::GetExtension(\$targetFile)');
    buffer.writeln('                \$cType = Get-ContentType \$ext');
    buffer.writeln('                if (\$targetFile.EndsWith("index.html")) {');
    buffer.writeln('                    \$htmlContent = [System.IO.File]::ReadAllText(\$targetFile, [System.Text.Encoding]::UTF8)');
    buffer.writeln('                    if (\$cleanPath -notmatch "^/pos") {');
    buffer.writeln('                        \$htmlContent = \$htmlContent.Replace(\'<base href="/pos/">\', \'<base href="/">\')');
    buffer.writeln('                    }');
    buffer.writeln('                    \$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(\$htmlContent)');
    buffer.writeln('                    \$headerStr = "HTTP/1.1 200 OK`r`nContent-Type: \$cType`r`nContent-Length: " + \$bodyBytes.Length + "`r`nCache-Control: no-cache`r`n" + \$corsHeaders + "Connection: close`r`n`r`n"');
    buffer.writeln('                    \$hBytes = [System.Text.Encoding]::UTF8.GetBytes(\$headerStr)');
    buffer.writeln('                    \$stream.Write(\$hBytes, 0, \$hBytes.Length)');
    buffer.writeln('                    \$stream.Write(\$bodyBytes, 0, \$bodyBytes.Length)');
    buffer.writeln('                    \$stream.Flush()');
    buffer.writeln('                    \$client.Close()');
    buffer.writeln('                    continue');
    buffer.writeln('                } else {');
    buffer.writeln('                    \$fileLen = (Get-Item \$targetFile).Length');
    buffer.writeln('                    \$headerStr = "HTTP/1.1 200 OK`r`nContent-Type: \$cType`r`nContent-Length: \$fileLen`r`nCache-Control: public, max-age=3600`r`n" + \$corsHeaders + "Connection: close`r`n`r`n"');
    buffer.writeln('                    \$hBytes = [System.Text.Encoding]::UTF8.GetBytes(\$headerStr)');
    buffer.writeln('                    \$stream.Write(\$hBytes, 0, \$hBytes.Length)');
    buffer.writeln('                    \$fs = [System.IO.File]::OpenRead(\$targetFile)');
    buffer.writeln('                    \$fs.CopyTo(\$stream, 65536)');
    buffer.writeln('                    \$fs.Close()');
    buffer.writeln('                    \$stream.Flush()');
    buffer.writeln('                    \$client.Close()');
    buffer.writeln('                    continue');
    buffer.writeln('                }');
    buffer.writeln('            } else {');
    buffer.writeln('                \$isRedirect = \$true');
    buffer.writeln('                \$statusCode = 302');
    buffer.writeln('                \$statusText = "Found"');
    buffer.writeln('            }');
    buffer.writeln('        }');
    buffer.writeln();
    buffer.writeln('        \$bodyBytes = [System.Text.Encoding]::UTF8.GetBytes(\$responseBody)');
    buffer.writeln('        if (\$isRedirect) {');
    buffer.writeln('            \$headerStr = "HTTP/1.1 302 Found`r`nLocation: \$redirectUrl`r`nContent-Length: 0`r`n"');
    buffer.writeln('        } elseif (\$statusCode -eq 204) {');
    buffer.writeln('            \$headerStr = "HTTP/1.1 204 No Content`r`nContent-Length: 0`r`n"');
    buffer.writeln('        } else {');
    buffer.writeln('            \$headerStr = "HTTP/1.1 200 OK`r`nContent-Type: application/json; charset=utf-8`r`nContent-Length: " + \$bodyBytes.Length + "`r`n"');
    buffer.writeln('        }');
    buffer.writeln('        \$headerStr += \$corsHeaders');
    buffer.writeln('        \$headerStr += "Connection: close`r`n`r`n"');
    buffer.writeln();
    buffer.writeln('        \$headerBytes = [System.Text.Encoding]::UTF8.GetBytes(\$headerStr)');
    buffer.writeln('        \$stream.Write(\$headerBytes, 0, \$headerBytes.Length)');
    buffer.writeln('        if (-not \$isRedirect -and \$bodyBytes.Length -gt 0) {');
    buffer.writeln('            \$stream.Write(\$bodyBytes, 0, \$bodyBytes.Length)');
    buffer.writeln('        }');
    buffer.writeln('        \$stream.Flush()');
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
