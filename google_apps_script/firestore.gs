/**
 * Firestore over REST, for the handful of writes this script has to make.
 *
 * The app and the admin console talk to Firestore through the Firebase SDK;
 * Apps Script has no SDK, so this is the REST surface with just enough of a
 * client around it: get one document, replace one, merge into one, create
 * one with a generated id, and a single-field equality query.
 *
 * Authentication. The project's security rules are open (a decision recorded
 * in the handoff), and the marketing site already writes `registration_requests`
 * with no credential at all, so by default this client sends none either --
 * that keeps deployment a paste-and-publish with no GCP project linking.
 * If the rules are ever tightened, set FS_USE_OAUTH to true: the request then
 * carries the script's own OAuth token, which needs the Apps Script project
 * bound to the Firebase GCP project and the
 * `https://www.googleapis.com/auth/datastore` scope in appsscript.json.
 *
 * Every function throws on a non-2xx reply with the body in the message, so a
 * caller that wants "best effort" wraps it in try/catch and a caller that must
 * not half-provision a tenant does not.
 */

var FS_PROJECT = "smartdine-restaurant-pos";
var FS_USE_OAUTH = false;
var FS_BASE = "https://firestore.googleapis.com/v1/projects/" + FS_PROJECT + "/databases/(default)/documents";

function fsHeaders_() {
  var h = { "Content-Type": "application/json" };
  if (FS_USE_OAUTH) h["Authorization"] = "Bearer " + ScriptApp.getOAuthToken();
  return h;
}

function fsRequest_(method, url, body) {
  var opts = { method: method, headers: fsHeaders_(), muteHttpExceptions: true };
  if (body !== undefined) opts.payload = JSON.stringify(body);
  var res = UrlFetchApp.fetch(url, opts);
  var code = res.getResponseCode();
  var text = res.getContentText();
  if (code === 404 && method === "get") return null;
  if (code < 200 || code >= 300) {
    throw new Error("Firestore " + method.toUpperCase() + " " + url.replace(FS_BASE, "") + " -> HTTP " + code + ": " + text.slice(0, 300));
  }
  return text ? JSON.parse(text) : {};
}

// ── values ───────────────────────────────────────────────────────────────────

/** JS value -> Firestore Value. Dates become timestamps, ints stay ints. */
function fsEncode_(v) {
  if (v === null || v === undefined) return { nullValue: null };
  if (v instanceof Date) return { timestampValue: v.toISOString() };
  if (typeof v === "boolean") return { booleanValue: v };
  if (typeof v === "number") {
    return Number.isInteger(v) ? { integerValue: String(v) } : { doubleValue: v };
  }
  if (typeof v === "string") return { stringValue: v };
  if (Array.isArray(v)) return { arrayValue: { values: v.map(fsEncode_) } };
  if (typeof v === "object") return { mapValue: { fields: fsEncodeFields_(v) } };
  return { stringValue: String(v) };
}

function fsEncodeFields_(obj) {
  var out = {};
  Object.keys(obj).forEach(function (k) {
    if (obj[k] !== undefined) out[k] = fsEncode_(obj[k]);
  });
  return out;
}

/** Firestore Value -> JS value. */
function fsDecode_(val) {
  if (!val || typeof val !== "object") return null;
  if ("stringValue" in val) return val.stringValue;
  if ("integerValue" in val) return parseInt(val.integerValue, 10);
  if ("doubleValue" in val) return val.doubleValue;
  if ("booleanValue" in val) return val.booleanValue;
  if ("timestampValue" in val) return new Date(val.timestampValue);
  if ("nullValue" in val) return null;
  if ("arrayValue" in val) return (val.arrayValue.values || []).map(fsDecode_);
  if ("mapValue" in val) return fsDecodeFields_(val.mapValue.fields || {});
  return null;
}

function fsDecodeFields_(fields) {
  var out = {};
  Object.keys(fields || {}).forEach(function (k) { out[k] = fsDecode_(fields[k]); });
  return out;
}

function fsIdOf_(doc) {
  var name = String((doc && doc.name) || "");
  return name.substring(name.lastIndexOf("/") + 1);
}

// ── documents ────────────────────────────────────────────────────────────────

/** Read `collection/id`. Returns the decoded fields, or null when absent. */
function fsGet_(docPath) {
  var doc = fsRequest_("get", FS_BASE + "/" + docPath);
  return doc ? fsDecodeFields_(doc.fields) : null;
}

/** Create or fully replace `collection/id`. */
function fsSet_(docPath, obj) {
  return fsRequest_("patch", FS_BASE + "/" + docPath, { fields: fsEncodeFields_(obj) });
}

/**
 * Merge `obj` into `collection/id`, creating it if absent. Only the keys given
 * are written; everything else on the document is left alone.
 */
function fsMerge_(docPath, obj) {
  var keys = Object.keys(obj).filter(function (k) { return obj[k] !== undefined; });
  var mask = keys.map(function (k) { return "updateMask.fieldPaths=" + encodeURIComponent(k); }).join("&");
  return fsRequest_("patch", FS_BASE + "/" + docPath + "?" + mask, { fields: fsEncodeFields_(obj) });
}

/** Create a document with a server-generated id. Returns the id. */
function fsCreate_(collection, obj) {
  var doc = fsRequest_("post", FS_BASE + "/" + collection, { fields: fsEncodeFields_(obj) });
  return fsIdOf_(doc);
}

/**
 * `where field == value`, at most `limit` rows. Returns [{id, data}].
 * A structured query against the parent of the collection, which is how the
 * REST API spells `collection('x').where(...).get()`.
 */
function fsQueryEq_(collection, field, value, limit) {
  var body = {
    structuredQuery: {
      from: [{ collectionId: collection }],
      where: {
        fieldFilter: {
          field: { fieldPath: field },
          op: "EQUAL",
          value: fsEncode_(value)
        }
      },
      limit: limit || 1
    }
  };
  var rows = fsRequest_("post", FS_BASE + ":runQuery", body);
  var out = [];
  (rows || []).forEach(function (r) {
    if (r.document) out.push({ id: fsIdOf_(r.document), data: fsDecodeFields_(r.document.fields) });
  });
  return out;
}
