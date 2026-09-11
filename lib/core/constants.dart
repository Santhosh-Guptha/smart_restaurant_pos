import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

// --- CONFIGURATION CONSTANTS ---
// Central location for all app-wide configuration values.

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

const String kDefaultMerchantVpa = ""; // Configured per-outlet by merchant in Store Settings

const String kRestaurantWebOrderingBaseUrl =
    'https://smartbizz.devmonks.space/r/'; // Production ordering URL (fallback to smartdine-pos.web.app)

const String kGoogleClientId =
    '486476143616-1e1pmj004p87b0h2pk09b00ejeepsfi8.apps.googleusercontent.com';

const String kAdminSpreadsheetId =
    '1RJ6FOdH9fmX3DIkygAfbb0ixaCKOKcBn1FZm5XGKjlM'; // Central registry managed by Santhosh

const String kAdminEmail = 'smartdine.platform@gmail.com'; // Primary production Master Admin email

const List<String> kAdminEmails = [
  'smartdine.platform@gmail.com',
  'santhoshbukka5@gmail.com',
];

bool isMasterAdminEmail(String? email) {
  if (email == null) return false;
  final clean = email.toLowerCase().trim();
  return kAdminEmails.any((e) => e.toLowerCase().trim() == clean);
}

const String kOutboxBoxName = 'outbox_queue';
const String kInventoryBoxName = 'inventory';
const String kCustomersBoxName = 'customers';
const String kLedgerBoxName = 'ledger';
const String kBillsBoxName = 'bills';
const String kSuppliersBoxName = 'suppliers';
const String kPurchaseOrdersBoxName = 'purchase_orders';
const String kStockMovementsBoxName = 'stock_movements';
const String kReturnsBoxName = 'returns';
const String kShopUsersBoxName = 'shop_users';
const String kSelfPickupNotesBoxName = 'self_pickup_notes';
const String kFranchisesBoxName = 'franchises';

// --- SILKY SMOOTH NAVIGATION TRANSITIONS ---

Route smoothRoute(Widget screen) {
  return CupertinoPageRoute(
    builder: (context) => screen,
  );
}

void smoothNavigateTo(BuildContext context, Widget screen) {
  Navigator.push(context, smoothRoute(screen));
}

// --- QUANTITY FORMATTING HELPER ---

String formatQty(dynamic qty) {
  if (qty == null) return '0';
  final num val = qty as num;
  if (val == -1) return '∞';
  if (val == val.toInt()) {
    return val.toInt().toString();
  }
  // Up to 3 decimal places, remove trailing zeros
  return val.toStringAsFixed(3).replaceAll(RegExp(r'\.?0+$'), '');
}

/// Resolves current effective outlet/org ID safely without guessing or hardcoding foreign tenants.
String resolveOutletId({String? userOrgId, String? sessionOrgId, dynamic hiveBox}) {
  if (userOrgId != null && userOrgId.isNotEmpty && userOrgId != 'ORG_DEFAULT' && userOrgId != 'default' && userOrgId != 'ORG264646') {
    return userOrgId;
  }
  if (sessionOrgId != null && sessionOrgId.isNotEmpty && sessionOrgId != 'ORG_DEFAULT' && sessionOrgId != 'default' && sessionOrgId != 'ORG264646') {
    return sessionOrgId;
  }
  if (hiveBox != null) {
    try {
      final saved = hiveBox.get('current_org_id') ?? hiveBox.get('default_org_id');
      if (saved != null && saved.toString().isNotEmpty && saved.toString() != 'ORG_DEFAULT' && saved.toString() != 'ORG264646') {
        return saved.toString();
      }
    } catch (_) {}
  }
  return '';
}

