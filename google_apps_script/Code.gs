/**
 * =========================================================================
 * SMARTDINE RESTAURANT POS CLOUD BACKEND (Google Apps Script)
 * Automatically creates & manages Google Spreadsheets in your Google Drive.
 * 100% Zero-Server & Zero-Firebase Architecture.
 * =========================================================================
 */

const SECRET_TOKEN = "SMART_POS_SECURE_TOKEN_2026";

// ─────────────────────────────────────────────────────────────────────────────
// Multi-Tenant Script Properties Registry Helper
// Maps org_id -> { spreadsheet_id, org_name, upi_id, updated_at }
// ─────────────────────────────────────────────────────────────────────────────
function getTenantInfo(orgId) {
  if (!orgId) return null;
  try {
    var raw = PropertiesService.getScriptProperties().getProperty("org_" + orgId.trim());
    if (raw) {
      return JSON.parse(raw);
    }
  } catch (e) {}
  return null;
}

function getSheetIdForOrg(orgId) {
  if (!orgId) return null;
  var info = getTenantInfo(orgId);
  return info ? info.spreadsheet_id : null;
}

function handleRegisterTenant(data) {
  var orgId = data.org_id || data.org;
  var sheetId = data.spreadsheet_id || data.sheet;
  if (!orgId || !sheetId) {
    return responseJson({ success: false, error: "org_id and spreadsheet_id are required." });
  }
  var info = {
    org_id: orgId.trim(),
    spreadsheet_id: sheetId.trim(),
    org_name: data.org_name || data.name || "",
    upi_id: data.upi_id || data.upi || "",
    updated_at: new Date().toISOString()
  };
  PropertiesService.getScriptProperties().setProperty("org_" + orgId.trim(), JSON.stringify(info));
  return responseJson({ success: true, message: "Tenant registered successfully.", tenant: info });
}

function doPost(e) {
  try {
    const json = JSON.parse(e.postData.contents);
    
    // Security verification: allow customer non-settled SAVE_BILL, SERVICE_REQUEST, CALL_WAITER without exposing master secret
    var b = json.data || json.bill || {};
    var isPublicAction = (
      (json.action === "SAVE_BILL" && !isStatusSettled(b.payment_status || b.status)) || 
      json.action === "SERVICE_REQUEST" || 
      json.action === "CALL_WAITER" || 
      json.action === "DISMISS_SERVICE_REQUEST" || 
      json.action === "RESOLVE_WAITER_CALL"
    );
    if (!isPublicAction && json.secret !== SECRET_TOKEN) {
      return responseJson({ success: false, error: "Unauthorized access: Invalid secret token." });
    }


    const action = json.action;

    switch (action) {
      case "ONBOARD_ORGANIZATION":
        return handleOnboardOrganization(json);

      case "CREATE_OUTLET":
        return handleCreateOutlet(json);

      case "REGISTER_TENANT":
        return handleRegisterTenant(json);

      case "SAVE_BILL":
      case "UPDATE_ORDER_STATUS":
      case "UPDATE_STATUS":
        return handleSaveBill(json);

      case "CLEAR_TABLE":
      case "RESET_TABLE":
        return handleClearTable(json);

      case "PURGE_TEST_ORDERS":
        return handlePurgeTestOrders(json);

      case "SERVICE_REQUEST":
      case "CALL_WAITER":
        return handleServiceRequest(json);

      case "DISMISS_SERVICE_REQUEST":
      case "RESOLVE_WAITER_CALL":
        return handleDismissServiceRequest(json);

      case "SYNC_INVENTORY":
        return handleSyncInventory(json);

      case "FETCH_MASTER_ANALYTICS":
        return handleFetchAnalytics(json);

      case "SEND_OTP_EMAIL":
        return handleSendOtpEmail(json);

      case "MIGRATE_V2_DATA":
        var ssMig = null;
        var sId = json.spreadsheet_id || json.spreadsheetId;
        if (!sId && json.org_id) sId = getSheetIdForOrg(json.org_id);
        if (sId) {
          try { ssMig = SpreadsheetApp.openById(sId); } catch(eMig) {}
        }
        return responseJson(migrateDiningBillsToV2(ssMig, json.dry_run !== false));

      case "GET_DELTA":
      case "FETCH_DELTA":
        return handleGetDelta(json);

      case "RECORD_PAYMENT":
        return handleRecordPayment(json);

      case "REFUND_PAYMENT":
        return handleRefundPayment(json);

      case "CLOSE_DAY":
        return handleCloseDay(json);

      case "SET_TABLE_STATUS":
        return handleSetTableStatus(json);

      case "RESERVE_TABLE":
        return handleReserveTable(json);

      case "CANCEL_RESERVATION":
        return handleCancelReservation(json);

      case "SEAT_RESERVATION":
        return handleSeatReservation(json);

      case "MOVE_TABLE":
        return handleMoveTable(json);

      case "MERGE_TABLES":
        return handleMergeTables(json);

      case "TOGGLE_ITEM_AVAILABILITY":
      case "SET_ITEM_AVAILABILITY":
        return handleToggleItemAvailability(json);

      case "DECREMENT_INVENTORY":
        return handleDecrementInventory(json);

      case "LOG_AUDIT":
        return handleLogAudit(json);

      case "VOID_ORDER":
      case "CANCEL_ORDER":
        return handleVoidOrder(json);

      case "VOID_LINE":
      case "CANCEL_LINE":
        return handleVoidLine(json);

      default:
        return responseJson({ success: false, error: "Unknown action: " + action });
    }
  } catch (err) {
    return responseJson({ success: false, error: err.toString() });
  }
}

function getInventorySheet(ss) {
  return ss.getSheetByName("Products & Stock") ||
         ss.getSheetByName("Inventory") ||
         ss.getSheetByName("Menu") ||
         ss.getSheetByName("Dishes") ||
         ss.getSheetByName("Catalog");
}

function getOrCreateInventorySheet(ss) {
  var sheet = getInventorySheet(ss);
  if (!sheet) {
    sheet = ss.insertSheet("Products & Stock");
    sheet.appendRow([
      "Product ID", "Product Name", "Category", "Cost Price (₹)", "Selling Price (₹)", "Stock Quantity", "Unit"
    ]);
    sheet.getRange("A1:G1").setFontWeight("bold").setBackground("#FEF3C7");
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function getStatusRank(status) {
  var s = String(status || "").toUpperCase().trim();
  if (s === "PAID" || s === "SUCCESS" || s === "COMPLETED" || s === "SETTLED") return 6;
  if (s === "PAYMENT_PENDING" || s === "BILLED" || s === "BILL_READY") return 5;
  if (s === "SERVED" || s === "PLACED_ON_TABLE" || s === "PLACED" || s === "ON_TABLE") return 4;
  if (s === "READY" || s === "DONE" || s === "FOOD_READY" || s === "KITCHEN_DONE") return 3;
  if (s === "PREPARING" || s === "ACCEPTED" || s === "COOKING" || s === "IN_PROGRESS") return 2;
  if (s === "ORDER_RECEIVED" || s === "PENDING" || s === "RECEIVED" || s === "TAKEN" || s === "NEW") return 1;
  return 1;
}

function cleanOrderId(id) {
  if (!id) return "";
  return String(id).toUpperCase().trim().replace(/^BILL_/, "").replace(/^KOT-?/, "").trim();
}

function cleanTableId(t) {
  if (!t) return "";
  var s = String(t).toLowerCase().trim();
  s = s.replace(/^table[\s_-]*/, "").replace(/[^a-z0-9]/g, "");
  return s;
}


function isStatusSettled(status) {
  var s = String(status || "").toUpperCase().trim();
  return s === "PAID" || s === "SUCCESS" || s === "COMPLETED" || s === "SETTLED";
}

function getOrCreateBillsSheet(ss) {
  var sheet = ss.getSheetByName("Dining Bills") || ss.getSheetByName("Bills") || ss.getSheetByName("Orders") || ss.getSheetByName("Table_Orders") || ss.getSheetByName("Sheet1");
  if (!sheet) {
    sheet = ss.insertSheet("Bills");
    sheet.appendRow([
      "Bill ID", "Date & Time", "Customer Name", "Customer Phone", 
      "Payment Mode", "Subtotal", "Discount", "Total Amount", "Items Summary", "Status", "Table", "Transaction ID"
    ]);
    sheet.getRange("A1:L1").setFontWeight("bold").setBackground("#E0F2FE");
    sheet.setFrozenRows(1);
    return sheet;
  }
  
  // Verify & fix header row if it has old format, fewer columns, or mismatched columns
  try {
    var headerRange = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), 12));
    var headers = headerRange.getValues()[0].map(function(h) { return String(h || "").trim(); });
    if (headers.length < 12 || headers[7] !== "Total Amount" || headers[8] !== "Items Summary" || headers[10] !== "Table") {
      sheet.getRange(1, 1, 1, 12).setValues([[
        "Bill ID", "Date & Time", "Customer Name", "Customer Phone", 
        "Payment Mode", "Subtotal", "Discount", "Total Amount", "Items Summary", "Status", "Table", "Transaction ID"
      ]]);
      sheet.getRange("A1:L1").setFontWeight("bold").setBackground("#E0F2FE");
      sheet.setFrozenRows(1);
    }
  } catch (e) {}
  return sheet;
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1: Server-Issued Counter Allocation (TOKEN, ORDER, INVOICE, SESSION)
// ─────────────────────────────────────────────────────────────────────────────
function allocateCounter(ss, outletId, kind, businessDate) {
  if (!outletId) outletId = "DEFAULT";
  if (!businessDate) {
    var now = new Date();
    businessDate = Utilities.formatDate(now, Session.getScriptTimeZone() || "GMT+05:30", "yyyy-MM-dd");
  }
  var sheet = ss.getSheetByName("Counters");
  if (!sheet) {
    sheet = ss.insertSheet("Counters");
    sheet.appendRow(["outletId", "kind", "businessDate", "lastValue", "updatedAt"]);
    sheet.setFrozenRows(1);
  }
  
  var data = sheet.getDataRange().getValues();
  var rowIndex = -1;
  var lastVal = 0;
  
  for (var i = 1; i < data.length; i++) {
    var rowOutlet = String(data[i][0] || "").trim();
    var rowKind = String(data[i][1] || "").trim().toUpperCase();
    var rowDate = String(data[i][2] || "").trim();
    
    if (rowOutlet === outletId && rowKind === kind.toUpperCase()) {
      if (kind.toUpperCase() === "TOKEN") {
        if (rowDate === businessDate) {
          rowIndex = i + 1;
          lastVal = parseInt(data[i][3], 10) || 0;
          break;
        }
      } else {
        rowIndex = i + 1;
        lastVal = parseInt(data[i][3], 10) || 0;
        break;
      }
    }
  }
  
  var nextVal = lastVal + 1;
  var nowIso = new Date().toISOString();
  
  if (rowIndex > 0) {
    sheet.getRange(rowIndex, 4, 1, 2).setValues([[nextVal, nowIso]]);
  } else {
    sheet.appendRow([outletId, kind.toUpperCase(), businessDate, nextVal, nowIso]);
  }
  
  return nextVal;
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared Bill Columns Resolver (Exact match with canonical fallbacks)
// ─────────────────────────────────────────────────────────────────────────────
function resolveBillColumns(headers) {
  var idIdx = -1, dateIdx = -1, nameIdx = -1, phoneIdx = -1, modeIdx = -1, subtotalIdx = -1, totalIdx = -1, itemsIdx = -1, statusIdx = -1, tableIdx = -1, txnIdx = -1, orderSourceIdx = -1, orderTypeIdx = -1;
  headers.forEach(function(rawH, idx) {
    var cleanH = String(rawH || "").toLowerCase().replace(/[^a-z0-9]/g, "");
    if (cleanH === "billid" || cleanH === "id" || cleanH === "kotid") idIdx = idx;
    else if (cleanH === "datetime" || cleanH === "date" || cleanH === "time" || cleanH === "timestamp") dateIdx = idx;
    else if (cleanH === "customername" || cleanH === "guestname" || (cleanH === "name" && cleanH.indexOf("dish") === -1 && cleanH.indexOf("item") === -1)) nameIdx = idx;
    else if (cleanH === "customerphone" || cleanH === "phone" || cleanH === "mobile") phoneIdx = idx;
    else if (cleanH === "paymentmode" || cleanH === "mode" || cleanH === "payment") modeIdx = idx;
    else if (cleanH === "subtotal" || cleanH === "subtotalamount") subtotalIdx = idx;
    else if (cleanH === "totalamount" || cleanH === "nettotal" || cleanH === "grandtotal" || cleanH === "total" || cleanH === "amount") totalIdx = idx;
    else if (cleanH === "itemssummary" || cleanH === "itemsjson" || cleanH === "items" || cleanH === "dishes") itemsIdx = idx;
    else if (cleanH === "status" || cleanH === "orderstatus" || cleanH === "billstatus") statusIdx = idx;
    else if (cleanH === "table" || cleanH === "tablename" || cleanH === "tablelocation" || cleanH === "tabletakeaway") tableIdx = idx;
    else if (cleanH === "transactionid" || cleanH === "txnid" || cleanH === "utr" || cleanH === "ref") txnIdx = idx;
    else if (cleanH === "ordersource" || cleanH === "source" || cleanH === "channel") orderSourceIdx = idx;
    else if (cleanH === "ordertype" || cleanH === "type") orderTypeIdx = idx;
  });

  // Canonical fallback indexes if headers could not be matched
  if (idIdx === -1) idIdx = 0;
  if (dateIdx === -1) dateIdx = 1;
  if (nameIdx === -1) nameIdx = 2;
  if (phoneIdx === -1) phoneIdx = 3;
  if (modeIdx === -1) modeIdx = 4;
  if (subtotalIdx === -1) subtotalIdx = 5;
  if (totalIdx === -1) totalIdx = 7;
  if (itemsIdx === -1) itemsIdx = 8;
  if (statusIdx === -1) statusIdx = 9;
  if (tableIdx === -1) tableIdx = 10;
  if (txnIdx === -1) txnIdx = 11;

  return {
    idIdx: idIdx,
    dateIdx: dateIdx,
    nameIdx: nameIdx,
    phoneIdx: phoneIdx,
    modeIdx: modeIdx,
    subtotalIdx: subtotalIdx,
    totalIdx: totalIdx,
    itemsIdx: itemsIdx,
    statusIdx: statusIdx,
    tableIdx: tableIdx,
    txnIdx: txnIdx,
    orderSourceIdx: orderSourceIdx,
    orderTypeIdx: orderTypeIdx
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 1: 48-Hour Idempotency Cache & Sheet Ledger
// ─────────────────────────────────────────────────────────────────────────────
function checkIdempotency(ss, clientRequestId) {
  if (!clientRequestId) return null;
  var key = "idemp_" + clientRequestId.trim();
  // 1. Fast path: CacheService
  try {
    var cached = CacheService.getScriptCache().get(key);
    if (cached) {
      return JSON.parse(cached);
    }
  } catch (e) {}
  
  // 2. Sheet ledger path: Idempotency tab (48 hours)
  try {
    var sheet = ss ? ss.getSheetByName("Idempotency") : null;
    if (sheet) {
      var data = sheet.getDataRange().getValues();
      var cutoff = Date.now() - (48 * 60 * 60 * 1000);
      for (var i = data.length - 1; i >= 1; i--) {
        if (String(data[i][0] || "").trim() === clientRequestId.trim()) {
          var timeStr = data[i][3];
          var t = timeStr ? new Date(timeStr).getTime() : 0;
          if (t > cutoff) {
            return JSON.parse(data[i][2]);
          }
        }
      }
    }
  } catch (e) {}
  return null;
}

function recordIdempotency(ss, clientRequestId, action, resultObj) {
  if (!clientRequestId || !resultObj) return;
  var key = "idemp_" + clientRequestId.trim();
  var resJson = JSON.stringify(resultObj);
  try {
    CacheService.getScriptCache().put(key, resJson, 21600); // 6 hours
  } catch (e) {}
  
  try {
    if (ss) {
      var sheet = ss.getSheetByName("Idempotency");
      if (!sheet) {
        sheet = ss.insertSheet("Idempotency");
        sheet.appendRow(["clientRequestId", "action", "resultJson", "createdAt"]);
        sheet.setFrozenRows(1);
      }
      sheet.appendRow([clientRequestId.trim(), action || "", resJson, new Date().toISOString()]);
      if (sheet.getLastRow() > 1000) {
        var rowsToDelete = sheet.getLastRow() - 800;
        if (rowsToDelete > 0) sheet.deleteRows(2, rowsToDelete);
      }
    }
  } catch (e) {}
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 2: Schema v2 Definitions (§6.1) & Monotonic Rev
// ─────────────────────────────────────────────────────────────────────────────
var V2_SCHEMAS = {
  "Sessions": [
    "sessionId", "outletId", "tableIds", "sessionStatus", "covers", "source", 
    "guestName", "guestPhone", "reservationId", "openedBy", "openedAt", "closedAt", 
    "invoiceNos", "rev"
  ],
  "Orders": [
    "orderId", "sessionId", "outletId", "tableId", "tokenNo", "courseNo", 
    "orderSource", "orderType", "station", "kitchenStatus", "firedAt", "readyAt", 
    "servedAt", "staffId", "staffName", "deviceId", "clientRequestId", "generalNotes", 
    "subtotalP", "discountP", "serviceChargeP", "taxableP", "cgstP", "sgstP", 
    "roundOffP", "grandTotalP", "rev"
  ],
  "OrderItems": [
    "lineId", "orderId", "sessionId", "productId", "name", "qty", "unitPriceP", 
    "lineTotalP", "taxRateBps", "station", "notes", "kitchenStatus", "voidedQty", 
    "voidReason", "voidedBy", "rev"
  ],
  "Payments": [
    "paymentId", "sessionId", "invoiceNo", "mode", "amountP", "tipP", "ref_UTR", 
    "gatewayId", "verified", "byStaffId", "at", "voidedBy", "voidReason", "rev"
  ],
  "Invoices": [
    "invoiceNo", "sessionId", "outletId", "fy", "issuedAt", "subtotalP", "discountP", 
    "serviceChargeP", "taxableP", "cgstP", "sgstP", "roundOffP", "grandTotalP", 
    "gstin", "printCount", "lastPrintedAt", "status", "voidReason", "rev"
  ],
  "Tables": [
    "tableId", "outletId", "displayName", "section", "capacity", "tableStatus", 
    "activeSessionId", "occupiedAt", "cleaningUntil", "qrToken", "rev"
  ],
  "Reservations": [
    "reservationId", "outletId", "tableIds", "guestName", "guestPhone", "partySize", 
    "startAt", "durationMin", "status", "notes", "createdBy", "createdAt", 
    "seatedSessionId", "rev"
  ],
  "Alerts": [
    "alertId", "outletId", "tableId", "sessionId", "type", "guestName", 
    "status", "raisedAt", "ackBy", "resolvedAt", "rev"
  ],
  "Counters": [
    "outletId", "kind", "businessDate", "lastValue", "updatedAt"
  ],
  "Idempotency": [
    "clientRequestId", "action", "resultJson", "createdAt"
  ],
  "Audit": [
    "at", "outletId", "staffId", "action", "entity", "entityId", 
    "before", "after", "reason"
  ],
  "Day End Reports": [
    "businessDate", "outletId", "grossP", "discountP", "taxP", "serviceChargeP", 
    "netP", "byMode", "covers", "orders", "voids", "refunds", "cashDeclaredP", 
    "varianceP", "closedBy", "closedAt"
  ]
};

function ensureV2Sheets(ss) {
  if (!ss) return;
  for (var tabName in V2_SCHEMAS) {
    var sheet = ss.getSheetByName(tabName);
    if (!sheet) {
      sheet = ss.insertSheet(tabName);
      sheet.appendRow(V2_SCHEMAS[tabName]);
      sheet.getRange(1, 1, 1, V2_SCHEMAS[tabName].length).setFontWeight("bold");
      sheet.setFrozenRows(1);
    }
  }
}

function getAndBumpRev(outletId) {
  if (!outletId) return 1;
  var props = PropertiesService.getScriptProperties();
  var revKey = "rev_" + outletId.trim();
  var currentRev = parseInt(props.getProperty(revKey), 10) || 0;
  var nextRev = currentRev + 1;
  props.setProperty(revKey, String(nextRev));
  return nextRev;
}

function findOrCreateActiveSession(ss, outletId, tableId, openedBy, guestName, guestPhone, rev) {
  if (!ss) return "";
  var sessionSheet = ss.getSheetByName("Sessions");
  if (!sessionSheet) return "";
  var cTable = cleanTableId(tableId);
  var data = sessionSheet.getDataRange().getValues();
  for (var i = data.length - 1; i >= 1; i--) {
    var rowOut = String(data[i][1] || "").trim();
    var rowTables = String(data[i][2] || "").trim().split(",").map(function(t) { return cleanTableId(t); });
    var rowStatus = String(data[i][3] || "").trim().toUpperCase();
    if (rowOut === outletId && rowStatus === "OPEN" && rowTables.indexOf(cTable) !== -1) {
      return String(data[i][0] || "").trim();
    }
  }
  
  var now = new Date();
  var ymd = Utilities.formatDate(now, Session.getScriptTimeZone() || "GMT+05:30", "yyyyMMdd");
  var seq = allocateCounter(ss, outletId, "SESSION");
  var sessionId = "SES-" + ymd + "-" + ("0000" + seq).slice(-4);
  sessionSheet.appendRow([
    sessionId,
    outletId,
    cTable,
    "OPEN",
    1,
    "POS",
    guestName || "",
    guestPhone || "",
    "",
    openedBy || "Staff",
    now.toISOString(),
    "",
    "",
    rev
  ]);
  return sessionId;
}

function persistV2Order(ss, orgId, billId, cleanId, tokenNo, tableName, cTable, status, isSettled, totalAmount, subtotal, timeStr, rawItems, paymentMode, customerName, customerPhone, specialInstructions, txnId, clientRequestId, b, rev) {
  if (!ss) return;
  try {
    ensureV2Sheets(ss);
    var staffName = String(b.waiter_name || b.waiterName || b.cashier_name || b.cashierName || b.staff_name || b.staffName || "Staff").trim();
    var staffId = String(b.staff_id || b.staffId || "").trim();
    var sessionId = String(b.session_id || b.sessionId || "").trim();
    if (!sessionId) {
      sessionId = findOrCreateActiveSession(ss, orgId, tableName, staffName, customerName, customerPhone, rev);
    }
    
    var grandTotalP = Math.round((totalAmount || 0) * 100);
    var subtotalP = b.subtotalP !== undefined ? parseInt(b.subtotalP, 10) : Math.round((subtotal || 0) * 100);
    var discountP = b.discountP !== undefined ? parseInt(b.discountP, 10) : Math.round((parseFloat(b.discount || b.discount_amount || b.discountP) || 0) * 100);
    var serviceChargeP = b.serviceChargeP !== undefined ? parseInt(b.serviceChargeP, 10) : Math.round((parseFloat(b.service_charge || b.service_charge_amount || b.serviceChargeP) || 0) * 100);

    var hasClientComponents = (b.cgstP !== undefined && b.sgstP !== undefined) || (b.cgst !== undefined && b.sgst !== undefined);
    var taxableP, cgstP, sgstP, roundOffP;

    if (hasClientComponents) {
      taxableP = b.taxableP !== undefined ? parseInt(b.taxableP, 10) : (b.taxable !== undefined ? Math.round(parseFloat(b.taxable) * 100) : Math.max(0, subtotalP - discountP + serviceChargeP));
      cgstP = b.cgstP !== undefined ? parseInt(b.cgstP, 10) : Math.round(parseFloat(b.cgst) * 100);
      sgstP = b.sgstP !== undefined ? parseInt(b.sgstP, 10) : Math.round(parseFloat(b.sgst) * 100);
      roundOffP = b.roundOffP !== undefined ? parseInt(b.roundOffP, 10) : (b.round_off !== undefined ? Math.round(parseFloat(b.round_off) * 100) : (grandTotalP - (taxableP + cgstP + sgstP)));

      if (taxableP + cgstP + sgstP + roundOffP !== grandTotalP) {
        if (Math.abs((taxableP + cgstP + sgstP + roundOffP) - grandTotalP) <= 1) {
          roundOffP = grandTotalP - (taxableP + cgstP + sgstP);
        } else {
          Logger.log("TOTALS_MISMATCH in persistV2Order: " + billId + " sum=" + (taxableP + cgstP + sgstP + roundOffP) + " vs grand=" + grandTotalP);
          var gstRateFb = parseFloat(b.gst_rate || b.gstRate) || 5;
          var gstPFb = Math.round(taxableP * (gstRateFb / 100));
          cgstP = Math.round(gstPFb / 2);
          sgstP = gstPFb - cgstP;
          roundOffP = grandTotalP - (taxableP + cgstP + sgstP);
        }
      }
    } else {
      var gstRate = parseFloat(b.gst_rate || b.gstRate) || 5;
      taxableP = Math.max(0, subtotalP - discountP + serviceChargeP);
      var gstP = Math.round(taxableP * (gstRate / 100));
      cgstP = Math.round(gstP / 2);
      sgstP = gstP - cgstP;
      roundOffP = grandTotalP - (taxableP + gstP);
    }
    
    // 1. Orders tab
    var ordersSheet = ss.getSheetByName("Orders");
    if (ordersSheet) {
      var oData = ordersSheet.getDataRange().getValues();
      var existingOrderRow = -1;
      for (var oi = oData.length - 1; oi >= 1; oi--) {
        if (cleanOrderId(oData[oi][0]) === cleanId) {
          existingOrderRow = oi + 1;
          break;
        }
      }
      
      var orderRow = [
        billId,
        sessionId,
        orgId,
        cTable,
        tokenNo || "",
        parseInt(b.course_no || b.courseNo || 1, 10) || 1,
        String(b.order_source || b.orderSource || "POS_COUNTER").trim(),
        String(b.order_type || b.orderType || "Dine-In").trim(),
        String(b.station || "Main Kitchen").trim(),
        isSettled ? "SERVED" : String(b.kitchenStatus || b.kitchen_status || "PENDING").toUpperCase(),
        timeStr,
        "",
        isSettled ? timeStr : "",
        staffId,
        staffName,
        String(b.device_id || b.deviceId || "").trim(),
        clientRequestId,
        specialInstructions,
        subtotalP,
        discountP,
        serviceChargeP,
        taxableP,
        cgstP,
        sgstP,
        roundOffP,
        grandTotalP,
        rev
      ];
      
      if (existingOrderRow > 0) {
        ordersSheet.getRange(existingOrderRow, 1, 1, orderRow.length).setValues([orderRow]);
      } else {
        ordersSheet.appendRow(orderRow);
      }
    }
    
    // 2. OrderItems tab
    var itemsSheet = ss.getSheetByName("OrderItems");
    if (itemsSheet && Array.isArray(rawItems) && rawItems.length > 0) {
      for (var idx = 0; idx < rawItems.length; idx++) {
        var it = rawItems[idx];
        if (!it) continue;
        var lineId = billId + "_L" + (idx + 1);
        var itemQty = parseFloat(it.qty || it.quantity) || 1;
        var itemPriceP = Math.round((parseFloat(it.price || it.unitPrice || 0) || 0) * 100);
        var lineTotalP = Math.round(itemQty * itemPriceP);
        var lineRow = [
          lineId,
          billId,
          sessionId,
          String(it.productId || it.id || "item").trim(),
          String(it.name || "Dish").trim(),
          itemQty,
          itemPriceP,
          lineTotalP,
          Math.round((parseFloat(b.gst_rate || b.gstRate) || 5) * 100),
          String(it.station || b.station || "Main Kitchen").trim(),
          String(it.notes || it.instructions || "").trim(),
          isSettled ? "SERVED" : String(it.kitchenStatus || b.kitchenStatus || "PENDING").toUpperCase(),
          0,
          "",
          "",
          rev
        ];
        itemsSheet.appendRow(lineRow);
      }
    }
    
    // Log discount authorization in Audit tab if applicable
    if (discountP > 0) {
      var discReason = String(b.discount_reason || b.discountReason || "Authorized discount").trim();
      var discAuthBy = String(b.discount_authorized_by || b.discountAuthorizedBy || staffName).trim();
      logAuditRecord(ss, orgId, discAuthBy, "DISCOUNT_APPLIED", "Order", cleanId, "0", String(discountP), discReason);
    }
    
    // 3. Payments tab
    if (isSettled) {
      var paySheet = ss.getSheetByName("Payments");
      if (paySheet) {
        var paySeq = allocateCounter(ss, orgId, "PAYMENT");
        var nowD = new Date();
        var ymdP = Utilities.formatDate(nowD, Session.getScriptTimeZone() || "GMT+05:30", "yyyyMMdd");
        var paymentId = "PAY-" + ymdP + "-" + ("0000" + paySeq).slice(-4);
        var payRow = [
          paymentId,
          sessionId,
          billId,
          paymentMode || "CASH",
          grandTotalP,
          b.tipP !== undefined ? parseInt(b.tipP, 10) : Math.round((parseFloat(b.tip_amount || b.tipAmount || b.tip || 0) || 0) * 100),
          txnId || "",
          "",
          true,
          staffId || staffName,
          timeStr,
          "",
          "",
          rev
        ];
        paySheet.appendRow(payRow);
      }
      
      var sSheet = ss.getSheetByName("Sessions");
      if (sSheet && sessionId) {
        var sData = sSheet.getDataRange().getValues();
        for (var si = sData.length - 1; si >= 1; si--) {
          if (String(sData[si][0] || "").trim() === sessionId) {
            sSheet.getRange(si + 1, 4).setValue("CLOSED");
            sSheet.getRange(si + 1, 12).setValue(timeStr);
            sSheet.getRange(si + 1, 14).setValue(rev);
            break;
          }
        }
      }
    }
  } catch (eV2) {
    console.warn("Error in persistV2Order: " + eV2);
  }
}

function migrateDiningBillsToV2(ss, isDryRun) {
  if (!ss) return { success: false, error: "No spreadsheet provided." };
  ensureV2Sheets(ss);
  
  var legacySheet = ss.getSheetByName("Dining Bills") || ss.getSheetByName("Bills");
  if (!legacySheet || legacySheet.getLastRow() < 2) {
    return { success: true, dryRun: isDryRun, message: "No legacy bills found to migrate.", totalScanned: 0, migratedOrders: 0, unmappedRows: 0 };
  }
  
  var data = legacySheet.getDataRange().getValues();
  var headers = data[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
  var colCount = data[0].length;
  
  var totalScanned = 0;
  var migratedOrders = 0;
  var unmappedRows = 0;
  var unmappedDetails = [];
  
  var orgId = "DEFAULT_ORG";
  try {
    var p = PropertiesService.getScriptProperties().getProperties();
    for (var k in p) {
      if (k.indexOf("org_") === 0) {
        orgId = k.replace("org_", "");
        break;
      }
    }
  } catch(e) {}
  
  var rev = getAndBumpRev(orgId);
  var ordersSheet = ss.getSheetByName("Orders");
  var paymentsSheet = ss.getSheetByName("Payments");
  var sessionsSheet = ss.getSheetByName("Sessions");
  
  for (var i = 1; i < data.length; i++) {
    totalScanned++;
    var row = data[i];
    if (!row || row.length === 0 || !row[0]) continue;
    
    try {
      var rawId = "", rawDate = "", rawTable = "", rawCustomer = "", rawPhone = "";
      var rawTotal = 0, rawSubtotal = 0, rawDiscount = 0, rawMode = "CASH", rawStatus = "PAID", rawItems = "";
      
      if (headers.indexOf("bill id") !== -1 || headers.indexOf("bill_id") !== -1 || headers.indexOf("order id") !== -1) {
        var idIdx = Math.max(headers.indexOf("bill id"), headers.indexOf("bill_id"), headers.indexOf("order id"), headers.indexOf("id"));
        var dateIdx = Math.max(headers.indexOf("date"), headers.indexOf("datetime"), headers.indexOf("time"));
        var tableIdx = Math.max(headers.indexOf("table"), headers.indexOf("tablename"), headers.indexOf("table_name"));
        var custIdx = Math.max(headers.indexOf("customer"), headers.indexOf("customername"), headers.indexOf("customer_name"));
        var phoneIdx = Math.max(headers.indexOf("phone"), headers.indexOf("customerphone"), headers.indexOf("customer_phone"));
        var totalIdx = Math.max(headers.indexOf("total"), headers.indexOf("total amount"), headers.indexOf("total_amount"));
        var subtotalIdx = Math.max(headers.indexOf("subtotal"), headers.indexOf("sub total"));
        var discountIdx = Math.max(headers.indexOf("discount"), headers.indexOf("discount_amount"));
        var modeIdx = Math.max(headers.indexOf("payment mode"), headers.indexOf("payment_mode"), headers.indexOf("mode"));
        var statusIdx = Math.max(headers.indexOf("status"), headers.indexOf("payment status"), headers.indexOf("payment_status"));
        var itemsIdx = Math.max(headers.indexOf("items"), headers.indexOf("itemssummary"), headers.indexOf("items summary"));
        
        rawId = idIdx >= 0 ? String(row[idIdx] || "").trim() : "";
        rawDate = dateIdx >= 0 ? String(row[dateIdx] || "").trim() : new Date().toISOString();
        rawTable = tableIdx >= 0 ? String(row[tableIdx] || "").trim() : "Table 1";
        rawCustomer = custIdx >= 0 ? String(row[custIdx] || "").trim() : "Guest";
        rawPhone = phoneIdx >= 0 ? String(row[phoneIdx] || "").trim() : "";
        rawTotal = totalIdx >= 0 ? parseFloat(String(row[totalIdx]).replace(/[^0-9.]/g, "")) || 0 : 0;
        rawSubtotal = subtotalIdx >= 0 ? parseFloat(String(row[subtotalIdx]).replace(/[^0-9.]/g, "")) || rawTotal : rawTotal;
        rawDiscount = discountIdx >= 0 ? parseFloat(String(row[discountIdx]).replace(/[^0-9.]/g, "")) || 0 : 0;
        rawMode = modeIdx >= 0 ? String(row[modeIdx] || "CASH").trim() : "CASH";
        rawStatus = statusIdx >= 0 ? String(row[statusIdx] || "PAID").trim().toUpperCase() : "PAID";
        rawItems = itemsIdx >= 0 ? row[itemsIdx] : "";
      } else if (colCount <= 12) {
        rawId = String(row[0] || "").trim();
        rawDate = String(row[1] || "").trim();
        rawCustomer = String(row[2] || "").trim();
        rawPhone = String(row[3] || "").trim();
        rawMode = String(row[4] || "").trim();
        rawSubtotal = parseFloat(String(row[5]).replace(/[^0-9.]/g, "")) || 0;
        rawDiscount = parseFloat(String(row[6]).replace(/[^0-9.]/g, "")) || 0;
        rawTotal = parseFloat(String(row[7]).replace(/[^0-9.]/g, "")) || 0;
        rawItems = row[8];
        rawStatus = String(row[9] || "PAID").trim().toUpperCase();
        rawTable = String(row[10] || "Table 1").trim();
      } else {
        unmappedRows++;
        unmappedDetails.push({ row: i + 1, reason: "Unrecognized column structure (" + colCount + " columns)" });
        continue;
      }
      
      if (!rawId || rawId.toLowerCase() === "id" || rawId.toLowerCase() === "bill id") {
        continue;
      }
      
      var cleanId = cleanOrderId(rawId);
      var cTable = cleanTableId(rawTable);
      var subtotalP = Math.round(rawSubtotal * 100);
      var discountP = Math.round(rawDiscount * 100);
      var grandTotalP = Math.round(rawTotal * 100);
      var taxableP = Math.max(0, subtotalP - discountP);
      var gstP = grandTotalP - taxableP;
      var cgstP = Math.round(gstP / 2);
      var sgstP = gstP - cgstP;
      
      var sessionId = "SES-MIG-" + cleanId;
      var isPaid = isStatusSettled(rawStatus);
      
      if (!isDryRun) {
        sessionsSheet.appendRow([
          sessionId, orgId, cTable, isPaid ? "CLOSED" : "OPEN", 1, "MIGRATION",
          rawCustomer, rawPhone, "", "Migration Script", rawDate, isPaid ? rawDate : "", "", rev
        ]);
        
        ordersSheet.appendRow([
          rawId, sessionId, orgId, cTable, "", 1, "MIGRATION", "Dine-In", "Main Kitchen",
          isPaid ? "SERVED" : "PENDING", rawDate, "", isPaid ? rawDate : "", "", "Staff",
          "migration", "", "", subtotalP, discountP, 0, taxableP, cgstP, sgstP, 0, grandTotalP, rev
        ]);
        
        if (isPaid) {
          paymentsSheet.appendRow([
            "PAY-MIG-" + cleanId, sessionId, rawId, rawMode || "CASH", grandTotalP, 0,
            "", "", true, "Migration Script", rawDate, "", "", rev
          ]);
        }
      }
      
      migratedOrders++;
    } catch (eRow) {
      unmappedRows++;
      unmappedDetails.push({ row: i + 1, reason: eRow.toString() });
    }
  }
  
  return {
    success: true,
    dryRun: isDryRun,
    totalScanned: totalScanned,
    migratedOrders: migratedOrders,
    unmappedRows: unmappedRows,
    unmappedDetails: unmappedDetails.slice(0, 50)
  };
}

function handleGetDelta(params) {
  var orgId = String(params.org || params.org_id || params.outlet || params.outlet_id || params.outletId || "").trim();
  var sheetId = String(params.sheet || params.spreadsheet_id || params.spreadsheetId || "").trim();
  if (!sheetId && orgId) {
    sheetId = getSheetIdForOrg(orgId);
  }
  if (!orgId) {
    return responseJson({ ok: false, success: false, error: "org parameter is required." });
  }

  var lock = LockService.getScriptLock();
  var locked = false;
  try {
    locked = lock.tryLock(5000);
  } catch (eLock) {}

  try {
    var sinceRev = parseInt(params.since || params.since_rev || "0", 10) || 0;
    var currentRev = parseInt(PropertiesService.getScriptProperties().getProperty("rev_" + orgId.trim()), 10) || 0;
    var maxScannedRev = currentRev;
    
    var deltaOrders = [];
    var deltaTables = [];
    var deltaSessions = [];
    var deltaReservations = [];
    var deltaPayments = [];
    var deltaAlerts = [];
    var deltaTombstones = [];
    
    var ss = null;
    if (sheetId && sheetId.indexOf("sheet_") !== 0) {
      try { ss = SpreadsheetApp.openById(sheetId); } catch(e) {}
      if (!ss) {
        return responseJson({
          ok: false,
          success: false,
          error: "Spreadsheet unavailable",
          error_code: "SHEET_UNAVAILABLE",
          retryable: true
        });
      }
    }
    
    if (ss) {
      ensureV2Sheets(ss);
      
      // 1. Orders delta
      var ordersSheet = ss.getSheetByName("Orders");
      if (ordersSheet && ordersSheet.getLastRow() > 1) {
        var oData = ordersSheet.getDataRange().getValues();
        var oHeaders = oData[0].map(function(h) { return String(h || "").trim(); });
        var revCol = oHeaders.indexOf("rev");
        if (revCol === -1) {
          return responseJson({
            ok: false,
            success: false,
            error: "Orders sheet missing 'rev' column",
            error_code: "SCHEMA_MISSING_REV"
          });
        }
        
        for (var i = 1; i < oData.length; i++) {
          var rowRev = parseInt(oData[i][revCol], 10) || 0;
          if (rowRev > maxScannedRev) maxScannedRev = rowRev;
          if (sinceRev === 0 || rowRev > sinceRev) {
            var orderObj = {};
            for (var c = 0; c < oHeaders.length; c++) {
              orderObj[oHeaders[c]] = oData[i][c];
            }
            orderObj.id = orderObj.orderId;
            orderObj.status = orderObj.kitchenStatus;
            orderObj.table = orderObj.tableId;
            orderObj.tableName = "Table " + orderObj.tableId;
            orderObj.totalAmount = (parseFloat(orderObj.grandTotalP) || 0) / 100;
            orderObj.subtotal = (parseFloat(orderObj.subtotalP) || 0) / 100;
            orderObj.rev = rowRev;
            deltaOrders.push(orderObj);

            // S-13: Collect tombstones / deleted order IDs for cancelled or voided orders
            var stUpper = String(orderObj.status || orderObj.kitchenStatus || "").toUpperCase().trim();
            if (stUpper === "CANCELLED" || stUpper === "VOIDED" || stUpper === "DELETED" || orderObj.tombstone === true || orderObj.isDeleted === true) {
              var tId = String(orderObj.id || orderObj.orderId || "").trim();
              if (tId && deltaTombstones.indexOf(tId) === -1) {
                deltaTombstones.push(tId);
              }
            }
          }
        }
      }
      
      // 2. Tables delta
      var tablesSheet = ss.getSheetByName("Tables");
      if (tablesSheet && tablesSheet.getLastRow() > 1) {
        var tData = tablesSheet.getDataRange().getValues();
        var tHeaders = tData[0].map(function(h) { return String(h || "").trim(); });
        var tRevCol = tHeaders.indexOf("rev");
        for (var ti = 1; ti < tData.length; ti++) {
          var tRev = tRevCol !== -1 ? (parseInt(tData[ti][tRevCol], 10) || 0) : 0;
          if (tRev > maxScannedRev) maxScannedRev = tRev;
          if (sinceRev === 0 || tRev > sinceRev) {
            var tObj = {};
            for (var tc = 0; tc < tHeaders.length; tc++) { tObj[tHeaders[tc]] = tData[ti][tc]; }
            tObj.rev = tRev;
            deltaTables.push(tObj);
          }
        }
      }

      // 2b. Sessions delta
      var sessionsSheet = ss.getSheetByName("Sessions");
      if (sessionsSheet && sessionsSheet.getLastRow() > 1) {
        var sesData = sessionsSheet.getDataRange().getValues();
        var sesHeaders = sesData[0].map(function(h) { return String(h || "").trim(); });
        var sesRevCol = sesHeaders.indexOf("rev");
        for (var si = 1; si < sesData.length; si++) {
          var sRev = sesRevCol !== -1 ? (parseInt(sesData[si][sesRevCol], 10) || 0) : 0;
          if (sRev > maxScannedRev) maxScannedRev = sRev;
          if (sinceRev === 0 || sRev > sinceRev) {
            var sesObj = {};
            for (var sc = 0; sc < sesHeaders.length; sc++) { sesObj[sesHeaders[sc]] = sesData[si][sc]; }
            sesObj.rev = sRev;
            deltaSessions.push(sesObj);
          }
        }
      }

      // 3. Reservations delta (T-05)
      var reservationsSheet = ss.getSheetByName("Reservations");
      if (reservationsSheet && reservationsSheet.getLastRow() > 1) {
        var rData = reservationsSheet.getDataRange().getValues();
        var rHeaders = rData[0].map(function(h) { return String(h || "").trim(); });
        var rRevCol = rHeaders.indexOf("rev");
        for (var ri = 1; ri < rData.length; ri++) {
          var rRev = rRevCol !== -1 ? (parseInt(rData[ri][rRevCol], 10) || 0) : 0;
          if (rRev > maxScannedRev) maxScannedRev = rRev;
          if (sinceRev === 0 || rRev > sinceRev) {
            var rObj = {};
            for (var rc = 0; rc < rHeaders.length; rc++) { rObj[rHeaders[rc]] = rData[ri][rc]; }
            rObj.rev = rRev;
            deltaReservations.push(rObj);
          }
        }
      }

      // 4. Alerts delta
      var alertsSheet = ss.getSheetByName("Alerts");
      if (alertsSheet && alertsSheet.getLastRow() > 1) {
        var aData = alertsSheet.getDataRange().getValues();
        var aHeaders = aData[0].map(function(h) { return String(h || "").trim(); });
        var aRevCol = aHeaders.indexOf("rev");
        for (var ai = 1; ai < aData.length; ai++) {
          var aRev = aRevCol !== -1 ? (parseInt(aData[ai][aRevCol], 10) || 0) : 0;
          if (aRev > maxScannedRev) maxScannedRev = aRev;
          if (sinceRev === 0 || aRev > sinceRev) {
            var aObj = {};
            for (var ac = 0; ac < aHeaders.length; ac++) { aObj[aHeaders[ac]] = aData[ai][ac]; }
            aObj.rev = aRev;
            deltaAlerts.push(aObj);
          }
        }
      }
    }
    
    // Fallback if Orders v2 empty on initial fetch
    if (deltaOrders.length === 0 && sinceRev === 0) {
      var rawCached = PropertiesService.getScriptProperties().getProperty("recent_orders_" + orgId.trim());
      if (rawCached) {
        try {
          var cList = JSON.parse(rawCached);
          if (Array.isArray(cList)) {
            deltaOrders = cList.filter(function(o) { return !isStatusSettled(o.status); });
          }
        } catch(e) {}
      }
    }

    // 5. Inventory / Item Availability Delta (§7.2, §7.3, S-19)
    var deltaInventory = [];
    if (ss) {
      try {
        var invSheet = getInventorySheet(ss);
        if (invSheet && invSheet.getLastRow() > 1) {
          var inData = invSheet.getDataRange().getValues();
          var inHeaders = inData[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
          var idCol = -1, nameCol = -1, stockCol = -1, availCol = -1, inRevCol = -1;
          for (var c = 0; c < inHeaders.length; c++) {
            var h = inHeaders[c];
            if (h.indexOf("id") !== -1 && idCol === -1) idCol = c;
            if ((h.indexOf("name") !== -1 || h.indexOf("dish") !== -1) && nameCol === -1) nameCol = c;
            if (h.indexOf("stock") !== -1 || h.indexOf("qty") !== -1 || h.indexOf("quantity") !== -1) stockCol = c;
            if (h.indexOf("avail") !== -1 || h.indexOf("status") !== -1) availCol = c;
            if (h === "rev") inRevCol = c;
          }
          if (idCol === -1) idCol = 0;
          if (nameCol === -1) nameCol = 1;

          for (var ri = 1; ri < inData.length; ri++) {
            var invRowRev = inRevCol !== -1 ? (parseInt(inData[ri][inRevCol], 10) || 0) : 0;
            if (invRowRev > maxScannedRev) maxScannedRev = invRowRev;
            if (sinceRev === 0 || (inRevCol !== -1 && invRowRev > sinceRev)) {
              var pId = String(inData[ri][idCol] || "").trim();
              var pName = String(inData[ri][nameCol] || "").trim();
              var pStock = stockCol !== -1 ? inData[ri][stockCol] : -1;
              var pAvail = true;
              if (availCol !== -1 && inData[ri][availCol] !== undefined) {
                var avStr = String(inData[ri][availCol]).toLowerCase().trim();
                if (avStr === "false" || avStr === "0" || avStr === "no" || avStr === "sold out" || avStr === "unavailable") {
                  pAvail = false;
                }
              }
              if (pId) {
                deltaInventory.push({
                  id: pId,
                  name: pName,
                  stock: pStock !== "" && pStock !== null && pStock !== undefined ? Number(pStock) : -1,
                  isAvailable: pAvail,
                  rev: invRowRev
                });
              }
            }
          }
        }
      } catch(eInv) {}
    }

    return responseJson({
      ok: true,
      success: true,
      rev: maxScannedRev || currentRev,
      since: sinceRev,
      orders: deltaOrders,
      tables: deltaTables,
      sessions: deltaSessions,
      reservations: deltaReservations,
      payments: deltaPayments,
      alerts: deltaAlerts,
      inventory: deltaInventory,
      tombstones: deltaTombstones,
      deleted: deltaTombstones,
      serverTime: new Date().toISOString()
    });
  } catch(errDelta) {
    return responseJson({ ok: false, success: false, error: errDelta.toString() });
  } finally {
    if (locked) {
      try { lock.releaseLock(); } catch(eL) {}
    }
  }
}
}

function doGet(e) {
  var params = (e && e.parameter) ? e.parameter : {};
  var orgId = params.org || params.org_id || "";
  var sheetId = params.sheet || params.spreadsheet_id || "";

  // Resolve private Google Sheet ID from server-side tenant registry if not explicitly passed
  if (!sheetId && orgId) {
    sheetId = getSheetIdForOrg(orgId);
  }

  // Adaptive delta sync protocol (§3.2, §6.2)
  if (params.action === "GET_DELTA" || params.action === "FETCH_DELTA") {
    return handleGetDelta(params);
  }

  var tenantInfo = getTenantInfo(orgId);

  // 1. GET_MENU / FETCH_MENU for Diners
  if (sheetId && (params.action === "GET_MENU" || params.action === "FETCH_MENU" || !params.action)) {
    try {
      var ss = SpreadsheetApp.openById(sheetId);
      var sheet = getInventorySheet(ss) || ss.getSheets()[0];
      var data = sheet ? sheet.getDataRange().getValues() : [];
      var items = [];
      if (data && data.length > 1) {
        var headers = data[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
        var nameIdx = -1, priceIdx = -1, catIdx = -1, vegIdx = -1, descIdx = -1, idIdx = -1, availIdx = -1;
        headers.forEach(function(h, idx) {
          if (h.indexOf("name") !== -1 || h.indexOf("dish") !== -1 || h.indexOf("item") !== -1) nameIdx = idx;
          if (h.indexOf("selling") !== -1 || h.indexOf("retail") !== -1 || (h.indexOf("price") !== -1 && h.indexOf("purchase") === -1 && h.indexOf("cost") === -1) || h.indexOf("mrp") !== -1 || h.indexOf("rate") !== -1) {
            if (priceIdx === -1 || h.indexOf("selling") !== -1) priceIdx = idx;
          }
          if (h.indexOf("cat") !== -1 || h.indexOf("type") !== -1 || h.indexOf("section") !== -1) catIdx = idx;
          if (h.indexOf("veg") !== -1 || h.indexOf("diet") !== -1) vegIdx = idx;
          if (h.indexOf("desc") !== -1 || h.indexOf("detail") !== -1) descIdx = idx;
          if (h.indexOf("id") !== -1 && h.indexOf("cat") === -1) idIdx = idx;
          if (h.indexOf("avail") !== -1 || h.indexOf("status") !== -1 || h.indexOf("sold") !== -1) availIdx = idx;
        });

        if (nameIdx === -1) nameIdx = 1;
        if (priceIdx === -1) priceIdx = 4;
        if (catIdx === -1) catIdx = 2;

        for (var r = 1; r < data.length; r++) {
          var row = data[r];
          var name = String(row[nameIdx] || "").trim();
          if (!name || name === "DELETED" || name.toLowerCase() === "product name") continue;
          var price = parseFloat(String(row[priceIdx] || "0").replace(/[^0-9.]/g, "")) || 0;
          var category = (catIdx !== -1 && row[catIdx]) ? String(row[catIdx]).trim() : "All Items";
          var isVeg = true;
          if (vegIdx !== -1 && row[vegIdx] !== undefined) {
            var v = String(row[vegIdx]).toLowerCase();
            if (v.indexOf("non") !== -1 || v === "egg" || v === "nv" || v === "no" || v === "false") isVeg = false;
          } else {
            var l = name.toLowerCase();
            if (l.indexOf("chicken") !== -1 || l.indexOf("mutton") !== -1 || l.indexOf("egg") !== -1 || l.indexOf("fish") !== -1 || l.indexOf("meat") !== -1 || l.indexOf("kabab") !== -1) isVeg = false;
          }

          var isAvailable = true;
          if (availIdx !== -1 && row[availIdx] !== undefined) {
            var av = String(row[availIdx]).toLowerCase().trim();
            if (av === "false" || av === "0" || av === "no" || av === "sold out" || av === "sold_out" || av === "unavailable" || av === "inactive") {
              isAvailable = false;
            }
          }

          // Strip out wholesale price, purchase cost, supplier details - public guest safety!
          items.push({
            id: (idIdx !== -1 && row[idIdx]) ? String(row[idIdx]) : "dish_" + r,
            name: name,
            price: price,
            category: category,
            description: (descIdx !== -1 && row[descIdx]) ? String(row[descIdx]) : "",
            isVeg: isVeg,
            available: isAvailable
          });
        }
      }

      return responseJson({
        success: true,
        items: items,
        restaurant_name: tenantInfo ? (tenantInfo.org_name || "") : "",
        upi_id: tenantInfo ? (tenantInfo.upi_id || "") : ""
      });
    } catch (err) {
      return responseJson({ success: false, error: err.toString() });
    }
  }

  // 2. GET_ORDERS / FETCH_ORDERS for Table Syncing & Live Status
  if (params.action === "GET_ORDERS" || params.action === "FETCH_ORDERS") {
    if (!orgId) {
      return responseJson({ success: false, error: "org parameter is required for multi-tenant isolation." });
    }
    try {
      var ordersMap = {};
      var reqTable = (params.table || "").toLowerCase().trim();
      var cReqTable = reqTable ? cleanTableId(reqTable) : "";
      var ss = null;
      var nowTime = new Date().getTime();

      var props = PropertiesService.getScriptProperties();
      var settledIds = [];
      try {
        var rawSettled = props.getProperty("settled_orders_" + orgId.trim());
        if (rawSettled) settledIds = JSON.parse(rawSettled);
      } catch (e) {}


      // 1. First retrieve recent memory-cached orders from ScriptProperties
      try {
        var key = "recent_orders_" + orgId.trim();
        var rawCached = props.getProperty(key);
        if (rawCached) {
          var cachedList = JSON.parse(rawCached);
          if (Array.isArray(cachedList)) {
            for (var cIdx = 0; cIdx < cachedList.length; cIdx++) {
              var co = cachedList[cIdx];
              var cNormId = cleanOrderId(co.id || co.orderId || "");
              if (!cNormId || isStatusSettled(co.status) || settledIds.indexOf(cNormId) !== -1) {
                continue;
              }
              // Filter out test orders!
              if (cNormId.indexOf("TEST") !== -1 || (co.customerName && String(co.customerName).toUpperCase().indexOf("TEST") !== -1)) {
                continue;
              }
              var coTableClean = cleanTableId(co.tableName || co.table || "");
              if (cReqTable && coTableClean !== cReqTable) {
                continue;
              }
              // Orders are kept active until settled or closed
              ordersMap[cNormId] = co;
            }
          }
        }
      } catch (eCache) {}

      // 2. Then retrieve from Google Sheet if sheetId is available
      if (sheetId && sheetId.indexOf("sheet_") !== 0) {
        try {
          ss = SpreadsheetApp.openById(sheetId);
          var sheet = getOrCreateBillsSheet(ss);
          if (sheet) {
            var data = sheet.getDataRange().getValues();
            if (data && data.length > 1) {
              var headers = data[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
              var cols = resolveBillColumns(headers);
              var idIdx = cols.idIdx, dateIdx = cols.dateIdx, nameIdx = cols.nameIdx, phoneIdx = cols.phoneIdx,
                  modeIdx = cols.modeIdx, subtotalIdx = cols.subtotalIdx, totalIdx = cols.totalIdx,
                  itemsIdx = cols.itemsIdx, statusIdx = cols.statusIdx, tableIdx = cols.tableIdx, txnIdx = cols.txnIdx;

              for (var r = 1; r < data.length; r++) {
                var row = data[r];
                var rawId = cleanOrderId(row[idIdx]);
                if (!rawId || rawId.toLowerCase() === "bill id" || rawId.toLowerCase() === "id") continue;
                // Filter out test orders!
                if (rawId.indexOf("TEST") !== -1 || (row[nameIdx] && String(row[nameIdx]).toUpperCase().indexOf("TEST") !== -1)) continue;

                var rawStatus = statusIdx !== -1 ? String(row[statusIdx] || "").trim() : "";
                var rowItemsStr = "";
                if (rawStatus.indexOf("[") === 0 || rawStatus.indexOf("{") === 0) {
                  rowItemsStr = rawStatus;
                  if (row[statusIdx + 1] !== undefined && String(row[statusIdx + 1]).indexOf("[") === -1 && String(row[statusIdx + 1]).indexOf("{") === -1 && String(row[statusIdx + 1]).trim() !== "") {
                    rawStatus = String(row[statusIdx + 1]).trim();
                  } else if (row[9] !== undefined && String(row[9]).indexOf("[") === -1 && String(row[9]).indexOf("{") === -1 && String(row[9]).trim() !== "") {
                    rawStatus = String(row[9]).trim();
                  } else {
                    rawStatus = "ORDER_RECEIVED";
                  }
                }
                if (!rawStatus) rawStatus = "ORDER_RECEIVED";

                // If this order is settled, NEVER return to active table session!
                if (isStatusSettled(rawStatus) || settledIds.indexOf(rawId) !== -1) {
                  continue;
                }

                var rawTableClean = cleanTableId(row[tableIdx]);
                if (cReqTable && rawTableClean !== cReqTable) {
                  continue;
                }

                var rawDate = dateIdx !== -1 ? String(row[dateIdx] || "").trim() : "";
                var rawMode = modeIdx !== -1 ? String(row[modeIdx] || "").trim() : "";
                var rawName = nameIdx !== -1 ? String(row[nameIdx] || "").trim() : "";
                if (rawName.toLowerCase().indexOf("table") === 0 || 
                    rawName.toLowerCase().indexOf("takeaway") === 0 ||
                    rawName.indexOf(" x") !== -1 || 
                    rawName.indexOf("{") !== -1 || 
                    rawName.indexOf("[") !== -1 || 
                    rawName.indexOf(",") !== -1) {
                  rawName = "";
                }
                var rawPhone = phoneIdx !== -1 ? String(row[phoneIdx] || "").trim() : "";
                var rawTxn = txnIdx !== -1 ? String(row[txnIdx] || "").trim() : "";

                // SAFE ITEM & TOTAL EXTRACTION (Guards against shifted columns & scientific notation)
                var cellTotal = String(row[totalIdx] || "").trim();
                var cellItems = itemsIdx !== -1 ? String(row[itemsIdx] || "").trim() : "";

                // If cellTotal starts with JSON brackets, columns are shifted (cellTotal has dishes!)
                if (cellTotal.indexOf("[") === 0 || cellTotal.indexOf("{") === 0) {
                  cellItems = cellTotal;
                  cellTotal = subtotalIdx !== -1 ? String(row[subtotalIdx] || "0") : "0";
                }

                // If cellItems looks like "Table X" or does not contain JSON, scan row for actual JSON items
                if (cellItems.toLowerCase().indexOf("table ") === 0 || cellItems.toLowerCase().indexOf("table_") === 0 || cellItems === "") {
                  for (var ci = 0; ci < row.length; ci++) {
                    var candidate = String(row[ci] || "").trim();
                    if (candidate.indexOf("[{") === 0 || candidate.indexOf('{"') === 0) {
                      cellItems = candidate;
                      break;
                    }
                  }
                }

                var parsedItems = [];
                if (cellItems.indexOf("[") === 0) {
                  try {
                    parsedItems = JSON.parse(cellItems);
                  } catch (e) {
                    parsedItems = [];
                  }
                }

                // Parse total with strict corruption limits
                var rawTotal = 0;
                var totalRecovered = false;
                var isCorrupted = false;

                if (cellTotal.indexOf("[") !== -1 || cellTotal.indexOf("{") !== -1 || /e[+-]?\d+/i.test(cellTotal)) {
                  isCorrupted = true;
                } else {
                  var cleanedTotalStr = cellTotal.replace(/[^0-9.]/g, "");
                  if (cleanedTotalStr.length > 9 || (cleanedTotalStr.length > 0 && isNaN(parseFloat(cleanedTotalStr)))) {
                    isCorrupted = true;
                  } else {
                    rawTotal = parseFloat(cleanedTotalStr) || 0;
                  }
                }

                // Trigger recovery ONLY on genuine corruption (isNaN, >10M, JSON/exponential), not on <= 0 (which can be comped/blank)
                if (isCorrupted || isNaN(rawTotal) || rawTotal > 10000000) {
                  if (parsedItems && parsedItems.length > 0) {
                    var sub = parsedItems.reduce(function(acc, it) {
                      var p = parseFloat(it.price || it.rate) || 0;
                      var q = parseFloat(it.qty || it.quantity) || 1;
                      if (isNaN(p) || !isFinite(p) || p < 0) p = 0;
                      return acc + (p * q);
                    }, 0);
                    var gstRateRec = 5;
                    rawTotal = Math.round(sub * (1 + (gstRateRec / 100)) * 100) / 100;
                    totalRecovered = true;
                  } else {
                    rawTotal = 0;
                  }
                }

                if (parsedItems.length === 0 && cellItems && cellItems.toLowerCase().indexOf("table ") !== 0) {
                  parsedItems = [{ name: cellItems, qty: 1, price: rawTotal }];
                }

                var canonicalTable = row[tableIdx] || ("Table " + rawTableClean);
                var rawOrderSource = (cols.orderSourceIdx !== -1 && cols.orderSourceIdx !== undefined) ? String(row[cols.orderSourceIdx] || "").trim() : "";
                var rawOrderType = (cols.orderTypeIdx !== -1 && cols.orderTypeIdx !== undefined) ? String(row[cols.orderTypeIdx] || "").trim() : "";

                var orderObj = {
                  id: rawId,
                  orderId: rawId,
                  kotNumber: "KOT-" + rawId,
                  customerName: rawName || "Dine-In Guest",
                  customerPhone: rawPhone,
                  totalAmount: rawTotal,
                  total: rawTotal,
                  total_recovered: totalRecovered,
                  items: parsedItems,
                  itemsSummary: rawItems,
                  status: rawStatus,
                  paymentMode: rawMode,
                  table: canonicalTable,
                  tableName: canonicalTable,
                  transactionId: rawTxn,
                  timestamp: rawDate,
                  orderSource: rawOrderSource || (canonicalTable.toLowerCase().indexOf("qr") !== -1 ? "QR" : "POS_COUNTER"),
                  orderType: rawOrderType || "Dine-In"
                };

                if (ordersMap[rawId]) {
                  var prev = ordersMap[rawId];
                  var newRank = getStatusRank(rawStatus);
                  var prevRank = getStatusRank(prev.status);
                  if (newRank >= prevRank) {
                    ordersMap[rawId] = orderObj;
                  } else {
                    orderObj.status = prev.status;
                    ordersMap[rawId] = orderObj;
                  }
                } else {
                  ordersMap[rawId] = orderObj;
                }
              }
            }
          }
        } catch (ssErr) {}
      }

      var finalOrders = [];
      for (var k in ordersMap) {
        var ord = ordersMap[k];
        if (!isStatusSettled(ord.status)) {
          finalOrders.push(ord);
        }
      }

      var activeAlerts = getActiveWaiterAlerts(orgId, ss);
      if (cReqTable) {
        activeAlerts = activeAlerts.filter(function(a) {
          return cleanTableId(a.table || a.tableName) === cReqTable;
        });
      }

      return responseJson({ success: true, orders: finalOrders, waiterCalls: activeAlerts });
    } catch (err) {
      return responseJson({ success: false, error: err.toString() });
    }
  }

  return responseJson({
    status: "ONLINE",
    message: "Smart POS Google Apps Script Webhook is active and running.",
    timestamp: new Date().toISOString()
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 1. CREATE OUTLET SPREADSHEET AUTOMATICALLY IN YOUR GOOGLE DRIVE
// ─────────────────────────────────────────────────────────────────────────────
function handleCreateOutlet(data) {
  const orgId = data.org_id || "ORG";
  const outletId = data.outlet_id || "OUTLET";
  const outletName = data.outlet_name || "Main Branch";

  // Create a new Google Spreadsheet in your personal Google Drive
  const fileName = outletName + " - Store Ledger (" + orgId + ")";
  const ss = SpreadsheetApp.create(fileName);

  // NOTE: Sheet remains 100% PRIVATE in Google Drive. No public ANYONE_WITH_LINK permission granted!

  // 1. Setup Bills Sheet
  let billsSheet = ss.getSheetByName("Sheet1");
  if (!billsSheet) {
    billsSheet = ss.insertSheet("Bills");
  } else {
    billsSheet.setName("Bills");
  }
  billsSheet.appendRow([
    "Bill ID", "Date & Time", "Customer Name", "Customer Phone", 
    "Payment Mode", "Subtotal", "Discount", "Total Amount", "Items Summary", "Status", "Table", "Transaction ID"
  ]);
  billsSheet.getRange("A1:L1").setFontWeight("bold").setBackground("#E0F2FE");
  billsSheet.setFrozenRows(1);

  // 2. Setup Inventory Sheet
  const invSheet = ss.insertSheet("Inventory");
  invSheet.appendRow([
    "Product ID", "Product Name", "Category", "Barcode", 
    "Selling Price", "Purchase Price", "Stock Quantity", "Unit", "Is Available"
  ]);
  invSheet.getRange("A1:I1").setFontWeight("bold").setBackground("#FEF3C7");
  invSheet.setFrozenRows(1);

  // 3. Setup Customers / Udhaar Khata Sheet
  const custSheet = ss.insertSheet("Customers");
  custSheet.appendRow([
    "Customer ID", "Customer Name", "Phone", "Outstanding Balance", 
    "Credit Limit", "Loyalty Points", "Last Transaction Date"
  ]);
  custSheet.getRange("A1:G1").setFontWeight("bold").setBackground("#DCFCE7");
  custSheet.setFrozenRows(1);

  // 4. Setup Expenses Sheet
  const expSheet = ss.insertSheet("Expenses");
  expSheet.appendRow(["Expense ID", "Date", "Category", "Amount", "Paid Via", "Notes"]);
  expSheet.getRange("A1:F1").setFontWeight("bold").setBackground("#FEE2E2");
  expSheet.setFrozenRows(1);

  // 5. Setup Day-Close Z-Reports Sheet
  const zSheet = ss.insertSheet("Z_Reports");
  zSheet.appendRow([
    "Report ID", "Date", "Total Sales", "Cash Collected", 
    "UPI / Online", "Card", "Udhaar Given", "Cash in Drawer", "Discrepancy"
  ]);
  zSheet.getRange("A1:I1").setFontWeight("bold").setBackground("#F3E8FF");
  zSheet.setFrozenRows(1);

  const sheetId = ss.getId();
  const sheetUrl = ss.getUrl();

  // Register in script properties for server-side lookup
  try {
    PropertiesService.getScriptProperties().setProperty("org_" + orgId.trim(), JSON.stringify({
      org_id: orgId.trim(),
      spreadsheet_id: sheetId,
      org_name: outletName,
      updated_at: new Date().toISOString()
    }));
  } catch (e) {}

  return responseJson({
    success: true,
    outlet_id: outletId,
    outlet_name: outletName,
    spreadsheet_id: sheetId,
    sheet_url: sheetUrl
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. ONBOARD ORGANIZATION
// ─────────────────────────────────────────────────────────────────────────────
function handleOnboardOrganization(data) {
  return responseJson({
    success: true,
    org_id: data.org_id,
    message: "Organization recorded in cloud backend."
  });
}

/// ─────────────────────────────────────────────────────────────────────────────
// 3. SAVE / UPDATE BILL IN OUTLET SPREADSHEET (Zero-Cost Order Signaling)
// ─────────────────────────────────────────────────────────────────────────────
function handleSaveBill(data) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ success: false, error: "Server busy, lock acquisition timed out. Please retry." });
  }

  try {
    let spreadsheetId = data.spreadsheet_id || data.spreadsheetId;
    const orgId = String(data.org_id || data.orgId || data.org || data.outlet_id || data.outletId || "").trim();

    // Resolve spreadsheetId from tenant registry if omitted by client
    if ((!spreadsheetId || spreadsheetId.indexOf("sheet_") === 0) && orgId) {
      spreadsheetId = getSheetIdForOrg(orgId);
    }

    var ss = null;
    if (spreadsheetId && spreadsheetId.indexOf("sheet_") !== 0) {
      try {
        ss = SpreadsheetApp.openById(spreadsheetId);
      } catch (e) {}
    }

    const b = data.data || data.bill || {};
    var clientRequestId = String(data.clientRequestId || data.client_request_id || b.clientRequestId || b.client_request_id || "").trim();
    if (clientRequestId) {
      var cachedIdemp = checkIdempotency(ss, clientRequestId);
      if (cachedIdemp) {
        return responseJson(cachedIdemp);
      }
    }

    const cust = b.customer || {};
    var billId = String(b.bill_id || b.billId || b.id || "");
    if (!billId || billId === "null" || billId === "undefined") {
      var orderSeq = allocateCounter(ss, orgId, "ORDER");
      var now = new Date();
      var ymd = Utilities.formatDate(now, Session.getScriptTimeZone() || "GMT+05:30", "yyyyMMdd");
      billId = "ORD-" + ymd + "-" + ("0000" + orderSeq).slice(-4);
    }
    const cleanId = cleanOrderId(billId);
    var rev = getAndBumpRev(orgId);

    var tokenNo = b.token_no || b.tokenNo;
    if (!tokenNo && ss) {
      tokenNo = allocateCounter(ss, orgId, "TOKEN");
    }
    var kotNumber = b.kot_number || b.kotNumber || (tokenNo ? ("#" + tokenNo) : (cleanId ? ("KOT-" + cleanId) : billId));

    const isStatusUpdate = (b.update_type === "STATUS_UPDATE" || data.update_type === "STATUS_UPDATE" || data.action === "UPDATE_ORDER_STATUS");

    // Reject missing table name instead of defaulting to "Table 1" (skip for STATUS_UPDATE)
    const tableNameRaw = b.table_name || b.tableName || (b.table_number ? ("Table " + b.table_number) : (b.tableNumber ? ("Table " + b.tableNumber) : (b.table || "")));
    if (!isStatusUpdate && (!tableNameRaw || String(tableNameRaw).trim() === "")) {
      return responseJson({ success: false, error: "Invalid order: missing table name or table number." });
    }
    const tableName = String(tableNameRaw || "").trim();
    const cTable = cleanTableId(tableName);

    const status = String(b.payment_status || b.paymentStatus || b.status || "ORDER_RECEIVED").toUpperCase().trim();
    const isSettled = isStatusSettled(status);
    const txnId = b.transaction_id || b.transactionId || b.upi_reference || b.upiReference || "";

    // Require total_amount (or totalAmount); DO NOT fall back to subtotal! (skip for STATUS_UPDATE)
    const rawTotal = b.total_amount !== undefined ? b.total_amount : (b.totalAmount !== undefined ? b.totalAmount : null);
    if (!isStatusUpdate && rawTotal === null) {
      return responseJson({ success: false, error: "Invalid order: missing total_amount." });
    }
    const totalAmount = rawTotal !== null ? (parseFloat(String(rawTotal).replace(/[^0-9.]/g, "")) || 0) : 0;
    const timeStr = b.timestamp || b.created_at || b.createdAt || new Date().toISOString();
    const rawItems = b.items || [];
    const paymentMode = String(b.payment_mode || b.paymentMode || (isSettled ? "PAID" : "PENDING")).trim();
    const customerName = String(b.customer_name || b.customerName || cust.name || (tableName.indexOf("Table ") === 0 ? "Dine-In Guest" : tableName)).trim();
    const customerPhone = String(b.customer_phone || b.customerPhone || cust.phone || "").trim();
    const subtotal = parseFloat(String(b.subtotal || b.subtotal_amount || b.subtotalAmount || totalAmount).replace(/[^0-9.]/g, "")) || totalAmount;
    const specialInstructions = String(b.special_instructions || b.specialInstructions || b.notes || "").trim();

    if (orgId) {
      try {
        var props = PropertiesService.getScriptProperties();

        if (isSettled) {
          // === PAYMENT SETTLED / CONFIRMED ===
          // 1. Record individual settled order ID (NO table-wide cutoff)
          if (cleanId) {
            var settledKey = "settled_orders_" + orgId.trim();
            var rawSettled = props.getProperty(settledKey);
            var settledList = [];
            if (rawSettled) {
              try { settledList = JSON.parse(rawSettled); } catch(e) {}
            }
            if (settledList.indexOf(cleanId) === -1) {
              settledList.push(cleanId);
              if (settledList.length > 500) settledList = settledList.slice(-500);
              props.setProperty(settledKey, JSON.stringify(settledList));
            }
          }

          // 2. Purge ONLY this specific settled order from recent_orders_ memory cache
          var cacheKey = "recent_orders_" + orgId.trim();
          var rawCached = props.getProperty(cacheKey);
          if (rawCached) {
            var cachedOrders = [];
            try { cachedOrders = JSON.parse(rawCached); } catch(e) {}
            cachedOrders = cachedOrders.filter(function(co) {
              var coCleanId = cleanOrderId(co.id || co.orderId);
              if (coCleanId === cleanId) return false;
              return true;
            });
            props.setProperty(cacheKey, JSON.stringify(cachedOrders));
          }

          // 3. Clear pending waiter alerts for this table if applicable
          var waiterKey = "waiter_alerts_" + orgId.trim();
          var rawWaiters = props.getProperty(waiterKey);
          if (rawWaiters) {
            try {
              var wList = JSON.parse(rawWaiters);
              wList = wList.filter(function(w) { return cleanTableId(w.table || w.tableName) !== cTable; });
              props.setProperty(waiterKey, JSON.stringify(wList));
            } catch(e) {}
          }
        } else {
          // === ORDER IN PROGRESS ===
          if (cleanId.indexOf("TEST") !== -1 || (customerName && customerName.toUpperCase().indexOf("TEST") !== -1)) {
            return responseJson({ success: true, message: "Test order ignored." });
          }

          var cacheKey = "recent_orders_" + orgId.trim();
          var rawCached = props.getProperty(cacheKey);
          var cachedOrders = [];
          if (rawCached) {
            try { cachedOrders = JSON.parse(rawCached); } catch (e) { cachedOrders = []; }
          }

          var foundIdx = -1;
          for (var ci = 0; ci < cachedOrders.length; ci++) {
            var cNorm = cleanOrderId(cachedOrders[ci].id || cachedOrders[ci].orderId);
            if (cNorm === cleanId) {
              foundIdx = ci;
              break;
            }
          }

          if (foundIdx !== -1) {
            var prev = cachedOrders[foundIdx];
            var prevRank = getStatusRank(prev.kitchenStatus || prev.status);
            var newRank = getStatusRank(b.kitchenStatus || b.status || status);
            var effectiveKitchenStatus = newRank >= prevRank ? (b.kitchenStatus || b.status || status) : (prev.kitchenStatus || prev.status);

            var mergedItems = (rawItems && rawItems.length > 0) ? rawItems : (prev.items || []);
            var mergedItemsSummary = (typeof rawItems === "string" && rawItems) ? rawItems : 
              ((rawItems && rawItems.length > 0) ? JSON.stringify(rawItems) : (prev.itemsSummary || ""));
            var mergedCustName = customerName || prev.customerName || "Dine-In Guest";
            if (mergedCustName && (mergedCustName.indexOf("Table ") === 0 || mergedCustName.indexOf(" x") !== -1 || mergedCustName.indexOf("{") !== -1 || mergedCustName.indexOf("[") !== -1 || mergedCustName.indexOf(",") !== -1)) {
              mergedCustName = "Dine-In Guest";
            }
            var mergedCustPhone = customerPhone || prev.customerPhone || "";
            var mergedTotal = totalAmount > 0 ? totalAmount : (prev.totalAmount || prev.total || 0);
            var mergedTime = prev.timestamp || timeStr;

            var orderObj = {
              id: prev.id || billId,
              orderId: prev.orderId || billId,
              kotNumber: prev.kotNumber || (cleanId ? ("KOT-" + cleanId) : billId),
              customerName: mergedCustName,
              customerPhone: mergedCustPhone,
              totalAmount: mergedTotal,
              total: mergedTotal,
              items: mergedItems,
              itemsSummary: mergedItemsSummary,
              status: status,
              kitchenStatus: effectiveKitchenStatus,
              paymentMode: paymentMode || prev.paymentMode || "DINE_IN",
              table: tableName || prev.table,
              tableName: tableName || prev.tableName,
              orderSource: String(b.order_source || b.orderSource || prev.orderSource || (tableName.toLowerCase().indexOf("qr") !== -1 ? "QR" : "POS_COUNTER")).trim(),
              orderType: String(b.order_type || b.orderType || prev.orderType || "Dine-In").trim(),
              transactionId: txnId || prev.transactionId,
              specialInstructions: specialInstructions || prev.specialInstructions || "",
              timestamp: mergedTime
            };

            cachedOrders[foundIdx] = orderObj;
          } else {
            var safeCustName = customerName || "Dine-In Guest";
            if (safeCustName && (safeCustName.indexOf("Table ") === 0 || safeCustName.indexOf(" x") !== -1 || safeCustName.indexOf("{") !== -1 || safeCustName.indexOf("[") !== -1 || safeCustName.indexOf(",") !== -1)) {
              safeCustName = "Dine-In Guest";
            }
            var orderObj = {
              id: billId,
              orderId: billId,
              kotNumber: kotNumber,
              tokenNo: tokenNo,
              customerName: safeCustName,
              customerPhone: customerPhone,
              totalAmount: totalAmount,
              total: totalAmount,
              items: rawItems,
              itemsSummary: typeof rawItems === "string" ? rawItems : JSON.stringify(rawItems),
              status: status,
              kitchenStatus: b.kitchenStatus || b.status || status,
              paymentMode: paymentMode || "DINE_IN",
              table: tableName,
              tableName: tableName,
              orderSource: String(b.order_source || b.orderSource || (tableName.toLowerCase().indexOf("qr") !== -1 ? "QR" : "POS_COUNTER")).trim(),
              orderType: String(b.order_type || b.orderType || "Dine-In").trim(),
              transactionId: txnId,
              specialInstructions: specialInstructions,
              timestamp: timeStr
            };
            cachedOrders.push(orderObj);
          }
          // Sheet-backed tracking without arbitrary 50-order cap
          props.setProperty(cacheKey, JSON.stringify(cachedOrders));
        }
      } catch (eCache) {}
    }

    function buildResult(extra) {
      var res = {
        success: true,
        ok: true,
        id: billId,
        order_id: billId,
        bill_id: billId,
        kotNumber: kotNumber,
        kot_number: kotNumber,
        token_no: tokenNo,
        status: isSettled ? "PAID" : status,
        rev: rev
      };
      if (extra) {
        for (var k in extra) { res[k] = extra[k]; }
      }
      if (clientRequestId) {
        recordIdempotency(ss, clientRequestId, "SAVE_BILL", res);
      }
      return responseJson(res);
    }

    if (!spreadsheetId || spreadsheetId.indexOf("sheet_") === 0) {
      return buildResult({
        cached: true,
        message: isSettled ? "Order settled and removed from active cache." : "Order cached in cloud memory."
      });
    }

    // Google Sheets persistence
    try {
      if (!ss) ss = SpreadsheetApp.openById(spreadsheetId);
      const sheet = getOrCreateBillsSheet(ss);
      const lastRow = sheet.getLastRow();
      let existingRow = -1;

      let idIdx = 0, statusIdx = 9, modeIdx = 4, tableIdx = 10, txnIdx = 11;
      if (lastRow > 1) {
        const data = sheet.getDataRange().getValues();
        var headers = data[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
        var cols = resolveBillColumns(headers);
        idIdx = cols.idIdx;
        statusIdx = cols.statusIdx;
        modeIdx = cols.modeIdx;
        tableIdx = cols.tableIdx;
        txnIdx = cols.txnIdx;

        // Find matching row by clean ID
        for (let i = 1; i < data.length; i++) {
          const rowNormId = cleanOrderId(data[i][idIdx]);
          if (rowNormId && rowNormId === cleanId) {
            existingRow = i + 1;
            break;
          }
        }

        // Only update status for THIS specific bill row if settled
        if (isSettled && existingRow !== -1) {
          sheet.getRange(existingRow, statusIdx + 1).setValue("PAID");
          if (paymentMode) sheet.getRange(existingRow, modeIdx + 1).setValue(paymentMode);
          if (txnId) sheet.getRange(existingRow, txnIdx + 1).setValue(txnId);
        }

        // If updating an existing row for status update with no items provided, only update status & txn
        if (existingRow !== -1 && (isStatusUpdate || b.update_type === "STATUS_UPDATE" || (!rawItems || rawItems.length === 0))) {
          sheet.getRange(existingRow, statusIdx + 1).setValue(isSettled ? "PAID" : status);
          if (txnId) sheet.getRange(existingRow, txnIdx + 1).setValue(txnId);
          return buildResult({
            row: existingRow,
            cleared: isSettled
          });
        }
      }

      const rowData = [
        billId,
        timeStr,
        customerName,
        customerPhone,
        paymentMode,
        subtotal,
        b.discount || b.discount_amount || 0,
        totalAmount,
        typeof rawItems === "string" ? rawItems : JSON.stringify(rawItems),
        isSettled ? "PAID" : status,
        tableName,
        txnId
      ];

      if (existingRow !== -1) {
        sheet.getRange(existingRow, 1, 1, rowData.length).setValues([rowData]);
      } else {
        if (isSettled && (b.is_settle_only || b.settle_pending || b.isSettlePending || b.target_bill_id)) {
          Logger.log("SETTLE_ROW_NOT_FOUND: " + billId + " (cleanId: " + cleanId + ")");
        }
        sheet.appendRow(rowData);
      }

      // Phase 2: Persist full data components into Schema v2 tabs
      persistV2Order(
        ss, orgId, billId, cleanId, tokenNo, tableName, cTable, 
        status, isSettled, totalAmount, subtotal, timeStr, 
        rawItems, paymentMode, customerName, customerPhone, 
        specialInstructions, txnId, clientRequestId, b, rev
      );

      // Phase 7: Decrement product stock and auto-86 if stock reaches 0
      if (isSettled && ss) {
        try {
          decrementInventoryForOrder(ss, orgId, rawItems);
        } catch(eStock) {
          console.warn("Stock decrement warning: " + eStock);
        }
      }

      return buildResult({
        row: existingRow !== -1 ? existingRow : lastRow + 1,
        cleared: isSettled
      });
    } catch (errSheet) {
      return buildResult({
        warning: errSheet.toString(),
        message: "Order cached in cloud memory, sheet write failed."
      });
    }
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleClearTable(data) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ success: false, error: "Server busy, lock acquisition timed out. Please retry." });
  }

  try {
    var orgId = String(data.org_id || data.org || data.outlet_id || "").trim();
    var table = data.table_name || data.table || data.table_number || "";
    var cTable = cleanTableId(table);

    if (orgId && cTable) {
      try {
        var props = PropertiesService.getScriptProperties();

        var cacheKey = "recent_orders_" + orgId.trim();
        var rawCached = props.getProperty(cacheKey);
        if (rawCached) {
          var cachedOrders = [];
          try { cachedOrders = JSON.parse(rawCached); } catch (e) { cachedOrders = []; }
          cachedOrders = cachedOrders.filter(function(co) {
            return cleanTableId(co.table || co.tableName) !== cTable;
          });
          props.setProperty(cacheKey, JSON.stringify(cachedOrders));
        }

        var waiterKey = "waiter_alerts_" + orgId.trim();
        var rawWaiters = props.getProperty(waiterKey);
        if (rawWaiters) {
          try {
            var wList = JSON.parse(rawWaiters);
            wList = wList.filter(function(w) { return cleanTableId(w.table || w.tableName) !== cTable; });
            props.setProperty(waiterKey, JSON.stringify(wList));
          } catch(e) {}
        }
        var sId = data.spreadsheet_id || data.spreadsheetId || getSheetIdForOrg(orgId);
        if (sId) {
          try {
            var ss = SpreadsheetApp.openById(sId);
            if (ss) {
              ensureV2Sheets(ss);
              var rev = getAndBumpRev(orgId);
              var sSheet = ss.getSheetByName("Sessions");
              if (sSheet && sSheet.getLastRow() > 1) {
                var sData = sSheet.getDataRange().getValues();
                for (var si = sData.length - 1; si >= 1; si--) {
                  var rowOut = String(sData[si][1] || "").trim();
                  var rowTables = String(sData[si][2] || "").trim().split(",").map(function(t) { return cleanTableId(t); });
                  var rowStatus = String(sData[si][3] || "").trim().toUpperCase();
                  if (rowOut === orgId && (rowStatus === "OPEN" || rowStatus === "BILL_REQUESTED") && rowTables.indexOf(cTable) !== -1) {
                    sSheet.getRange(si + 1, 4).setValue("CLOSED");
                    sSheet.getRange(si + 1, 12).setValue(new Date().toISOString());
                    sSheet.getRange(si + 1, 14).setValue(rev);
                    break;
                  }
                }
              }
              var tSheet = ss.getSheetByName("Tables");
              if (tSheet && tSheet.getLastRow() > 1) {
                var tData = tSheet.getDataRange().getValues();
                for (var ti = 1; ti < tData.length; ti++) {
                  if (cleanTableId(tData[ti][0]) === cTable) {
                    tSheet.getRange(ti + 1, 6, 1, 3).setValues([["VACANT", "", ""]]);
                    tSheet.getRange(ti + 1, 11).setValue(rev);
                    break;
                  }
                }
              }
            }
          } catch(eClearSs) {}
        }
      } catch(e) {}
    }

    // Task 0.5: Clearing table resets in-memory cache and marks table VACANT. It NEVER marks unpaid Sheet rows as PAID!

    return responseJson({ success: true, message: "Table " + table + " cache and session cleared successfully." });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handlePurgeTestOrders(data) {
  var orgId = data.org_id || data.org || data.outlet_id || "";
  if (!orgId) {
    return responseJson({ success: false, error: "org_id is required." });
  }
  var props = PropertiesService.getScriptProperties();
  var cacheKey = "recent_orders_" + orgId.trim();
  var rawCached = props.getProperty(cacheKey);
  var removed = 0;
  if (rawCached) {
    try {
      var list = JSON.parse(rawCached);
      var filtered = list.filter(function(o) {
        var id = String(o.id || o.orderId || "").toUpperCase();
        var name = String(o.customerName || "").toUpperCase();
        if (id.indexOf("TEST") !== -1 || name.indexOf("TEST") !== -1) {
          removed++;
          return false;
        }
        return true;
      });
      props.setProperty(cacheKey, JSON.stringify(filtered));
    } catch(e) {}
  }
  return responseJson({ success: true, removedCount: removed, message: "Purged " + removed + " test orders from cache." });
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. SYNC INVENTORY
// ─────────────────────────────────────────────────────────────────────────────
function handleSyncInventory(data) {
  let spreadsheetId = data.spreadsheet_id;
  const orgId = data.org_id || data.org || data.outlet_id;
  if ((!spreadsheetId || spreadsheetId.indexOf("sheet_") === 0) && orgId) {
    spreadsheetId = getSheetIdForOrg(orgId);
  }

  if (!spreadsheetId || spreadsheetId.indexOf("sheet_") === 0) {
    return responseJson({ success: true, message: "Placeholder sheet, inventory skipped." });
  }

  const ss = SpreadsheetApp.openById(spreadsheetId);
  const sheet = getOrCreateInventorySheet(ss);
  const sheetName = sheet.getName();

  const isProductsAndStock = sheetName.indexOf("Products") !== -1;
  const items = data.items || (data.product ? [data.product] : (data.item ? [data.item] : []));
  const replaceAll = data.replace_all === true || data.replaceAll === true;

  if (replaceAll) {
    const lastRow = sheet.getLastRow();
    if (lastRow > 1) {
      sheet.getRange(2, 1, lastRow - 1, sheet.getLastColumn() || (isProductsAndStock ? 7 : 9)).clearContent();
    }
    const rows = items.map(function(p) {
      if (isProductsAndStock) {
        return [
          p.id || "",
          p.name || "",
          p.category || "General",
          p.purchase_price || p.cost_price || 0,
          p.price || p.selling_price || 0,
          p.stock !== undefined ? p.stock : -1,
          p.unit || "pcs"
        ];
      } else {
        return [
          p.id || "",
          p.name || "",
          p.category || "General",
          p.barcode || "",
          p.price || p.selling_price || 0,
          p.purchase_price || p.cost_price || 0,
          p.stock !== undefined ? p.stock : -1,
          p.unit || "pcs",
          p.is_available !== false ? "TRUE" : "FALSE"
        ];
      }
    });
    if (rows.length > 0) {
      sheet.getRange(2, 1, rows.length, rows[0].length).setValues(rows);
    }
    return responseJson({ success: true, count: rows.length, mode: "REPLACE_ALL" });
  } else {
    // Upsert items by ID or Name
    const lastRow = sheet.getLastRow();
    let existingData = lastRow > 1 ? sheet.getRange(2, 1, lastRow - 1, 2).getValues() : [];
    let updatedCount = 0;
    let appendedCount = 0;

    items.forEach(function(p) {
      const pId = String(p.id || "").trim();
      const pName = String(p.name || "").trim().toLowerCase();
      let matchRow = -1;

      for (let i = 0; i < existingData.length; i++) {
        const rowId = String(existingData[i][0] || "").trim();
        const rowName = String(existingData[i][1] || "").trim().toLowerCase();
        if ((pId && rowId === pId) || (pName && rowName === pName)) {
          matchRow = i + 2;
          break;
        }
      }

      const rowValues = isProductsAndStock ? [
        p.id || "",
        p.name || "",
        p.category || "General",
        p.purchase_price || p.cost_price || 0,
        p.price || p.selling_price || 0,
        p.stock !== undefined ? p.stock : -1,
        p.unit || "pcs"
      ] : [
        p.id || "",
        p.name || "",
        p.category || "General",
        p.barcode || "",
        p.price || p.selling_price || 0,
        p.purchase_price || p.cost_price || 0,
        p.stock !== undefined ? p.stock : -1,
        p.unit || "pcs",
        p.is_available !== false ? "TRUE" : "FALSE"
      ];

      if (matchRow !== -1) {
        sheet.getRange(matchRow, 1, 1, rowValues.length).setValues([rowValues]);
        updatedCount++;
      } else {
        sheet.appendRow(rowValues);
        existingData.push([p.id || "", p.name || ""]);
        appendedCount++;
      }
    });

    return responseJson({ success: true, updated: updatedCount, appended: appendedCount });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. MASTER ANALYTICS
// ─────────────────────────────────────────────────────────────────────────────
function handleFetchAnalytics(data) {
  return responseJson({
    success: true,
    total_sales: 0,
    total_bills: 0
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 4B. WAITER CALLS & SERVICE REQUESTS (Real-Time Dine-In Table Assistance)
// ─────────────────────────────────────────────────────────────────────────────
function getOrCreateAlertsSheet(ss) {
  var sheet = ss.getSheetByName("Alerts") || ss.getSheetByName("ServiceRequests") || ss.getSheetByName("WaiterCalls");
  if (!sheet) {
    sheet = ss.insertSheet("Alerts");
    sheet.appendRow(["Alert ID", "Date & Time", "Table", "Request Type", "Guest Name", "Status"]);
    sheet.getRange("A1:F1").setFontWeight("bold").setBackground("#FEF08A");
    sheet.setFrozenRows(1);
  }
  return sheet;
}

function handleServiceRequest(data) {
  var orgId = data.org_id || data.org || data.outlet_id || "";
  var spreadsheetId = data.spreadsheet_id || getSheetIdForOrg(orgId);
  var payload = data.data || {};
  var alertId = "ALT_" + Date.now().toString().slice(-6);
  var table = payload.table || payload.table_name || "Table 1";
  var reqType = (payload.request_type || payload.type || "WAITER").toUpperCase();
  var guestName = payload.guest_name || payload.customer_name || "Guest";
  var timeStr = payload.timestamp || new Date().toISOString();

  // 1. Save in ScriptProperties for ultra-fast instant retrieval
  try {
    var props = PropertiesService.getScriptProperties();
    var key = "waiter_alerts_" + (orgId || "DEFAULT");
    var existingRaw = props.getProperty(key);
    var alerts = [];
    if (existingRaw) {
      try { alerts = JSON.parse(existingRaw); } catch(e) { alerts = []; }
    }
    alerts.push({
      id: alertId,
      table: table,
      tableName: table,
      requestType: reqType,
      guestName: guestName,
      timestamp: timeStr,
      status: "PENDING"
    });
    if (alerts.length > 20) alerts = alerts.slice(-20);
    props.setProperty(key, JSON.stringify(alerts));
  } catch(e) {}

  // 2. Also append to spreadsheet Alerts sheet
  try {
    if (spreadsheetId && spreadsheetId.indexOf("sheet_") !== 0) {
      var ss = SpreadsheetApp.openById(spreadsheetId);
      var sheet = getOrCreateAlertsSheet(ss);
      sheet.appendRow([alertId, timeStr, table, reqType, guestName, "PENDING"]);
    }
  } catch(e) {}

  return responseJson({ success: true, alert_id: alertId, message: "Alert dispatched to staff." });
}

function handleDismissServiceRequest(data) {
  var orgId = data.org_id || data.org || data.outlet_id || "";
  var spreadsheetId = data.spreadsheet_id || getSheetIdForOrg(orgId);
  var payload = data.data || data;
  var alertId = payload.alert_id || payload.id || "";
  var table = payload.table || "";

  // 1. Remove from ScriptProperties
  try {
    var props = PropertiesService.getScriptProperties();
    var key = "waiter_alerts_" + (orgId || "DEFAULT");
    var existingRaw = props.getProperty(key);
    if (existingRaw) {
      var alerts = JSON.parse(existingRaw);
      alerts = alerts.filter(function(a) {
        if (alertId && a.id === alertId) return false;
        if (table && a.table.toLowerCase() === table.toLowerCase()) return false;
        return true;
      });
      props.setProperty(key, JSON.stringify(alerts));
    }
  } catch(e) {}

  // 2. Mark RESOLVED in spreadsheet Alerts sheet
  try {
    if (spreadsheetId && spreadsheetId.indexOf("sheet_") !== 0) {
      var ss = SpreadsheetApp.openById(spreadsheetId);
      var sheet = ss.getSheetByName("Alerts") || ss.getSheetByName("ServiceRequests");
      if (sheet && sheet.getLastRow() > 1) {
        var dataRows = sheet.getDataRange().getValues();
        for (var r = 1; r < dataRows.length; r++) {
          var rowId = String(dataRows[r][0] || "").trim();
          var rowTable = String(dataRows[r][2] || "").trim();
          if ((alertId && rowId === alertId) || (table && rowTable.toLowerCase() === table.toLowerCase())) {
            sheet.getRange(r + 1, 6).setValue("RESOLVED");
          }
        }
      }
    }
  } catch(e) {}

  return responseJson({ success: true, message: "Alert dismissed." });
}

function getActiveWaiterAlerts(orgId, ss) {
  var alerts = [];
  var props = PropertiesService.getScriptProperties();
  var key = "waiter_alerts_" + (orgId || "DEFAULT");
  try {
    var raw = props.getProperty(key);
    if (raw) {
      alerts = JSON.parse(raw);
    }
  } catch(e) {}

  // Fallback: Check Alerts sheet if props empty and ss provided
  if (alerts.length === 0 && ss) {
    try {
      var sheet = ss.getSheetByName("Alerts") || ss.getSheetByName("ServiceRequests");
      if (sheet && sheet.getLastRow() > 1) {
        var rows = sheet.getDataRange().getValues();
        for (var r = 1; r < rows.length; r++) {
          var st = String(rows[r][5] || "").toUpperCase().trim();
          if (st === "PENDING") {
            alerts.push({
              id: String(rows[r][0] || ("ALT-" + r)),
              timestamp: String(rows[r][1] || ""),
              table: String(rows[r][2] || "Table 1"),
              tableName: String(rows[r][2] || "Table 1"),
              requestType: String(rows[r][3] || "WAITER"),
              guestName: String(rows[r][4] || "Guest"),
              status: "PENDING"
            });
          }
        }
      }
    } catch(e) {}
  }

  // Filter out expired alerts (> 10 mins) and alerts for settled tables
  var now = new Date().getTime();
  var maxAgeMs = 10 * 60 * 1000; // 10 minutes max age
  var validAlerts = alerts.filter(function(a) {
    var aTime = new Date(a.timestamp).getTime();
    if (!isNaN(aTime) && (now - aTime > maxAgeMs)) {
      return false; // Stale alert (> 10 mins)
    }
    // Check if table was settled after this alert was created
    if (orgId) {
      var cTable = cleanTableId(a.table || a.tableName);
      var settledRaw = props.getProperty("table_settled_" + orgId.trim() + "_" + cTable);
      if (settledRaw) {
        var settledTime = parseInt(settledRaw, 10);
        if (!isNaN(settledTime) && !isNaN(aTime) && aTime <= settledTime) {
          return false; // Table already settled
        }
      }
    }
    return true;
  });

  // If stale alerts were pruned, persist back to cache
  if (validAlerts.length !== alerts.length) {
    try {
      props.setProperty(key, JSON.stringify(validAlerts));
    } catch(e) {}
  }

  return validAlerts;
}

function handleSendOtpEmail(p) {
  var email = p.email;
  var clientName = p.client_name || "Valued Retailer";
  var otpCode = p.otp_code;

  if (!email || !otpCode) {
    return responseJson({ success: false, error: "Missing email or OTP code" });
  }

  var subject = "Your Smart POS Verification Code: " + otpCode;
  var bodyText = "Hello " + clientName + ",\n\nYour 6-digit verification code is: " + otpCode + "\n\nThis code will expire in 10 minutes. If you did not request this, please ignore this email.\n\nBest regards,\nSmart POS Team";

  var htmlBody = '<div style="font-family: Arial, sans-serif; max-width: 500px; margin: 0 auto; padding: 24px; border: 1px solid #e2e8f0; border-radius: 12px; background-color: #ffffff;">' +
    '<h2 style="color: #2563eb; margin-top: 0;">Smart POS Retail</h2>' +
    '<p style="color: #475569; font-size: 15px;">Hello <strong>' + clientName + '</strong>,</p>' +
    '<p style="color: #475569; font-size: 14px;">Thank you for registering your store. Please use the verification code below to verify your email address:</p>' +
    '<div style="text-align: center; margin: 24px 0;">' +
      '<span style="display: inline-block; font-size: 28px; font-weight: bold; letter-spacing: 6px; color: #1e293b; background: #f1f5f9; padding: 14px 28px; border-radius: 8px; border: 1px dashed #94a3b8;">' +
        otpCode +
      '</span>' +
    '</div>' +
    '<p style="color: #64748b; font-size: 13px;">This code is valid for <strong>10 minutes</strong>. Do not share this code with anyone.</p>' +
    '<hr style="border: none; border-top: 1px solid #e2e8f0; margin: 20px 0;" />' +
    '<p style="color: #94a3b8; font-size: 12px; margin-bottom: 0;">If you didn\'t request this verification code, please ignore this email.</p>' +
  '</div>';

  try {
    MailApp.sendEmail({
      to: email,
      subject: subject,
      body: bodyText,
      htmlBody: htmlBody,
      name: "Smart POS System"
    });
    return responseJson({ success: true, message: "Email sent successfully to " + email });
  } catch (err) {
    return responseJson({ success: false, error: "Failed to send email: " + err.toString() });
  }
}

function handleRecordPayment(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleRecordPayment." });
  }

  try {
    var clientRequestId = json.clientRequestId || json.client_request_id;
    var data = json.data || json.payment || json;
    var outletId = String(json.outletId || json.org_id || json.organizationId || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (clientRequestId && ss) {
      var cached = checkIdempotency(ss, clientRequestId);
      if (cached) {
        return responseJson(cached);
      }
    }

    var rev = getAndBumpRev(outletId);
    var paymentId = data.paymentId || data.id || ("PAY-" + Utilities.getUuid());
    var sessionId = data.sessionId || "";
    var invoiceNo = data.invoiceNo || "";
    var mode = String(data.mode || data.paymentMode || "CASH").toUpperCase();
    var amountP = parseInt(data.amountP || data.amountPaise || 0, 10);
    if (!amountP && data.amount) amountP = Math.round(Number(data.amount) * 100);
    var tipP = parseInt(data.tipP || data.tipPaise || 0, 10);
    if (!tipP && (data.tip || data.tip_amount || data.tipAmount)) tipP = Math.round(Number(data.tip_amount || data.tipAmount || data.tip) * 100);
    var refUtr = data.refUtr || data.ref_UTR || data.utr || data.ref || "";
    var gatewayId = data.gatewayId || "";
    var verified = data.verified !== false;
    var byStaffId = data.byStaffId || data.staffId || "";
    var atStr = data.at || new Date().toISOString();
    var voidedBy = data.voidedBy || "";
    var voidReason = data.voidReason || "";

    if (ss) {
      ensureV2Sheets(ss);
      var pSheet = ss.getSheetByName("Payments");
      if (pSheet) {
        pSheet.appendRow([
          paymentId, sessionId, invoiceNo, mode, amountP, tipP, refUtr,
          gatewayId, verified, byStaffId, atStr, voidedBy, voidReason, rev
        ]);
      }
    }

    var res = {
      ok: true,
      success: true,
      paymentId: paymentId,
      rev: rev,
      amountP: amountP
    };

    if (clientRequestId && ss) {
      recordIdempotency(ss, clientRequestId, "RECORD_PAYMENT", res);
    }
    return responseJson(res);
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err), error_code: "HANDLER_ERROR" });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleCloseDay(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleCloseDay." });
  }

  try {
    var clientRequestId = json.clientRequestId || json.client_request_id;
    var data = json.data || json.report || json;
    var outletId = String(json.outletId || json.org_id || json.organizationId || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (clientRequestId && ss) {
      var cached = checkIdempotency(ss, clientRequestId);
      if (cached) {
        return responseJson(cached);
      }
    }

    var rev = getAndBumpRev(outletId);
    var businessDate = data.businessDate || Utilities.formatDate(new Date(), Session.getScriptTimeZone() || "GMT+05:30", "yyyy-MM-dd");
    var grossP = parseInt(data.grossP || data.grossPaise || 0, 10);
    var discountP = parseInt(data.discountP || data.discountPaise || 0, 10);
    var taxP = parseInt(data.taxP || data.taxPaise || 0, 10);
    var scP = parseInt(data.serviceChargeP || data.serviceChargePaise || 0, 10);
    var netP = parseInt(data.netP || data.netPaise || 0, 10);
    var byModeStr = typeof data.byMode === "string" ? data.byMode : JSON.stringify(data.byMode || {});
    var covers = parseInt(data.covers || 0, 10);
    var orders = parseInt(data.orders || data.orderCount || 0, 10);
    var voids = parseInt(data.voids || data.voidCount || 0, 10);
    var refunds = parseInt(data.refunds || data.refundCount || 0, 10);
    var cashDeclaredP = parseInt(data.cashDeclaredP || data.cashDeclaredPaise || 0, 10);
    var varianceP = parseInt(data.varianceP || data.variancePaise || 0, 10);
    var closedBy = data.closedBy || "Staff";
    var closedAt = data.closedAt || new Date().toISOString();

    if (ss) {
      ensureV2Sheets(ss);
      var rSheet = ss.getSheetByName("Day End Reports");
      if (rSheet) {
        rSheet.appendRow([
          businessDate, outletId, grossP, discountP, taxP, scP,
          netP, byModeStr, covers, orders, voids, refunds,
          cashDeclaredP, varianceP, closedBy, closedAt
        ]);
      }
    }

    var res = {
      ok: true,
      success: true,
      businessDate: businessDate,
      rev: rev
    };

    if (clientRequestId && ss) {
      recordIdempotency(ss, clientRequestId, "CLOSE_DAY", res);
    }
    return responseJson(res);
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 6: Table Lifecycle, Occupancy, Reservations & Floor Operations
// ─────────────────────────────────────────────────────────────────────────────

function handleSetTableStatus(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleSetTableStatus." });
  }

  try {
    var clientRequestId = json.clientRequestId || json.client_request_id;
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || json.organizationId || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var tableId = String(data.tableId || data.table || data.tableNumber || "").trim();
    var newStatus = String(data.status || data.tableStatus || "VACANT").toUpperCase().trim();
    var force = data.force === true;
    var reason = String(data.reason || "").trim();

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (clientRequestId && ss) {
      var cached = checkIdempotency(ss, clientRequestId);
      if (cached) return responseJson(cached);
    }

    var cTable = cleanTableId(tableId);

    // Guard: Prevent vacating a table if it has an active unpaid order
    if (newStatus === "VACANT" && !force && outletId) {
      var props = PropertiesService.getScriptProperties();
      var rawCached = props.getProperty("recent_orders_" + outletId);
      if (rawCached) {
        try {
          var orders = JSON.parse(rawCached);
          var activeUnpaid = orders.find(function(o) {
            var oTable = cleanTableId(o.tableName || o.table || o.tableNumber || "");
            var oStat = String(o.status || o.paymentStatus || "").toUpperCase();
            return oTable === cTable && !isStatusSettled(oStat);
          });
          if (activeUnpaid) {
            return responseJson({
              ok: false,
              success: false,
              error: "Cannot mark table vacant: Active unpaid bill exists (" + (activeUnpaid.id || activeUnpaid.bill_id || "Bill") + "). Settle bill first or provide override reason.",
              activeBillId: activeUnpaid.id || activeUnpaid.bill_id
            });
          }
        } catch(e) {}
      }
    }

    var rev = getAndBumpRev(outletId);

    // Update in Tables tab
    if (ss) {
      ensureV2Sheets(ss);
      var tSheet = ss.getSheetByName("Tables");
      if (tSheet) {
        var tData = tSheet.getDataRange().getValues();
        var rowIdx = -1;
        for (var i = 1; i < tData.length; i++) {
          if (String(tData[i][0] || "").trim() === tableId || cleanTableId(tData[i][0]) === cTable) {
            rowIdx = i + 1;
            break;
          }
        }
        var occupiedAt = (newStatus === "OCCUPIED" || newStatus === "SEATED") ? (data.occupiedAt || new Date().toISOString()) : "";
        var cleaningUntil = newStatus === "CLEANING" ? (data.cleaningUntil || new Date(Date.now() + 15*60000).toISOString()) : "";
        var capacity = parseInt(data.capacity || 4, 10);
        var section = data.section || "Main Floor";

        if (rowIdx > 0) {
          tSheet.getRange(rowIdx, 6, 1, 6).setValues([[
            newStatus, data.activeSessionId || "", occupiedAt, cleaningUntil, data.qrToken || "", rev
          ]]);
        } else {
          tSheet.appendRow([
            tableId, outletId, "Table " + tableId, section, capacity,
            newStatus, data.activeSessionId || "", occupiedAt, cleaningUntil, data.qrToken || "", rev
          ]);
        }

        // Close active session in Sessions sheet if vacating
        if (newStatus === "VACANT") {
          var sSheet = ss.getSheetByName("Sessions");
          if (sSheet && sSheet.getLastRow() > 1) {
            var sData = sSheet.getDataRange().getValues();
            for (var si = sData.length - 1; si >= 1; si--) {
              var rowOut = String(sData[si][1] || "").trim();
              var rowTables = String(sData[si][2] || "").trim().split(",").map(function(t) { return cleanTableId(t); });
              var rowStatus = String(sData[si][3] || "").trim().toUpperCase();
              if (rowOut === outletId && (rowStatus === "OPEN" || rowStatus === "BILL_REQUESTED") && rowTables.indexOf(cTable) !== -1) {
                sSheet.getRange(si + 1, 4).setValue("CLOSED");
                sSheet.getRange(si + 1, 12).setValue(new Date().toISOString());
                sSheet.getRange(si + 1, 14).setValue(rev);
                break;
              }
            }
          }
        }
      }

      // Log force override in Audit tab with mandatory reason check
      if (force) {
        if (!reason || !String(reason).trim()) {
          return responseJson({ ok: false, success: false, error: "Manager override reason is mandatory to force vacate an active table." });
        }
        logAuditRecord(ss, outletId, data.staffId || "Manager", "FORCE_VACATE", "Table", tableId, "OCCUPIED", "VACANT", reason);
      }
    }

    var res = {
      ok: true,
      success: true,
      tableId: tableId,
      status: newStatus,
      rev: rev
    };

    if (clientRequestId && ss) {
      recordIdempotency(ss, clientRequestId, "SET_TABLE_STATUS", res);
    }
    return responseJson(res);
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleReserveTable(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleReserveTable." });
  }

  try {
    var clientRequestId = json.clientRequestId || json.client_request_id;
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || json.organizationId || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (clientRequestId && ss) {
      var cached = checkIdempotency(ss, clientRequestId);
      if (cached) return responseJson(cached);
    }

    var tableId = String(data.tableId || data.table || "").trim();
    var guestName = String(data.guestName || data.name || "Guest").trim();
    var guestPhone = String(data.guestPhone || data.phone || "").trim();
    var partySize = parseInt(data.partySize || data.guests || 2, 10);
    var startAtStr = data.startAt || new Date().toISOString();
    var durationMin = parseInt(data.durationMin || 90, 10);
    var startTime = new Date(startAtStr).getTime();
    var endTime = startTime + (durationMin * 60 * 1000);

    if (ss) {
      ensureV2Sheets(ss);
      var rSheet = ss.getSheetByName("Reservations");
      if (rSheet) {
        var rData = rSheet.getDataRange().getValues();
        for (var i = 1; i < rData.length; i++) {
          var rowTable = String(rData[i][2] || "").trim();
          var rowStatus = String(rData[i][8] || "").toUpperCase().trim();
          if (rowTable === tableId && (rowStatus === "BOOKED" || rowStatus === "CONFIRMED")) {
            var rowStart = new Date(rData[i][6]).getTime();
            var rowDur = parseInt(rData[i][7] || 90, 10);
            var rowEnd = rowStart + (rowDur * 60 * 1000);
            // Overlap check
            if (startTime < rowEnd && endTime > rowStart) {
              return responseJson({
                ok: false,
                success: false,
                error: "Reservation conflict: Table " + tableId + " already booked between " +
                       Utilities.formatDate(new Date(rowStart), "GMT+05:30", "HH:mm") + " - " +
                       Utilities.formatDate(new Date(rowEnd), "GMT+05:30", "HH:mm")
              });
            }
          }
        }
      }
    }

    var rev = getAndBumpRev(outletId);
    var resId = data.reservationId || ("RES-" + Utilities.getUuid());

    if (ss) {
      var rSheet = ss.getSheetByName("Reservations");
      if (rSheet) {
        rSheet.appendRow([
          resId, outletId, tableId, guestName, guestPhone, partySize,
          startAtStr, durationMin, "CONFIRMED", data.notes || "",
          data.createdBy || "Staff", new Date().toISOString(), "", rev
        ]);
      }
    }

    var res = {
      ok: true,
      success: true,
      reservationId: resId,
      tableId: tableId,
      startAt: startAtStr,
      rev: rev
    };

    if (clientRequestId && ss) {
      recordIdempotency(ss, clientRequestId, "RESERVE_TABLE", res);
    }
    return responseJson(res);
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleCancelReservation(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var resId = String(data.reservationId || data.id || "").trim();

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    var rev = getAndBumpRev(outletId);

    if (ss) {
      var rSheet = ss.getSheetByName("Reservations");
      if (rSheet) {
        var rData = rSheet.getDataRange().getValues();
        for (var i = 1; i < rData.length; i++) {
          if (String(rData[i][0] || "").trim() === resId) {
            rSheet.getRange(i + 1, 9).setValue("CANCELLED");
            rSheet.getRange(i + 1, 14).setValue(rev);
            break;
          }
        }
      }
    }

    return responseJson({ ok: true, success: true, reservationId: resId, rev: rev });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleSeatReservation(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var resId = String(data.reservationId || data.id || "").trim();
    var tableId = String(data.tableId || "").trim();

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    var rev = getAndBumpRev(outletId);

    if (ss) {
      var rSheet = ss.getSheetByName("Reservations");
      if (rSheet) {
        var rData = rSheet.getDataRange().getValues();
        for (var i = 1; i < rData.length; i++) {
          if (String(rData[i][0] || "").trim() === resId) {
            rSheet.getRange(i + 1, 9).setValue("SEATED");
            rSheet.getRange(i + 1, 14).setValue(rev);
            break;
          }
        }
      }

      // Mark Table as Occupied
      var tSheet = ss.getSheetByName("Tables");
      if (tSheet) {
        var tData = tSheet.getDataRange().getValues();
        for (var j = 1; j < tData.length; j++) {
          if (String(tData[j][0] || "").trim() === tableId || cleanTableId(tData[j][0]) === cleanTableId(tableId)) {
            tSheet.getRange(j + 1, 6).setValue("OCCUPIED");
            tSheet.getRange(j + 1, 8).setValue(new Date().toISOString());
            tSheet.getRange(j + 1, 11).setValue(rev);
            break;
          }
        }
      }
    }

    return responseJson({ ok: true, success: true, reservationId: resId, tableId: tableId, rev: rev });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleMoveTable(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleMoveTable." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var fromTable = String(data.fromTableId || data.fromTable || "").trim();
    var toTable = String(data.toTableId || data.toTable || "").trim();

    var cFrom = cleanTableId(fromTable);
    var cTo = cleanTableId(toTable);

    var rev = getAndBumpRev(outletId);

    // Reassign active orders in memory cache
    var props = PropertiesService.getScriptProperties();
    var cacheKey = "recent_orders_" + outletId;
    var rawCached = props.getProperty(cacheKey);
    if (rawCached) {
      try {
        var orders = JSON.parse(rawCached);
        orders.forEach(function(o) {
          if (cleanTableId(o.tableName || o.table || o.tableNumber) === cFrom) {
            o.tableName = "Table " + toTable;
            o.table = toTable;
            o.tableNumber = toTable;
            o.tableId = toTable;
          }
        });
        props.setProperty(cacheKey, JSON.stringify(orders));
      } catch(e) {}
    }

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (ss) {
      ensureV2Sheets(ss);
      // Update Tables tab: fromTable -> VACANT/CLEANING, toTable -> OCCUPIED
      var tSheet = ss.getSheetByName("Tables");
      if (tSheet) {
        var tData = tSheet.getDataRange().getValues();
        for (var i = 1; i < tData.length; i++) {
          var tId = cleanTableId(tData[i][0]);
          if (tId === cFrom) {
            tSheet.getRange(i + 1, 6).setValue("CLEANING");
            tSheet.getRange(i + 1, 11).setValue(rev);
          } else if (tId === cTo) {
            tSheet.getRange(i + 1, 6).setValue("OCCUPIED");
            tSheet.getRange(i + 1, 8).setValue(new Date().toISOString());
            tSheet.getRange(i + 1, 11).setValue(rev);
          }
        }
      }

      // Update Bills sheet
      var bSheet = getOrCreateBillsSheet(ss);
      if (bSheet) {
        var bData = bSheet.getDataRange().getValues();
        if (bData && bData.length > 1) {
          var bCols = resolveBillColumns(bData[0]);
          var bTableIdx = bCols.tableIdx;
          var bStatusIdx = bCols.statusIdx;
          for (var bi = 1; bi < bData.length; bi++) {
            var bStatus = bStatusIdx !== -1 ? String(bData[bi][bStatusIdx] || "").trim() : "";
            if (!isStatusSettled(bStatus)) {
              var curTable = cleanTableId(bData[bi][bTableIdx]);
              if (curTable === cFrom) {
                bSheet.getRange(bi + 1, bTableIdx + 1).setValue("Table " + toTable);
              }
            }
          }
        }
      }

      // Update Orders tab
      var ordersSheet = ss.getSheetByName("Orders");
      if (ordersSheet && ordersSheet.getLastRow() >= 2) {
        var oData = ordersSheet.getDataRange().getValues();
        for (var oi = 1; oi < oData.length; oi++) {
          var oStatus = String(oData[oi][9] || "").trim();
          if (!isStatusSettled(oStatus)) {
            var oTable = cleanTableId(oData[oi][3]);
            if (oTable === cFrom) {
              ordersSheet.getRange(oi + 1, 4).setValue("Table " + toTable);
            }
          }
        }
      }
    }

    return responseJson({ ok: true, success: true, fromTable: fromTable, toTable: toTable, rev: rev });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleMergeTables(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleMergeTables." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var sourceTables = data.sourceTableIds || data.sources || [];
    var targetTable = String(data.targetTableId || data.target || "").trim();

    var cTarget = cleanTableId(targetTable);
    var cSources = sourceTables.map(function(s) { return cleanTableId(s); });

    var rev = getAndBumpRev(outletId);

    // Merge active orders in memory cache to target table
    var props = PropertiesService.getScriptProperties();
    var cacheKey = "recent_orders_" + outletId;
    var rawCached = props.getProperty(cacheKey);
    if (rawCached) {
      try {
        var orders = JSON.parse(rawCached);
        orders.forEach(function(o) {
          var oTable = cleanTableId(o.tableName || o.table || o.tableNumber);
          if (cSources.indexOf(oTable) !== -1) {
            o.tableName = "Table " + targetTable;
            o.table = targetTable;
            o.tableNumber = targetTable;
            o.tableId = targetTable;
          }
        });
        props.setProperty(cacheKey, JSON.stringify(orders));
      } catch(e) {}
    }

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (ss) {
      ensureV2Sheets(ss);
      var tSheet = ss.getSheetByName("Tables");
      if (tSheet) {
        var tData = tSheet.getDataRange().getValues();
        for (var i = 1; i < tData.length; i++) {
          var tId = cleanTableId(tData[i][0]);
          if (cSources.indexOf(tId) !== -1) {
            tSheet.getRange(i + 1, 6).setValue("VACANT");
            tSheet.getRange(i + 1, 11).setValue(rev);
          } else if (tId === cTarget) {
            tSheet.getRange(i + 1, 6).setValue("OCCUPIED");
            tSheet.getRange(i + 1, 11).setValue(rev);
          }
        }
      }

      // Update Bills sheet
      var bSheet = getOrCreateBillsSheet(ss);
      if (bSheet) {
        var bData = bSheet.getDataRange().getValues();
        if (bData && bData.length > 1) {
          var bCols = resolveBillColumns(bData[0]);
          var bTableIdx = bCols.tableIdx;
          var bStatusIdx = bCols.statusIdx;
          for (var bi = 1; bi < bData.length; bi++) {
            var bStatus = bStatusIdx !== -1 ? String(bData[bi][bStatusIdx] || "").trim() : "";
            if (!isStatusSettled(bStatus)) {
              var curTable = cleanTableId(bData[bi][bTableIdx]);
              if (cSources.indexOf(curTable) !== -1) {
                bSheet.getRange(bi + 1, bTableIdx + 1).setValue("Table " + targetTable);
              }
            }
          }
        }
      }

      // Update Orders tab
      var ordersSheet = ss.getSheetByName("Orders");
      if (ordersSheet && ordersSheet.getLastRow() >= 2) {
        var oData = ordersSheet.getDataRange().getValues();
        for (var oi = 1; oi < oData.length; oi++) {
          var oStatus = String(oData[oi][9] || "").trim();
          if (!isStatusSettled(oStatus)) {
            var oTable = cleanTableId(oData[oi][3]);
            if (cSources.indexOf(oTable) !== -1) {
              ordersSheet.getRange(oi + 1, 4).setValue("Table " + targetTable);
            }
          }
        }
      }
    }

    return responseJson({ ok: true, success: true, sourceTables: sourceTables, targetTable: targetTable, rev: rev });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function responseJson(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}


// ─────────────────────────────────────────────────────────────────────────────
// Phase 7: Catalog & Inventory Handlers (§7.1, §7.2)
// ─────────────────────────────────────────────────────────────────────────────

function decrementInventoryForOrder(ss, outletId, rawItems) {
  if (!ss || !rawItems) return;
  var items = [];
  if (typeof rawItems === "string") {
    try { items = JSON.parse(rawItems); } catch(e) { return; }
  } else if (Array.isArray(rawItems)) {
    items = rawItems;
  } else {
    return;
  }
  if (!items || items.length === 0) return;

  var sheet = getInventorySheet(ss);
  if (!sheet) return;

  var data = sheet.getDataRange().getValues();
  if (data.length <= 1) return;

  var headers = data[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
  var idCol = -1, nameCol = -1, stockCol = -1, availCol = -1;
  for (var c = 0; c < headers.length; c++) {
    var h = headers[c];
    if (h.indexOf("id") !== -1 && idCol === -1) idCol = c;
    if ((h.indexOf("name") !== -1 || h.indexOf("dish") !== -1) && nameCol === -1) nameCol = c;
    if (h.indexOf("stock") !== -1 || h.indexOf("qty") !== -1 || h.indexOf("quantity") !== -1) stockCol = c;
    if (h.indexOf("avail") !== -1 || h.indexOf("status") !== -1) availCol = c;
  }
  if (idCol === -1) idCol = 0;
  if (nameCol === -1) nameCol = 1;
  if (stockCol === -1) return; // No stock column found

  if (availCol === -1) {
    availCol = headers.length;
    sheet.getRange(1, availCol + 1).setValue("Available").setFontWeight("bold");
  }

  var updated = false;
  items.forEach(function(item) {
    var orderItemId = String(item.productId || item.id || "").trim();
    var orderItemName = String(item.name || "").trim().toLowerCase();
    var qty = parseInt(item.qty || item.quantity || 1, 10);
    if (qty <= 0) return;

    for (var r = 1; r < data.length; r++) {
      var rowId = String(data[r][idCol] || "").trim();
      var rowName = String(data[r][nameCol] || "").trim().toLowerCase();

      if ((orderItemId && rowId === orderItemId) || (orderItemName && rowName === orderItemName)) {
        var currentStock = data[r][stockCol];
        // -1 represents infinite stock (never decrement)
        if (currentStock !== "" && currentStock !== null && currentStock !== undefined && Number(currentStock) >= 0) {
          var numStock = Number(currentStock);
          var newStock = Math.max(0, numStock - qty);
          data[r][stockCol] = newStock;
          sheet.getRange(r + 1, stockCol + 1).setValue(newStock);
          updated = true;

          // Auto-86: Mark unavailable if stock reaches 0
          if (newStock === 0) {
            data[r][availCol] = "FALSE";
            sheet.getRange(r + 1, availCol + 1).setValue("FALSE");
          }
        }
        break;
      }
    }
  });

  if (updated && outletId) {
    getAndBumpRev(outletId);
  }
}

function handleToggleItemAvailability(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleToggleItemAvailability." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || json.organizationId || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var itemId = String(data.itemId || data.id || "").trim();
    var itemName = String(data.name || data.itemName || "").trim().toLowerCase();
    var isAvailable = data.isAvailable !== false && data.is_available !== false && data.available !== false;

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (!ss) {
      return responseJson({ ok: false, success: false, error: "Spreadsheet not found or not connected." });
    }

    var sheet = getInventorySheet(ss);
    if (!sheet) {
      return responseJson({ ok: false, success: false, error: "Inventory sheet not found." });
    }

    var values = sheet.getDataRange().getValues();
    if (values.length <= 1) {
      return responseJson({ ok: false, success: false, error: "Inventory is empty." });
    }

    var headers = values[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
    var idCol = -1, nameCol = -1, availCol = -1;
    for (var c = 0; c < headers.length; c++) {
      var h = headers[c];
      if (h.indexOf("id") !== -1 && idCol === -1) idCol = c;
      if ((h.indexOf("name") !== -1 || h.indexOf("dish") !== -1) && nameCol === -1) nameCol = c;
      if (h.indexOf("avail") !== -1 || h.indexOf("status") !== -1) availCol = c;
    }
    if (idCol === -1) idCol = 0;
    if (nameCol === -1) nameCol = 1;
    if (availCol === -1) {
      availCol = headers.length;
      sheet.getRange(1, availCol + 1).setValue("Available").setFontWeight("bold");
    }

    var matchRow = -1;
    for (var r = 1; r < values.length; r++) {
      var rowId = String(values[r][idCol] || "").trim();
      var rowName = String(values[r][nameCol] || "").trim().toLowerCase();
      if ((itemId && rowId === itemId) || (itemName && rowName === itemName)) {
        matchRow = r + 1;
        break;
      }
    }

    if (matchRow === -1) {
      return responseJson({ ok: false, success: false, error: "Item not found in inventory: " + (itemId || itemName) });
    }

    sheet.getRange(matchRow, availCol + 1).setValue(isAvailable ? "TRUE" : "FALSE");
    var rev = getAndBumpRev(outletId);

    return responseJson({
      ok: true,
      success: true,
      itemId: itemId,
      isAvailable: isAvailable,
      rev: rev
    });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleDecrementInventory(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleDecrementInventory." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var rawItems = data.items || data.orderItems || [];

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }

    if (ss) {
      decrementInventoryForOrder(ss, outletId, rawItems);
    }
    return responseJson({ ok: true, success: true });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 8: Audit Logging & Order Voiding Engine (§8.1, §8.2)
// ─────────────────────────────────────────────────────────────────────────────

function logAuditRecord(ss, outletId, staffId, action, entity, entityId, beforeVal, afterVal, reason) {
  if (!ss) return;
  try {
    ensureV2Sheets(ss);
    var aSheet = ss.getSheetByName("Audit");
    if (!aSheet) {
      aSheet = ss.insertSheet("Audit");
      aSheet.appendRow(V2_SCHEMAS["Audit"]);
      aSheet.getRange(1, 1, 1, V2_SCHEMAS["Audit"].length).setFontWeight("bold");
      aSheet.setFrozenRows(1);
    }
    aSheet.appendRow([
      new Date().toISOString(),
      String(outletId || "").trim(),
      String(staffId || "Staff").trim(),
      String(action || "").trim(),
      String(entity || "").trim(),
      String(entityId || "").trim(),
      String(beforeVal || "").trim(),
      String(afterVal || "").trim(),
      String(reason || "").trim()
    ]);
  } catch (eAudit) {
    console.warn("Failed to log audit record: " + eAudit);
  }
}

function handleLogAudit(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(15000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleLogAudit." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }
    if (!ss) {
      return responseJson({ ok: false, success: false, error: "Spreadsheet not found." });
    }

    var staffId = data.staffId || data.staff_id || data.staffName || "Staff";
    var action = data.auditAction || data.actionName || data.action || "GENERIC_AUDIT";
    var entity = data.entity || "System";
    var entityId = data.entityId || data.id || "";
    var beforeVal = data.before || "";
    var afterVal = data.after || "";
    var reason = data.reason || "";

    if (!reason || !String(reason).trim()) {
      return responseJson({ ok: false, success: false, error: "Audit reason is required." });
    }

    logAuditRecord(ss, outletId, staffId, action, entity, entityId, beforeVal, afterVal, reason);
    var rev = getAndBumpRev(outletId);
    return responseJson({ ok: true, success: true, rev: rev });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleVoidOrder(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleVoidOrder." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }
    if (!ss) {
      return responseJson({ ok: false, success: false, error: "Spreadsheet not found." });
    }

    var orderId = cleanOrderId(data.orderId || data.order_id || data.billId || data.id);
    var reason = String(data.reason || data.voidReason || "").trim();
    var authorizedBy = String(data.authorizedBy || data.staffName || data.staffId || "Manager").trim();
    var tableId = cleanTableId(data.tableId || data.table || data.tableName || "");

    if (!orderId) {
      return responseJson({ ok: false, success: false, error: "Order ID is required to void an order." });
    }
    if (!reason) {
      return responseJson({ ok: false, success: false, error: "A valid cancellation/void reason is mandatory for audit compliance." });
    }

    ensureV2Sheets(ss);
    var rev = getAndBumpRev(outletId);
    var oldStatus = "PENDING";
    var orderFound = false;
    var orderItemsToRestock = [];
    var sessionId = "";

    // 1. Update in Orders tab
    var oSheet = ss.getSheetByName("Orders");
    if (oSheet && oSheet.getLastRow() >= 2) {
      var oData = oSheet.getDataRange().getValues();
      for (var i = 1; i < oData.length; i++) {
        var rowId = cleanOrderId(oData[i][0]);
        if (rowId === orderId) {
          orderFound = true;
          oldStatus = String(oData[i][9] || "PENDING").trim().toUpperCase();
          sessionId = String(oData[i][1] || "").trim();
          var oTable = cleanTableId(oData[i][3]);
          if (oTable && !tableId) tableId = oTable;

          // Column 10 (kitchenStatus) -> CANCELLED
          oSheet.getRange(i + 1, 10).setValue("CANCELLED");
          // Column 27 (rev)
          oSheet.getRange(i + 1, 27).setValue(rev);
          break;
        }
      }
    }

    // Also update legacy Dining Bills sheet if present
    var legacySheet = ss.getSheetByName("Dining Bills") || ss.getSheetByName("Bills");
    if (legacySheet && legacySheet.getLastRow() >= 2) {
      var lData = legacySheet.getDataRange().getValues();
      for (var li = 1; li < lData.length; li++) {
        var lId = cleanOrderId(lData[li][0]);
        if (lId === orderId) {
          var lCols = resolveBillColumns(lData[0]);
          var statusCol = lCols.statusIdx + 1;
          legacySheet.getRange(li + 1, statusCol).setValue("CANCELLED");
          break;
        }
      }
    }

    // 2. Mark OrderItems as voided
    var oiSheet = ss.getSheetByName("OrderItems");
    if (oiSheet && oiSheet.getLastRow() >= 2) {
      var oiData = oiSheet.getDataRange().getValues();
      for (var j = 1; j < oiData.length; j++) {
        var oiOrdId = cleanOrderId(oiData[j][1]);
        if (oiOrdId === orderId) {
          var pId = String(oiData[j][3] || "").trim();
          var pName = String(oiData[j][4] || "").trim();
          var pQty = parseInt(oiData[j][5], 10) || 0;
          if (pQty > 0) {
            orderItemsToRestock.push({ id: pId, name: pName, qty: pQty });
          }
          // kitchenStatus (col 12) -> CANCELLED
          oiSheet.getRange(j + 1, 12).setValue("CANCELLED");
          // voidedQty (col 13)
          oiSheet.getRange(j + 1, 13).setValue(oiData[j][5]);
          // voidReason (col 14)
          oiSheet.getRange(j + 1, 14).setValue(reason);
          // voidedBy (col 15)
          oiSheet.getRange(j + 1, 15).setValue(authorizedBy);
          // rev (col 16)
          oiSheet.getRange(j + 1, 16).setValue(rev);
        }
      }
    }

    // 3. If order was paid/settled, restock finite inventory in Products & Stock
    if (oldStatus === "PAID" || oldStatus === "SETTLED" || oldStatus === "COMPLETED") {
      var pSheet = getInventorySheet(ss);
      if (pSheet && pSheet.getLastRow() >= 2 && orderItemsToRestock.length > 0) {
        var pData = pSheet.getDataRange().getValues();
        var pHeaders = pData[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
        var idColIdx = pHeaders.indexOf("product id");
        var nameColIdx = pHeaders.indexOf("product name");
        var stockColIdx = pHeaders.indexOf("stock quantity");
        var isAvailColIdx = -1;
        for (var c = 0; c < pHeaders.length; c++) {
          if (pHeaders[c].indexOf("avail") !== -1) { isAvailColIdx = c; break; }
        }

        if (stockColIdx !== -1) {
          for (var ri = 0; ri < orderItemsToRestock.length; ri++) {
            var item = orderItemsToRestock[ri];
            for (var row = 1; row < pData.length; row++) {
              var rId = idColIdx !== -1 ? String(pData[row][idColIdx] || "").trim() : "";
              var rName = nameColIdx !== -1 ? String(pData[row][nameColIdx] || "").trim().toLowerCase() : "";
              if ((item.id && rId && rId === item.id) || (item.name && rName && rName === item.name.toLowerCase())) {
                var curStock = parseInt(pData[row][stockColIdx], 10);
                if (!isNaN(curStock) && curStock >= 0) {
                  var newStock = curStock + item.qty;
                  pSheet.getRange(row + 1, stockColIdx + 1).setValue(newStock);
                  if (newStock > 0 && isAvailColIdx !== -1) {
                    pSheet.getRange(row + 1, isAvailColIdx + 1).setValue("TRUE");
                  }
                }
                break;
              }
            }
          }
        }
      }
    }

    // 4. Update Table state if table was Dine-In
    if (tableId) {
      var tSheet = ss.getSheetByName("Tables");
      if (tSheet && tSheet.getLastRow() >= 2) {
        var tData = tSheet.getDataRange().getValues();
        for (var ti = 1; ti < tData.length; ti++) {
          var tClean = cleanTableId(tData[ti][0]);
          if (tClean === tableId) {
            // tableStatus (col 6) -> VACANT
            tSheet.getRange(ti + 1, 6).setValue("VACANT");
            // activeSessionId (col 7) -> ""
            tSheet.getRange(ti + 1, 7).setValue("");
            // rev (col 11)
            tSheet.getRange(ti + 1, 11).setValue(rev);
            break;
          }
        }
      }
    }

    // 5. Close Session in Sessions tab if applicable
    if (sessionId) {
      var sSheet = ss.getSheetByName("Sessions");
      if (sSheet && sSheet.getLastRow() >= 2) {
        var sData = sSheet.getDataRange().getValues();
        for (var si = 1; si < sData.length; si++) {
          if (String(sData[si][0] || "").trim() === sessionId) {
            // sessionStatus (col 4) -> CANCELLED
            sSheet.getRange(si + 1, 4).setValue("CANCELLED");
            sSheet.getRange(si + 1, 12).setValue(new Date().toISOString());
            sSheet.getRange(si + 1, 14).setValue(rev);
            break;
          }
        }
      }
    }

    // 6. Log to Audit tab
    logAuditRecord(ss, outletId, authorizedBy, "VOID_ORDER", "Order", orderId, oldStatus, "CANCELLED", reason);

    return responseJson({
      ok: true,
      success: true,
      orderId: orderId,
      status: "CANCELLED",
      voidReason: reason,
      voidedBy: authorizedBy,
      tableId: tableId,
      rev: rev
    });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleVoidLine(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleVoidLine." });
  }

  try {
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }
    if (!ss) {
      return responseJson({ ok: false, success: false, error: "Spreadsheet not found." });
    }

    var orderId = cleanOrderId(data.orderId || data.order_id || data.billId || data.id);
    var lineId = String(data.lineId || data.line_id || "").trim();
    var productId = String(data.productId || data.product_id || "").trim();
    var voidQty = parseFloat(data.voidQty || data.voidedQty || data.qty || "1") || 1.0;
    var reason = String(data.reason || data.voidReason || "").trim();
    var authorizedBy = String(data.authorizedBy || data.staffName || data.staffId || "Manager").trim();

    if (!orderId) {
      return responseJson({ ok: false, success: false, error: "Order ID is required to void an item line." });
    }
    if (!reason) {
      return responseJson({ ok: false, success: false, error: "A valid cancellation/void reason is mandatory for audit compliance." });
    }

    ensureV2Sheets(ss);
    var rev = getAndBumpRev(outletId);
    var lineFound = false;

    var oiSheet = ss.getSheetByName("OrderItems");
    if (oiSheet && oiSheet.getLastRow() >= 2) {
      var oiData = oiSheet.getDataRange().getValues();
      for (var j = 1; j < oiData.length; j++) {
        var rowOrderId = cleanOrderId(oiData[j][1]);
        var rowLineId = String(oiData[j][0] || "").trim();
        var rowProdId = String(oiData[j][3] || "").trim();

        if (rowOrderId === orderId && (rowLineId === lineId || (productId && rowProdId === productId))) {
          lineFound = true;
          oiSheet.getRange(j + 1, 12).setValue("VOIDED");
          oiSheet.getRange(j + 1, 13).setValue(voidQty);
          oiSheet.getRange(j + 1, 14).setValue(reason);
          oiSheet.getRange(j + 1, 15).setValue(authorizedBy);
          oiSheet.getRange(j + 1, 16).setValue(rev);
          break;
        }
      }
    }

    logAuditRecord(ss, outletId, authorizedBy, "VOID_LINE", "OrderItem", lineId || (orderId + ":" + productId), "ACTIVE", "VOIDED (" + voidQty + ")", reason);

    return responseJson({
      ok: true,
      success: true,
      orderId: orderId,
      lineId: lineId,
      rev: rev,
      message: "Item line voided successfully."
    });
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}

function handleRefundPayment(json) {
  var lock = LockService.getScriptLock();
  try {
    lock.waitLock(20000);
  } catch (eLock) {
    return responseJson({ ok: false, success: false, error: "Server busy: lock timeout in handleRefundPayment." });
  }

  try {
    var clientRequestId = json.clientRequestId || json.client_request_id;
    var data = json.data || json;
    var outletId = String(json.outletId || json.org_id || json.organizationId || data.outletId || "").trim();
    var sId = json.spreadsheet_id || json.spreadsheetId || getSheetIdForOrg(outletId);
    var originalPaymentId = String(data.paymentId || data.originalPaymentId || "").trim();
    var billId = String(data.billId || data.orderId || "").trim();
    var cleanId = cleanOrderId(billId);
    var reason = String(data.reason || data.refundReason || "").trim();
    var authorizedBy = String(data.authorizedBy || data.staffName || data.staffId || "Manager").trim();
    var refundAmount = parseFloat(data.amount || data.refundAmount || 0);

    if (!reason) {
      return responseJson({ ok: false, success: false, error: "A valid refund reason is mandatory for audit compliance." });
    }

    var ss = null;
    if (sId) {
      try { ss = SpreadsheetApp.openById(sId); } catch(e) {}
    }
    if (!ss) {
      return responseJson({ ok: false, success: false, error: "Spreadsheet not found." });
    }

    ensureV2Sheets(ss);
    var rev = getAndBumpRev(outletId);

    // 1. Allocate Credit Note number from INVOICE counter
    var cnSeq = allocateCounter(ss, outletId, "INVOICE");
    var nowD = new Date();
    var ymd = Utilities.formatDate(nowD, Session.getScriptTimeZone() || "GMT+05:30", "yyyyMMdd");
    var creditNoteNo = "CN-" + ymd + "-" + ("0000" + cnSeq).slice(-4);

    var refundAmountP = Math.round(refundAmount * 100);
    var origMode = "CASH";
    var sessionId = "";

    // 2. Find original payment row if paymentId provided, or by billId
    var pSheet = ss.getSheetByName("Payments");
    if (pSheet && pSheet.getLastRow() >= 2) {
      var pData = pSheet.getDataRange().getValues();
      for (var pi = 1; pi < pData.length; pi++) {
        var rowPayId = String(pData[pi][0] || "").trim();
        var rowBillId = String(pData[pi][2] || "").trim();
        if ((originalPaymentId && rowPayId === originalPaymentId) || (cleanId && cleanOrderId(rowBillId) === cleanId)) {
          sessionId = String(pData[pi][1] || "").trim();
          origMode = String(pData[pi][3] || "CASH").trim();
          if (!refundAmountP) {
            refundAmountP = parseInt(pData[pi][4] || 0, 10);
          }
          break;
        }
      }
    }

    if (refundAmountP > 0) refundAmountP = -refundAmountP;

    // Append negative payment row in Payments tab
    if (pSheet) {
      var refPayId = "REF-" + Utilities.getUuid();
      var atStr = nowD.toISOString();
      pSheet.appendRow([
        refPayId,
        sessionId,
        creditNoteNo,
        origMode,
        refundAmountP,
        0,
        originalPaymentId,
        "",
        true,
        authorizedBy,
        atStr,
        authorizedBy,
        reason,
        rev
      ]);
    }

    // 3. Update Orders tab status to REFUNDED
    var oSheet = ss.getSheetByName("Orders");
    if (oSheet && oSheet.getLastRow() >= 2 && cleanId) {
      var oData = oSheet.getDataRange().getValues();
      for (var oi = 1; oi < oData.length; oi++) {
        if (cleanOrderId(oData[oi][0]) === cleanId) {
          oSheet.getRange(oi + 1, 10).setValue("REFUNDED");
          oSheet.getRange(oi + 1, 27).setValue(rev);
          break;
        }
      }
    }

    // 4. Update legacy Bills sheet if present
    var bSheet = getOrCreateBillsSheet(ss);
    if (bSheet && bSheet.getLastRow() >= 2 && cleanId) {
      var bData = bSheet.getDataRange().getValues();
      var cols = resolveBillColumns(bData[0].map(function(h) { return String(h || "").trim().toLowerCase(); }));
      for (var bi = 1; bi < bData.length; bi++) {
        if (cleanOrderId(bData[bi][cols.idIdx]) === cleanId) {
          bSheet.getRange(bi + 1, cols.statusIdx + 1).setValue("REFUNDED");
          break;
        }
      }
    }

    // 5. Log audit
    logAuditRecord(ss, outletId, authorizedBy, "REFUND_PAYMENT", "Payment", originalPaymentId || billId, "PAID", "REFUNDED", reason + " (" + creditNoteNo + ")");

    var res = {
      ok: true,
      success: true,
      creditNoteNo: creditNoteNo,
      refundAmountP: refundAmountP,
      rev: rev
    };

    if (clientRequestId && ss) {
      recordIdempotency(ss, clientRequestId, "REFUND_PAYMENT", res);
    }
    return responseJson(res);
  } catch (err) {
    return responseJson({ ok: false, success: false, error: String(err) });
  } finally {
    try { lock.releaseLock(); } catch(e) {}
  }
}
