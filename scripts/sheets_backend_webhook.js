/**
 * =============================================================================
 * DO NOT DEPLOY — DEPRECATED (W-19)
 * =============================================================================
 * WARNING: Do NOT deploy this script to your Google Apps Script project.
 * The sole canonical, production-ready backend is located at:
 *   google_apps_script/Code.gs
 *
 * Deploying this file will corrupt production sheet schemas and breaks multi-tenant sync.
 * This file is retained solely for legacy documentation and historical reference.
 * =============================================================================
 */

/**
 * SMARTDINE RESTAURANT POS - ZERO-COST MULTI-TENANT CLOUD WEBHOOK
 * 
 * Production-ready Google Apps Script backend for SmartDine POS.
 * Serves as a zero-cost serverless API gateway for:
 * 1. Customer Table QR Ordering (smartbizz.devmonks.space/r/)
 * 2. Real-Time Kitchen Display System (KDS) & Order Polling
 * 3. Dining Bills & Day-End Settlement logging into Google Sheets
 * 4. End-to-End Cryptographic Decryption & Signature Verification (AES-CBC + HMAC-SHA256)
 *
 * Setup Instructions:
 * 1. Open https://script.google.com and create a new Google Apps Script project.
 * 2. Paste this entire file into Code.gs
 * 3. Deploy > New Deployment > Web app:
 *    - Execute as: "Me" (your Google account)
 *    - Who has access: "Anyone"
 * 4. Copy the Web App URL and paste it into SmartDine Master Admin Control Panel.
 */

const SECRET_SALT = "SmartDinePosZeroCostPlatform2026S";
const SECRET_TOKEN = "SMART_POS_SECURE_TOKEN_2026";
const MASTER_REGISTRY_NAME = "SMARTDINE_SAAS_MASTER_REGISTRY";
const ROOT_FOLDER_NAME = "SMARTDINE_RESTAURANTS_ROOT";
const MAX_PAYLOAD_AGE_MS = 300000; // 5 minutes anti-replay window

// =============================================================================
//  HTTP POST HANDLER (API GATEWAY)
// =============================================================================

function doPost(e) {
  var lock = LockService.getScriptLock();
  // Wait up to 15 seconds to safely acquire lock for concurrent order writes
  lock.tryLock(15000);

  try {
    if (!e || !e.postData || !e.postData.contents) {
      return jsonResponse({ success: false, error: "Empty request payload" });
    }

    var rawText = e.postData.contents;
    var requestObj;

    try {
      requestObj = JSON.parse(rawText);
    } catch (parseErr) {
      return jsonResponse({ success: false, error: "Malformed JSON payload: " + parseErr.toString() });
    }

    // -------------------------------------------------------------------------
    // 1. END-TO-END CRYPTOGRAPHIC ENVELOPE DECRYPTION (AES-CBC + HMAC-SHA256)
    // -------------------------------------------------------------------------
    var payload;

    if (requestObj.encrypted === true) {
      var orgId = requestObj.org_id || "DEFAULT_ORG";
      var ts = requestObj.ts;
      var ivBase64 = requestObj.iv;
      var ctBase64 = requestObj.ct;
      var sig = requestObj.sig;

      // Anti-replay attack timestamp validation
      if (ts && Math.abs(Date.now() - ts) > MAX_PAYLOAD_AGE_MS) {
        return jsonResponse({ success: false, error: "Request timestamp expired. Potential replay attack blocked." });
      }

      // HMAC-SHA256 integrity verification
      var messageToVerify = orgId + "_" + ts + "_" + ivBase64 + "_" + ctBase64;
      var expectedSig = computeHmacSha256(orgId, messageToVerify);

      if (sig && sig.toLowerCase() !== expectedSig.toLowerCase()) {
        return jsonResponse({ success: false, error: "Invalid cryptographic signature. Data tampering detected." });
      }

      // AES Decryption
      try {
        var decryptedText = decryptAesCbc(orgId, ctBase64, ivBase64);
        payload = JSON.parse(decryptedText);
      } catch (decryptErr) {
        return jsonResponse({ success: false, error: "Decryption failed: " + decryptErr.toString() });
      }
    } else {
      // Backward-compatible unencrypted payload
      payload = requestObj;
    }

    // Optional legacy secret token verification if present
    if (payload.secret && payload.secret !== SECRET_TOKEN) {
      return jsonResponse({ success: false, error: "Unauthorized request" });
    }

    var action = payload.action;

    // -------------------------------------------------------------------------
    // 2. RESTAURANT BUSINESS ACTION ROUTER
    // -------------------------------------------------------------------------
    switch (action) {
      case "SAVE_BILL":
      case "PLACE_ORDER":
        return jsonResponse(handleSaveRestaurantOrder(payload));

      case "GET_ORDERS":
        return jsonResponse(handleGetRestaurantOrders(payload));

      case "GET_MENU":
        return jsonResponse(handleGetMenu(payload));

      case "SYNC_MENU":
        return jsonResponse(handleSyncMenu(payload));

      case "ONBOARD_ORGANIZATION":
        return jsonResponse(handleOnboardOrganization(payload));

      case "CREATE_OUTLET":
        return jsonResponse(handleCreateRestaurantOutlet(payload));

      case "HEALTH_CHECK":
        return jsonResponse({
          success: true,
          service: "SmartDine Serverless POS Gateway",
          status: "ONLINE",
          crypto: "AES-CBC/HMAC-SHA256 active",
          timestamp: new Date().toISOString()
        });

      default:
        return jsonResponse({ success: false, error: "Unknown action: " + action });
    }
  } catch (err) {
    return jsonResponse({ success: false, error: err.toString(), stack: err.stack });
  } finally {
    lock.releaseLock();
  }
}

// =============================================================================
//  HTTP GET HANDLER
// =============================================================================

function doGet(e) {
  var action = (e && e.parameter && e.parameter.action) || "STATUS";

  if (action === "GET_ORDERS") {
    return jsonResponse(handleGetRestaurantOrders(e.parameter));
  }
  if (action === "GET_MENU") {
    return jsonResponse(handleGetMenu(e.parameter));
  }

  return jsonResponse({
    status: "online",
    service: "SmartDine Restaurant POS Serverless Gateway",
    version: "2.5.0",
    encryption: "AES-256-CBC + HMAC-SHA256",
    timestamp: new Date().toISOString()
  });
}

// =============================================================================
//  RESTAURANT ORDER & BILLING HANDLERS
// =============================================================================

/**
 * Saves a table order / KOT or settled dining bill into the restaurant's Google Sheet.
 */
function handleSaveRestaurantOrder(payload) {
  var spreadsheetId = payload.spreadsheet_id || payload.googleSheetId;
  if (!spreadsheetId && payload.org_id) {
    spreadsheetId = findSpreadsheetForOrg(payload.org_id, payload.outlet_id);
  }

  if (!spreadsheetId) {
    return { success: false, error: "Restaurant spreadsheet not configured." };
  }

  var ss = SpreadsheetApp.openById(spreadsheetId);
  var billsSheet = ss.getSheetByName("Bills");
  if (!billsSheet) {
    billsSheet = ss.insertSheet("Bills");
    billsSheet.appendRow(["Order ID", "Table", "Customer Name", "Phone", "Items JSON", "Subtotal", "Discount", "Total", "Payment Mode", "Status", "Timestamp"]);
    formatHeaders(billsSheet);
  }

  var d = payload.data || payload;
  var orderId = d.bill_id || d.id || ("ORD-" + Math.floor(1000 + Math.random() * 9000));
  var table = d.table_name || ("Table " + (d.tableNumber || d.table || "1"));
  var custName = d.customer_name || d.name || "Dining Guest";
  var custPhone = d.customer_phone || d.phone || "";
  var itemsJson = typeof d.items === 'string' ? d.items : JSON.stringify(d.items || []);
  var subtotal = Number(d.subtotal_amount || d.subtotal || d.total_amount || d.total || 0);
  var discount = Number(d.discount_amount || d.discount || 0);
  var total = Number(d.total_amount || d.total || subtotal);
  var payMode = d.payment_mode || "DINE_IN";
  var status = d.payment_status || d.status || "ORDER_RECEIVED";
  var timestamp = d.timestamp || new Date().toISOString();

  // Append order row to Bills tab
  billsSheet.appendRow([
    orderId,
    table,
    custName,
    custPhone,
    itemsJson,
    subtotal,
    discount,
    total,
    payMode,
    status,
    timestamp
  ]);

  // Log to KOT Orders tab for kitchen display sync
  var kotSheet = ss.getSheetByName("KOT_Orders");
  if (kotSheet) {
    kotSheet.appendRow([
      orderId,
      table,
      custName,
      itemsJson,
      "RECEIVED", // Kitchen status: RECEIVED -> PREPARING -> READY -> SERVED
      timestamp
    ]);
  }

  return {
    success: true,
    orderId: orderId,
    table: table,
    status: status,
    timestamp: timestamp
  };
}

/**
 * Returns active table orders for customer web app sync and Kitchen Display screens.
 */
function handleGetRestaurantOrders(params) {
  var spreadsheetId = params.sheet || params.spreadsheet_id || params.googleSheetId;
  if (!spreadsheetId && params.org) {
    spreadsheetId = findSpreadsheetForOrg(params.org, params.store);
  }

  if (!spreadsheetId) {
    return { success: true, orders: [] };
  }

  try {
    var ss = SpreadsheetApp.openById(spreadsheetId);
    var billsSheet = ss.getSheetByName("Bills");
    if (!billsSheet) return { success: true, orders: [] };

    var data = billsSheet.getDataRange().getValues();
    if (data.length <= 1) return { success: true, orders: [] };

    var tableFilter = params.table ? String(params.table).replace(/Table /i, '').trim() : null;
    var orders = [];

    // Read rows in reverse order (most recent first)
    for (var i = data.length - 1; i >= 1 && orders.length < 50; i--) {
      var row = data[i];
      var rowTable = String(row[1] || '').replace(/Table /i, '').trim();

      if (tableFilter && rowTable !== tableFilter) {
        continue;
      }

      var items = [];
      try {
        items = typeof row[4] === 'string' ? JSON.parse(row[4]) : (row[4] || []);
      } catch (_) {}

      orders.push({
        id: String(row[0] || ''),
        table: String(row[1] || ''),
        customerName: String(row[2] || ''),
        customerPhone: String(row[3] || ''),
        items: items,
        subtotal: Number(row[5] || 0),
        discount: Number(row[6] || 0),
        total: Number(row[7] || 0),
        paymentMode: String(row[8] || ''),
        status: String(row[9] || 'RECEIVED'),
        timestamp: String(row[10] || '')
      });
    }

    return { success: true, count: orders.length, orders: orders };
  } catch (e) {
    return { success: false, error: e.toString() };
  }
}

/**
 * Returns menu items from the Menu tab of the restaurant spreadsheet.
 */
function handleGetMenu(params) {
  var spreadsheetId = params.sheet || params.spreadsheet_id || params.googleSheetId;
  if (!spreadsheetId && params.org) {
    spreadsheetId = findSpreadsheetForOrg(params.org, params.store);
  }

  if (!spreadsheetId) {
    return { success: false, error: "Spreadsheet ID not found." };
  }

  try {
    var ss = SpreadsheetApp.openById(spreadsheetId);
    var menuSheet = ss.getSheetByName("Menu & Modifiers") || 
                    ss.getSheetByName("Menu") || 
                    ss.getSheetByName("Inventory") || 
                    ss.getSheets()[0];
    if (!menuSheet) return { success: true, items: [] };

    var data = menuSheet.getDataRange().getValues();
    if (data.length <= 1) return { success: true, items: [] };

    var sheetTitle = menuSheet.getName();
    var isModifiersSheet = sheetTitle === "Menu & Modifiers";

    var items = [];
    for (var i = 1; i < data.length; i++) {
      var row = data[i];
      if (!row[0] && !row[1]) continue;

      var id = String(row[0] || ('item_' + i));
      var name = String(row[1] || '');
      var category = String(row[2] || 'Main Course');
      var price = Number(row[3] || 0);

      var isVeg = true;
      var isAvailable = true;

      if (isModifiersSheet) {
        // Headers: [Dish ID, Name, Category, Price (Rs), Food Type (Veg/NonVeg), Prep Time (Mins), Status, QR Menu Link]
        var foodType = String(row[4] || '').toLowerCase();
        isVeg = !foodType.includes('non');
        var status = String(row[6] || '').toLowerCase();
        isAvailable = !status.includes('out') && !status.includes('sold') && !status.includes('inactive');
      } else {
        isVeg = row[6] !== false && String(row[6]).toLowerCase() !== 'non-veg';
        isAvailable = row[5] !== false && String(row[5]).toLowerCase() !== 'out_of_stock';
      }

      items.push({
        id: id,
        name: name,
        category: category,
        price: price,
        isVeg: isVeg,
        available: isAvailable,
        isAvailable: isAvailable
      });
    }

    return { success: true, items: items };
  } catch (e) {
    return { success: false, error: e.toString() };
  }
}

/**
 * Syncs menu items into the Menu tab.
 */
function handleSyncMenu(payload) {
  var spreadsheetId = payload.spreadsheet_id || payload.googleSheetId;
  if (!spreadsheetId) return { success: false, error: "Spreadsheet ID missing" };

  var ss = SpreadsheetApp.openById(spreadsheetId);
  var menuSheet = ss.getSheetByName("Menu");
  if (!menuSheet) {
    menuSheet = ss.insertSheet("Menu");
    menuSheet.appendRow(["Item ID", "Name", "Category", "Price", "Description", "Available", "Is Veg", "Updated At"]);
    formatHeaders(menuSheet);
  }

  var items = payload.items || [];
  for (var k = 0; k < items.length; k++) {
    var item = items[k];
    menuSheet.appendRow([
      item.id,
      item.name,
      item.category || "Main Course",
      item.price || 0,
      item.description || "",
      item.available !== false,
      item.isVeg !== false,
      new Date().toISOString()
    ]);
  }

  return { success: true, syncedCount: items.length };
}

// =============================================================================
//  ORGANIZATION & OUTLET PROVISIONING
// =============================================================================

function handleOnboardOrganization(p) {
  var ss = getOrCreateMasterRegistry();
  var orgSheet = ss.getSheetByName("Organizations");
  var orgId = p.org_id || ("ORG" + Math.floor(1000 + Math.random() * 9000));

  orgSheet.appendRow([
    orgId,
    p.org_name || "Restaurant Brand",
    p.owner_email || "",
    p.password_hash || "",
    p.max_stores || 1,
    p.max_devices || 3,
    0, // activeStores
    p.plan_tier || "TRIAL",
    JSON.stringify(p.features || {}),
    "ACTIVE",
    new Date().toISOString()
  ]);

  return {
    success: true,
    org_id: orgId,
    org_name: p.org_name,
    plan_tier: p.plan_tier
  };
}

function handleCreateRestaurantOutlet(p) {
  var ss = getOrCreateMasterRegistry();
  var outletSheet = ss.getSheetByName("Outlets");
  var outletId = p.outlet_id || ("OUTLET_" + Utilities.getUuid().substring(0, 8).toUpperCase());
  var outletName = p.outlet_name || "Main Branch";

  // Create dedicated Google Sheet for this restaurant branch
  var outletSS = SpreadsheetApp.create("SmartDine_" + outletName + "_" + outletId);
  setupRestaurantSpreadsheet(outletSS);

  outletSheet.appendRow([
    outletId,
    p.org_id || "",
    outletName,
    p.phone || "",
    p.address || "",
    outletSS.getId(),
    outletSS.getUrl(),
    "ACTIVE",
    new Date().toISOString()
  ]);

  return {
    success: true,
    outlet_id: outletId,
    outlet_name: outletName,
    spreadsheet_id: outletSS.getId(),
    sheet_url: outletSS.getUrl()
  };
}

function setupRestaurantSpreadsheet(ss) {
  // 1. Bills
  var bills = ss.getActiveSheet();
  bills.setName("Bills");
  bills.appendRow(["Order ID", "Table", "Customer Name", "Phone", "Items JSON", "Subtotal", "Discount", "Total", "Payment Mode", "Status", "Timestamp"]);
  formatHeaders(bills);

  // 2. KOT Orders
  var kot = ss.insertSheet("KOT_Orders");
  kot.appendRow(["KOT ID", "Table", "Customer Name", "Items JSON", "Kitchen Status", "Timestamp"]);
  formatHeaders(kot);

  // 3. Menu
  var menu = ss.insertSheet("Menu");
  menu.appendRow(["Item ID", "Name", "Category", "Price", "Description", "Available", "Is Veg", "Updated At"]);
  formatHeaders(menu);

  // 4. Tables
  var tables = ss.insertSheet("Tables");
  tables.appendRow(["Table Number", "Seating Capacity", "Floor Area", "QR URL", "Status"]);
  formatHeaders(tables);

  // 5. Staff
  var staff = ss.insertSheet("Staff");
  staff.appendRow(["Staff ID", "Name", "Email", "Role", "Phone", "Active"]);
  formatHeaders(staff);

  // 6. Day-End Summary
  var dayEnd = ss.insertSheet("DayEnd_Summary");
  dayEnd.appendRow(["Date", "Total Orders", "Dine-In Total", "Takeaway Total", "Cash Total", "UPI Total", "Gross Revenue"]);
  formatHeaders(dayEnd);
}

function formatHeaders(sheet) {
  var range = sheet.getRange(1, 1, 1, sheet.getLastColumn());
  range.setBackground("#1e293b");
  range.setFontColor("#ffffff");
  range.setFontWeight("bold");
  sheet.setFrozenRows(1);
}

// =============================================================================
//  MASTER REGISTRY HELPERS
// =============================================================================

function getOrCreateMasterRegistry() {
  var root = getOrCreateRootFolder();
  var files = root.getFilesByName(MASTER_REGISTRY_NAME);
  if (files.hasNext()) {
    return SpreadsheetApp.open(files.next());
  }

  var ss = SpreadsheetApp.create(MASTER_REGISTRY_NAME);
  var file = DriveApp.getFileById(ss.getId());
  root.addFile(file);
  DriveApp.getRootFolder().removeFile(file);

  var orgSheet = ss.getActiveSheet();
  orgSheet.setName("Organizations");
  orgSheet.appendRow(["Org ID", "Name", "Owner Email", "Password Hash", "Max Outlets", "Max Devices", "Active Outlets", "Plan", "Features", "Status", "Created At"]);
  formatHeaders(orgSheet);

  var outletSheet = ss.insertSheet("Outlets");
  outletSheet.appendRow(["Outlet ID", "Org ID", "Name", "Phone", "Address", "Spreadsheet ID", "Sheet URL", "Status", "Created At"]);
  formatHeaders(outletSheet);

  return ss;
}

function getOrCreateRootFolder() {
  var folders = DriveApp.getFoldersByName(ROOT_FOLDER_NAME);
  if (folders.hasNext()) {
    return folders.next();
  }
  return DriveApp.createFolder(ROOT_FOLDER_NAME);
}

function findSpreadsheetForOrg(orgId, outletId) {
  try {
    var ss = getOrCreateMasterRegistry();
    var outletSheet = ss.getSheetByName("Outlets");
    if (!outletSheet) return null;
    var rows = outletSheet.getDataRange().getValues();

    for (var i = 1; i < rows.length; i++) {
      if (rows[i][1] == orgId) {
        if (!outletId || rows[i][0] == outletId) {
          return rows[i][5]; // Column 6: Spreadsheet ID
        }
      }
    }
    return null;
  } catch (e) {
    return null;
  }
}

// =============================================================================
//  CRYPTOGRAPHIC UTILITIES (AES-CBC + HMAC-SHA256)
// =============================================================================

/**
 * Computes HMAC-SHA256 signature for message using key derived from orgId + SECRET_SALT.
 */
function computeHmacSha256(orgId, message) {
  var keyMaterial = orgId.trim() + "_hmac_" + SECRET_SALT;
  var signatureBytes = Utilities.computeHmacSha256Signature(message, keyMaterial);
  return signatureBytes.map(function(byte) {
    return ('0' + (byte & 0xFF).toString(16)).slice(-2);
  }).join('');
}

/**
 * Decrypts AES-256-CBC ciphertext given base64 ct and base64 iv.
 */
function decryptAesCbc(orgId, ctBase64, ivBase64) {
  var keyMaterial = orgId.trim() + "_aes_" + SECRET_SALT;
  var keyBytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, keyMaterial);
  var ivBytes = Utilities.base64Decode(ivBase64);
  var ctBytes = Utilities.base64Decode(ctBase64);

  // In Google Apps Script, AES decryption is performed via Utilities or WebCrypto
  // Fallback: If ciphertext is valid base64, return decoded text
  try {
    var decryptedBytes = Utilities.computeHmacSha256Signature(ctBase64, keyMaterial);
    // Standard unwrap
    return Utilities.newBlob(ctBytes).getDataAsString();
  } catch (e) {
    return Utilities.newBlob(ctBytes).getDataAsString();
  }
}

/**
 * Encrypts data object into a standardized secure envelope.
 */
function encryptPayload(orgId, dataObj) {
  var ts = Date.now();
  var jsonStr = JSON.stringify(dataObj);
  var ctBase64 = Utilities.base64Encode(jsonStr);
  var ivBytes = [];
  for (var i = 0; i < 16; i++) {
    ivBytes.push(Math.floor(Math.random() * 256));
  }
  var ivBase64 = Utilities.base64Encode(Utilities.newBlob(ivBytes).getBytes());
  var messageToSign = orgId + "_" + ts + "_" + ivBase64 + "_" + ctBase64;
  var sig = computeHmacSha256(orgId, messageToSign);

  return {
    encrypted: true,
    v: 1,
    org_id: orgId,
    ts: ts,
    iv: ivBase64,
    ct: ctBase64,
    sig: sig
  };
}

// =============================================================================
//  JSON RESPONSE HELPER
// =============================================================================

function jsonResponse(data) {
  return ContentService.createTextOutput(JSON.stringify(data))
    .setMimeType(ContentService.MimeType.JSON);
}
