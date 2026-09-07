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
    
    // Security verification: allow customer SAVE_BILL, SERVICE_REQUEST, CALL_WAITER without exposing master secret
    var isPublicAction = (
      json.action === "SAVE_BILL" || 
      json.action === "UPDATE_ORDER_STATUS" || 
      json.action === "UPDATE_STATUS" || 
      json.action === "SERVICE_REQUEST" || 
      json.action === "CALL_WAITER" || 
      json.action === "DISMISS_SERVICE_REQUEST" || 
      json.action === "RESOLVE_WAITER_CALL" || 
      json.action === "SEND_OTP_EMAIL" || 
      json.action === "CLEAR_TABLE" || 
      json.action === "RESET_TABLE" ||
      json.action === "PURGE_TEST_ORDERS"
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
  if (!t) return "1";
  var s = String(t).toLowerCase().trim();
  s = s.replace(/^table[\s_-]*/, "").replace(/[^a-z0-9]/g, "");
  return s || "1";
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
  
  // Verify & fix header row if it has old 9-column format or "Status" at column 8
  try {
    var headerRange = sheet.getRange(1, 1, 1, Math.max(sheet.getLastColumn(), 12));
    var headers = headerRange.getValues()[0].map(function(h) { return String(h || "").trim(); });
    if (headers.length < 12 || headers[8] === "Status" || headers[8] === "status") {
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

function doGet(e) {
  var params = (e && e.parameter) ? e.parameter : {};
  var orgId = params.org || params.org_id || "";
  var sheetId = params.sheet || params.spreadsheet_id || "";

  // Resolve private Google Sheet ID from server-side tenant registry if not explicitly passed
  if (!sheetId && orgId) {
    sheetId = getSheetIdForOrg(orgId);
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
      var tableSettledTime = 0;
      var settledIds = [];
      try {
        if (cReqTable) {
          var tableSettledKey = "table_settled_" + orgId.trim() + "_" + cReqTable;
          tableSettledTime = parseInt(props.getProperty(tableSettledKey) || "0", 10);
        }
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
              var coTime = co.timestamp ? new Date(co.timestamp).getTime() : 0;
              if (tableSettledTime > 0 && coTime > 0 && coTime <= tableSettledTime) {
                continue; // Placed before table settlement -> past session!
              }
              if (coTime > 0 && (nowTime - coTime) > 4 * 60 * 60 * 1000) {
                continue; // Older than 4 hours -> stale!
              }
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
              var idIdx = 0, dateIdx = 1, nameIdx = -1, phoneIdx = 3, modeIdx = 4, totalIdx = 7, itemsIdx = 8, statusIdx = 9, tableIdx = 10, txnIdx = 11;
              headers.forEach(function(h, idx) {
                if (h.indexOf("bill") !== -1 || h.indexOf("kot") !== -1 || (h.indexOf("id") !== -1 && h.indexOf("product") === -1 && h.indexOf("cust") === -1)) idIdx = idx;
                if (h.indexOf("date") !== -1 || h.indexOf("time") !== -1) dateIdx = idx;
                if ((h.indexOf("customer") !== -1 || h.indexOf("guest") !== -1 || h.indexOf("client") !== -1 || h === "name") &&
                    h.indexOf("dish") === -1 && h.indexOf("item") === -1 && h.indexOf("product") === -1) {
                  nameIdx = idx;
                }
                if (h.indexOf("phone") !== -1 || h.indexOf("mobile") !== -1) phoneIdx = idx;
                if (h.indexOf("mode") !== -1 || h.indexOf("payment") !== -1) modeIdx = idx;
                if (h.indexOf("total") !== -1 || h.indexOf("amount") !== -1) totalIdx = idx;
                if (h.indexOf("item") !== -1 || h.indexOf("dish") !== -1 || h.indexOf("summary") !== -1) itemsIdx = idx;
                if (h.indexOf("status") !== -1 && idx !== itemsIdx) statusIdx = idx;
                if (h.indexOf("table") !== -1) tableIdx = idx;
                if (h.indexOf("txn") !== -1 || h.indexOf("utr") !== -1 || h.indexOf("ref") !== -1) txnIdx = idx;
              });

              for (var r = 1; r < data.length; r++) {
                var row = data[r];
                var rawId = cleanOrderId(row[idIdx]);
                if (!rawId || rawId.toLowerCase() === "bill id" || rawId.toLowerCase() === "id") continue;
                // Filter out test orders!
                if (rawId.indexOf("TEST") !== -1 || (row[nameIdx] && String(row[nameIdx]).toUpperCase().indexOf("TEST") !== -1)) continue;

                var rawStatus = statusIdx !== -1 ? String(row[statusIdx] || "").trim() : "";
                if (rawStatus.indexOf("[") === 0 || rawStatus.indexOf("{") === 0) {
                  rawItems = rawStatus;
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
                var rowTime = rawDate ? new Date(rawDate).getTime() : 0;
                if (tableSettledTime > 0 && rowTime > 0 && rowTime <= tableSettledTime) {
                  continue; // Pre-settlement order -> ignore!
                }
                if (rowTime > 0 && (nowTime - rowTime) > 4 * 60 * 60 * 1000) {
                  continue; // Stale abandoned order -> ignore!
                }

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
                var rawTotal = parseFloat(String(row[totalIdx] || "0").replace(/[^0-9.]/g, "")) || 0;
                var rawItems = itemsIdx !== -1 ? String(row[itemsIdx] || "").trim() : "";

                var parsedItems = [];
                if (rawItems.indexOf("[") === 0) {
                  try {
                    parsedItems = JSON.parse(rawItems);
                  } catch (e) {
                    parsedItems = [{ name: rawItems, qty: 1, price: rawTotal }];
                  }
                } else if (rawItems) {
                  parsedItems = [{ name: rawItems, qty: 1, price: rawTotal }];
                }

                var canonicalTable = row[tableIdx] || ("Table " + rawTableClean);
                var orderObj = {
                  id: "BILL_" + rawId,
                  orderId: "BILL_" + rawId,
                  kotNumber: "KOT-" + rawId,
                  customerName: rawName || "Dine-In Guest",
                  customerPhone: rawPhone,
                  totalAmount: rawTotal,
                  total: rawTotal,
                  items: parsedItems,
                  itemsSummary: rawItems,
                  status: rawStatus,
                  paymentMode: rawMode,
                  table: canonicalTable,
                  tableName: canonicalTable,
                  transactionId: rawTxn,
                  timestamp: rawDate
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
  let spreadsheetId = data.spreadsheet_id;
  const orgId = data.org_id || data.org || data.outlet_id;

  // Resolve spreadsheetId from tenant registry if omitted by client
  if ((!spreadsheetId || spreadsheetId.indexOf("sheet_") === 0) && orgId) {
    spreadsheetId = getSheetIdForOrg(orgId);
  }

  const b = data.data || {};
  const cust = b.customer || {};
  const billId = String(b.bill_id || b.id || "");
  const cleanId = cleanOrderId(billId);
  const tableName = b.table_name || (b.table_number ? ("Table " + b.table_number) : "Table 1");
  const cTable = cleanTableId(tableName);
  const status = String(b.payment_status || b.status || "ORDER_RECEIVED").toUpperCase().trim();
  const isSettled = isStatusSettled(status);
  const txnId = b.transaction_id || b.upi_reference || "";
  const totalAmount = parseFloat(String(b.total_amount || b.subtotal || b.subtotal_amount || 0).replace(/[^0-9.]/g, "")) || 0;
  const timeStr = b.timestamp || new Date().toISOString();
  const rawItems = b.items || [];

  if (orgId) {
    try {
      var props = PropertiesService.getScriptProperties();

      if (isSettled) {
        // === PAYMENT SETTLED / CONFIRMED: PURGE CACHE & RECORD SETTLEMENT ===
        // 1. Record Table Settlement Timestamp (Any orders placed at/before this time belong to past session)
        props.setProperty("table_settled_" + orgId.trim() + "_" + cTable, String(new Date().getTime()));

        // 2. Add order ID to persistent settled list
        var settledKey = "settled_orders_" + orgId.trim();
        var settledList = [];
        try {
          var rawSettled = props.getProperty(settledKey);
          if (rawSettled) settledList = JSON.parse(rawSettled);
        } catch(e) {}
        if (cleanId && settledList.indexOf(cleanId) === -1) {
          settledList.push(cleanId);
          if (settledList.length > 300) settledList = settledList.slice(-300);
          props.setProperty(settledKey, JSON.stringify(settledList));
        }

        // 3. Purge settled orders from recent_orders_ memory cache
        var cacheKey = "recent_orders_" + orgId.trim();
        var rawCached = props.getProperty(cacheKey);
        if (rawCached) {
          var cachedOrders = [];
          try { cachedOrders = JSON.parse(rawCached); } catch(e) {}
          cachedOrders = cachedOrders.filter(function(co) {
            var coCleanId = cleanOrderId(co.id || co.orderId);
            var coTable = cleanTableId(co.table || co.tableName);
            if (coCleanId === cleanId) return false;
            if (coTable === cTable) return false; // Entire table session settled!
            return true;
          });
          props.setProperty(cacheKey, JSON.stringify(cachedOrders));
        }

        // 4. Clear pending waiter alerts for this table
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
        // === ORDER IN PROGRESS (ORDER_RECEIVED, PREPARING, READY, SERVED, PAYMENT_PENDING) ===
        // Filter out test orders!
        if (cleanId.indexOf("TEST") !== -1 || (cust.name && String(cust.name).toUpperCase().indexOf("TEST") !== -1)) {
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
          var mergedItems = (rawItems && rawItems.length > 0) ? rawItems : (prev.items || []);
          var mergedItemsSummary = (typeof rawItems === "string" && rawItems) ? rawItems : 
            ((rawItems && rawItems.length > 0) ? JSON.stringify(rawItems) : (prev.itemsSummary || ""));
          var mergedCustName = cust.name || b.customer_name || prev.customerName || "Dine-In Guest";
          if (mergedCustName && (mergedCustName.indexOf("Table ") === 0 || mergedCustName.indexOf(" x") !== -1 || mergedCustName.indexOf("{") !== -1 || mergedCustName.indexOf("[") !== -1 || mergedCustName.indexOf(",") !== -1)) {
            mergedCustName = "Dine-In Guest";
          }
          var mergedCustPhone = cust.phone || b.customer_phone || prev.customerPhone || "";
          var mergedTotal = totalAmount > 0 ? totalAmount : (prev.totalAmount || prev.total || 0);
          var mergedTime = prev.timestamp || timeStr; // PRESERVE ORIGINAL CREATION TIME!

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
            kitchenStatus: b.kitchenStatus || status,
            paymentMode: b.payment_mode || prev.paymentMode || "DINE_IN",
            table: tableName || prev.table,
            tableName: tableName || prev.tableName,
            transactionId: txnId || prev.transactionId,
            timestamp: mergedTime
          };

          cachedOrders[foundIdx] = orderObj;
        } else {
          var safeCustName = cust.name || b.customer_name || "Dine-In Guest";
          if (safeCustName && (safeCustName.indexOf("Table ") === 0 || safeCustName.indexOf(" x") !== -1 || safeCustName.indexOf("{") !== -1 || safeCustName.indexOf("[") !== -1 || safeCustName.indexOf(",") !== -1)) {
            safeCustName = "Dine-In Guest";
          }
          var orderObj = {
            id: billId,
            orderId: billId,
            kotNumber: cleanId ? ("KOT-" + cleanId) : billId,
            customerName: safeCustName,
            customerPhone: cust.phone || b.customer_phone || "",
            totalAmount: totalAmount,
            total: totalAmount,
            items: rawItems,
            itemsSummary: typeof rawItems === "string" ? rawItems : JSON.stringify(rawItems),
            status: status,
            kitchenStatus: b.kitchenStatus || status,
            paymentMode: b.payment_mode || "DINE_IN",
            table: tableName,
            tableName: tableName,
            transactionId: txnId,
            timestamp: timeStr
          };
          cachedOrders.push(orderObj);
        }
        if (cachedOrders.length > 50) cachedOrders = cachedOrders.slice(-50);
        props.setProperty(cacheKey, JSON.stringify(cachedOrders));
      }
    } catch (eCache) {}
  }

  // If spreadsheetId is missing or placeholder, return cached success
  if (!spreadsheetId || spreadsheetId.indexOf("sheet_") === 0) {
    return responseJson({
      success: true,
      bill_id: billId,
      status: status,
      cached: true,
      message: isSettled ? "Table session settled and cache purged." : "Order cached in cloud memory."
    });
  }

  // Write to Google Sheet
  try {
    const ss = SpreadsheetApp.openById(spreadsheetId);
    const sheet = getOrCreateBillsSheet(ss);
    const lastRow = sheet.getLastRow();
    let existingRow = -1;

    if (lastRow > 1) {
      const data = sheet.getDataRange().getValues();
      var headers = data[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
      var idIdx = 0, statusIdx = 9, modeIdx = 4, tableIdx = 10, txnIdx = 11;
      headers.forEach(function(h, idx) {
        if (h.indexOf("bill") !== -1 || h.indexOf("kot") !== -1 || (h.indexOf("id") !== -1 && h.indexOf("product") === -1 && h.indexOf("cust") === -1)) idIdx = idx;
        if (h.indexOf("status") !== -1) statusIdx = idx;
        if (h.indexOf("mode") !== -1 || h.indexOf("payment") !== -1) modeIdx = idx;
        if (h.indexOf("table") !== -1) tableIdx = idx;
        if (h.indexOf("txn") !== -1 || h.indexOf("utr") !== -1 || h.indexOf("ref") !== -1) txnIdx = idx;
      });

      // Find matching row by clean ID
      for (let i = 1; i < data.length; i++) {
        const rowNormId = cleanOrderId(data[i][idIdx]);
        if (rowNormId && rowNormId === cleanId) {
          existingRow = i + 1;
          break;
        }
      }

      // If settling this table, update ALL unpaid rows for this table to PAID!
      if (isSettled) {
        for (let i = 1; i < data.length; i++) {
          const rowTableClean = cleanTableId(data[i][tableIdx]);
          const rowStatus = String(data[i][statusIdx] || "").toUpperCase().trim();
          if (rowTableClean === cTable && !isStatusSettled(rowStatus)) {
            sheet.getRange(i + 1, statusIdx + 1).setValue("PAID");
            if (b.payment_mode) sheet.getRange(i + 1, modeIdx + 1).setValue(b.payment_mode);
            if (txnId) sheet.getRange(i + 1, txnIdx + 1).setValue(txnId);
          }
        }
      }

      // If updating an existing row for status update with no items provided, only update status & txn
      if (existingRow !== -1 && (b.update_type === "STATUS_UPDATE" || (!rawItems || rawItems.length === 0))) {
        sheet.getRange(existingRow, statusIdx + 1).setValue(isSettled ? "PAID" : status);
        if (txnId) sheet.getRange(existingRow, txnIdx + 1).setValue(txnId);
        return responseJson({
          success: true,
          bill_id: billId,
          status: isSettled ? "PAID" : status,
          row: existingRow,
          cleared: isSettled
        });
      }
    }

    const rowData = [
      billId,
      timeStr,
      cust.name || b.customer_name || (tableName.indexOf("Table ") === 0 ? "Dine-In Guest" : tableName),
      cust.phone || b.customer_phone || "",
      b.payment_mode || (isSettled ? "PAID" : "CASH"),
      b.subtotal || b.subtotal_amount || totalAmount,
      b.discount || 0,
      totalAmount,
      typeof rawItems === "string" ? rawItems : JSON.stringify(rawItems),
      isSettled ? "PAID" : status,
      tableName,
      txnId
    ];

    if (existingRow !== -1) {
      sheet.getRange(existingRow, 1, 1, rowData.length).setValues([rowData]);
    } else {
      sheet.appendRow(rowData);
    }

    return responseJson({
      success: true,
      bill_id: billId,
      status: isSettled ? "PAID" : status,
      row: existingRow !== -1 ? existingRow : lastRow + 1,
      cleared: isSettled
    });
  } catch (errSheet) {
    return responseJson({
      success: true,
      bill_id: billId,
      status: status,
      warning: errSheet.toString(),
      message: "Order cached in cloud memory, sheet write failed."
    });
  }
}

function handleClearTable(data) {
  var orgId = data.org_id || data.org || data.outlet_id || "";
  var spreadsheetId = data.spreadsheet_id || getSheetIdForOrg(orgId);
  var table = data.table_name || data.table || data.table_number || "1";
  var cTable = cleanTableId(table);

  if (orgId) {
    try {
      var props = PropertiesService.getScriptProperties();
      props.setProperty("table_settled_" + orgId.trim() + "_" + cTable, String(new Date().getTime()));

      var cacheKey = "recent_orders_" + orgId.trim();
      var rawCached = props.getProperty(cacheKey);
      if (rawCached) {
        var cachedOrders = JSON.parse(rawCached);
        cachedOrders = cachedOrders.filter(function(co) {
          return cleanTableId(co.table || co.tableName) !== cTable;
        });
        props.setProperty(cacheKey, JSON.stringify(cachedOrders));
      }

      var waiterKey = "waiter_alerts_" + orgId.trim();
      var rawWaiters = props.getProperty(waiterKey);
      if (rawWaiters) {
        var wList = JSON.parse(rawWaiters);
        wList = wList.filter(function(w) { return cleanTableId(w.table || w.tableName) !== cTable; });
        props.setProperty(waiterKey, JSON.stringify(wList));
      }
    } catch(e) {}
  }

  if (spreadsheetId && spreadsheetId.indexOf("sheet_") !== 0) {
    try {
      var ss = SpreadsheetApp.openById(spreadsheetId);
      var sheet = getOrCreateBillsSheet(ss);
      if (sheet && sheet.getLastRow() > 1) {
        var dataVals = sheet.getDataRange().getValues();
        var headers = dataVals[0].map(function(h) { return String(h || "").trim().toLowerCase(); });
        var statusIdx = 9, tableIdx = 10;
        headers.forEach(function(h, idx) {
          if (h.indexOf("status") !== -1) statusIdx = idx;
          if (h.indexOf("table") !== -1) tableIdx = idx;
        });
        for (var r = 1; r < dataVals.length; r++) {
          if (cleanTableId(dataVals[r][tableIdx]) === cTable && !isStatusSettled(dataVals[r][statusIdx])) {
            sheet.getRange(r + 1, statusIdx + 1).setValue("PAID");
          }
        }
      }
    } catch(e) {}
  }

  return responseJson({ success: true, message: "Table " + table + " session and cache cleared successfully." });
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

function responseJson(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
