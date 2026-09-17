/// One way to print a slip.
///
/// Every screen that prints goes through here, which is what stops the app
/// having two answers to "what does our bill look like". It resolves the
/// template the owner mapped to this order type, renders it, encodes it and
/// hands the bytes to the printer.
///
/// Two rules, both from FEATURE_MASTER_PLAN.md rule 7:
///
/// - **It never throws.** A template that cannot render, a printer that is
///   asleep, a missing mapping: all of them come back as a result the caller
///   can show, and none of them stop a bill being saved.
/// - **It never decides whether to print.** The caller owns that, because the
///   caller knows whether the feature is on and whether the owner asked for
///   auto-print.
library;

import 'package:esc_pos_utils_plus/esc_pos_utils_plus.dart';

import 'escpos_encoder.dart';
import 'receipt_context.dart';
import 'receipt_layout.dart';
import 'receipt_renderer.dart';
import 'receipt_store.dart';
import 'receipt_template.dart';
import 'receipt_text_encoder.dart';

/// What happened, in enough detail to tell the user the truth.
class ReceiptPrintResult {
  /// Slips that reached the printer.
  final List<String> printed;

  /// Slips that were rendered but could not be sent.
  final List<String> failed;

  /// Anything the renderer wanted to say — unknown placeholders, a condition
  /// that would not parse. Surfaced so a broken template is visible somewhere
  /// other than the paper.
  final List<String> warnings;

  final String? error;

  const ReceiptPrintResult({
    this.printed = const [],
    this.failed = const [],
    this.warnings = const [],
    this.error,
  });

  bool get ok => failed.isEmpty && error == null && printed.isNotEmpty;
  bool get printedNothing => printed.isEmpty;

  /// Nothing reached the printer and nothing was refused either: every slip
  /// asked for rendered empty. That is a template problem, not a printer
  /// problem, and telling the user the printer refused sends them to the
  /// wrong settings screen.
  bool get nothingToPrint =>
      printed.isEmpty && failed.isEmpty && error == null;

  /// The best one-line cause available, for a message to the user.
  String get reason {
    if (error != null) return error!;
    if (nothingToPrint) {
      return warnings.isEmpty
          ? 'This slip\'s template is empty. Check Settings > Receipts & slips.'
          : warnings.first;
    }
    if (failed.isNotEmpty) {
      return 'The printer did not take ${failed.first}.';
    }
    return 'Nothing was printed.';
  }
}

/// Sends bytes to a printer. Kept as a function so this service has no
/// dependency on Riverpod, and so a test can watch what it produced.
typedef PrinterSink = Future<bool> Function(List<int> bytes);

class ReceiptPrintService {
  ReceiptPrintService._();

  /// `CapabilityProfile.load()` parses a bundled asset. It never changes
  /// within a run, and the kitchen prints one slip per station in a loop, so
  /// it is read once and kept.
  static CapabilityProfile? _caps;

  static Future<CapabilityProfile> _profile() async =>
      _caps ??= await CapabilityProfile.load();

  /// Render and print one slip.
  static Future<ReceiptPrintResult> printOne({
    required String orgId,
    required ReceiptKind kind,
    required ReceiptContext context,
    required PrinterSink send,
    String channel = '',
    String paperSize = '58mm',
    CapabilityProfile? profile,
    int copies = 1,
  }) =>
      printMany(
        orgId: orgId,
        kinds: [kind],
        context: context,
        send: send,
        channel: channel,
        paperSize: paperSize,
        profile: profile,
        copies: {kind: copies},
      );

  /// Render and print several slips in one printer session.
  ///
  /// The order given is the order printed, so a caller asking for
  /// `[token, invoice, restaurantCopy]` gets them in the order the counter
  /// hands them over. A kind with no template mapped is skipped quietly
  /// rather than failing the batch — a store with no token slip simply does
  /// not print one.
  static Future<ReceiptPrintResult> printMany({
    required String orgId,
    required List<ReceiptKind> kinds,
    required ReceiptContext context,
    required PrinterSink send,
    String channel = '',
    String paperSize = '58mm',
    CapabilityProfile? profile,
    Map<ReceiptKind, int> copies = const {},
  }) async {
    final printed = <String>[];
    final failed = <String>[];
    final warnings = <String>[];

    try {
      final chars = charsFor(paperSize);
      final size = paperSize.trim() == '80mm' ? PaperSize.mm80 : PaperSize.mm58;
      final caps = profile ?? await _profile();

      for (final kind in kinds) {
        final template =
            await ReceiptTemplateStore.resolve(orgId, kind, channel: channel);
        final layout =
            ReceiptRenderer.layout(template, context, paperChars: chars);

        for (final w in layout.warnings) {
          final line = '${template.name}: $w';
          if (!warnings.contains(line)) warnings.add(line);
        }

        if (layout.isEmpty) {
          // An empty slip is not a failure; it is a template with nothing in
          // it, and feeding blank paper helps nobody.
          continue;
        }

        final bytes =
            EscPosEncoder.encode(layout, paperSize: size, profile: caps);

        final n = (copies[kind] ?? 1).clamp(1, 5);
        for (var i = 0; i < n; i++) {
          final sent = await send(bytes);
          if (sent) {
            printed.add(template.name);
          } else {
            failed.add(template.name);
            // A printer that refused one slip will refuse the next. Stop
            // rather than queue three more failures.
            return ReceiptPrintResult(
              printed: printed,
              failed: failed,
              warnings: warnings,
            );
          }
        }
      }

      return ReceiptPrintResult(
          printed: printed, failed: failed, warnings: warnings);
    } catch (e) {
      return ReceiptPrintResult(
        printed: printed,
        failed: failed,
        warnings: warnings,
        error: e.toString(),
      );
    }
  }

  /// The same slip as text, for the share sheet and the "copy bill" action.
  ///
  /// Returns an empty string rather than throwing, for the same reason as
  /// everything else here.
  static Future<String> asText({
    required String orgId,
    required ReceiptKind kind,
    required ReceiptContext context,
    String channel = '',
    String paperSize = '58mm',
  }) async {
    try {
      final template =
          await ReceiptTemplateStore.resolve(orgId, kind, channel: channel);
      return ReceiptTextEncoder.encodeTrimmed(
        ReceiptRenderer.layout(template, context,
            paperChars: charsFor(paperSize)),
      );
    } catch (_) {
      return '';
    }
  }

  /// The layout, for the preview and the PDF.
  static Future<ReceiptLayout> layoutFor({
    required String orgId,
    required ReceiptKind kind,
    required ReceiptContext context,
    String channel = '',
    String paperSize = '58mm',
  }) async {
    final template =
        await ReceiptTemplateStore.resolve(orgId, kind, channel: channel);
    return ReceiptRenderer.layout(template, context,
        paperChars: charsFor(paperSize));
  }

  /// `'58mm'` / `'80mm'` as the printer state spells it, in character cells.
  static int charsFor(String paperSize) =>
      paperSize.trim() == '80mm' ? Paper.mm80 : Paper.mm58;
}
