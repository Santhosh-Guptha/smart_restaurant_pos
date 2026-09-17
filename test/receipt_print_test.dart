import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:smart_restaurant_pos/core/receipt/printer_layout_migration.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_context.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_print_service.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_renderer.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_store.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_template.dart';
import 'package:smart_restaurant_pos/core/receipt/receipt_text_encoder.dart';
import 'package:smart_restaurant_pos/core/receipt/starter_templates.dart';

/// R6: the printer settings carried forward, and one way to print.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  const org = 'ORG_PRINT';

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('receipt_print_test');
    Hive.init(dir.path);
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await Hive.deleteBoxFromDisk(ReceiptTemplateStore.boxNameFor(org));
  });

  String render(ReceiptTemplate t) => ReceiptTextEncoder.encode(
      ReceiptRenderer.layout(t, ReceiptContext.sample()));

  group('carrying the printer settings forward', () {
    test('a store on the defaults is left completely alone', () async {
      final migrated = await PrinterLayoutMigration.run(orgId: org);
      expect(migrated, isNull);

      await ReceiptTemplateStore.ensureSeeded(org);
      final invoice = await ReceiptTemplateStore.byId(
          org, StarterTemplates.invoiceClassicId);
      // Untouched, so the slip it prints is the one the golden test pins.
      expect(invoice?.blocks.length,
          StarterTemplates.classicInvoice.blocks.length);
    });

    test('it runs once, not on every launch', () async {
      final first =
          await PrinterLayoutMigration.run(orgId: org, customHeader: 'WELCOME');
      expect(first, isNotNull);

      final second = await PrinterLayoutMigration.run(
          orgId: org, customHeader: 'SOMETHING ELSE');
      expect(second, isNull, reason: 'a second launch must not rewrite a '
          'template the owner may have edited since');

      final stored = await ReceiptTemplateStore.byId(
          org, StarterTemplates.invoiceClassicId);
      expect(render(stored!), contains('WELCOME'));
      expect(render(stored), isNot(contains('SOMETHING ELSE')));
    });

    test('the header the owner typed still prints', () {
      final t = PrinterLayoutMigration.apply(
          StarterTemplates.classicInvoice, customHeader: 'FAMILY RESTAURANT');
      final out = render(t);
      expect(out, contains('FAMILY RESTAURANT'));
      expect(out.indexOf('FAMILY RESTAURANT'),
          lessThan(out.indexOf('SPICE GARDEN')),
          reason: 'the header sits above the store name, where it was');
    });

    test('the note the owner typed still prints, near the end', () {
      final t = PrinterLayoutMigration.apply(
          StarterTemplates.classicInvoice, customNotes: 'GST paid on all items');
      final out = render(t);
      expect(out, contains('GST paid on all items'));
      expect(out.indexOf('GST paid on all items'),
          greaterThan(out.indexOf('TOTAL AMOUNT:')));
    });

    test('switching tax off removes the tax rows and nothing else', () {
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice,
          showGst: false);
      final out = render(t);
      expect(out, isNot(contains('CGST')));
      expect(out, isNot(contains('SGST')));
      expect(out, contains('Subtotal:'));
      expect(out, contains('TOTAL AMOUNT:'));
    });

    test('switching the discount off removes only the discount row', () {
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice,
          showDiscount: false);
      final ctx = ReceiptContext.sample()..values['bill.discount'] = 4000;
      final out =
          ReceiptTextEncoder.encode(ReceiptRenderer.layout(t, ctx));
      expect(out, isNot(contains('Discount:')));
      expect(out, contains('CGST'));
    });

    test('the feed lines the owner chose are used', () {
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice,
          feedLines: 6);
      final spacers =
          t.blocks.where((b) => b.type == BlockType.spacer).toList();
      expect(spacers.last.props['lines'], 6);
    });

    test('the invoice prefix goes back on the bill number', () {
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice,
          invoicePrefix: 'SG/');
      // The identifiers column is 19 cells on 58 mm paper, so a longer bill
      // number is clipped there \u2014 as it always was.
      expect(render(t), contains('BILL NO: SG/INV-000'));
    });

    test('the default prefix changes nothing', () {
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice,
          invoicePrefix: 'INV-');
      expect(render(t), contains('BILL NO: INV-000412'));
    });

    test("customer lines are not added behind the owner's back", () {
      // showCustomer defaults to true on PrinterState, but only the order
      // history generator ever honoured it. Migrating that default would start
      // printing guests' phone numbers on every slip.
      expect(PrinterLayoutMigration.hasCustomisation(), isFalse);
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice);
      final ctx = ReceiptContext.sample();
      final out = ReceiptTextEncoder.encode(ReceiptRenderer.layout(t, ctx));
      expect(out, isNot(contains('CUSTOMER')));
    });

    test('but they can be asked for', () {
      final t = PrinterLayoutMigration.apply(StarterTemplates.classicInvoice,
          showCustomer: true);
      final out = render(t);
      expect(out, contains('CUSTOMER'));
      expect(out, contains('Ravi'));
    });

    test('several settings at once all survive together', () {
      final t = PrinterLayoutMigration.apply(
        StarterTemplates.classicInvoice,
        customHeader: 'WELCOME',
        customNotes: 'Taxes included',
        showGst: false,
        feedLines: 5,
        invoicePrefix: 'SG/',
        boldItems: true,
      );
      final out = render(t);
      expect(out, contains('WELCOME'));
      expect(out, contains('Taxes included'));
      expect(out, isNot(contains('CGST')));
      expect(out, contains('BILL NO: SG/'));
      expect(
          t.blocks
              .firstWhere((b) => b.type == BlockType.items)
              .style
              .bold,
          isTrue);
    });
  });

  group('printing', () {
    test('a bill reaches the printer once', () async {
      final sent = <List<int>>[];
      final result = await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
        send: (bytes) async {
          sent.add(bytes);
          return true;
        },
      );
      expect(result.ok, isTrue);
      expect(sent.length, 1);
      expect(sent.first, isNotEmpty);
      expect(result.printed.single, StarterTemplates.classicInvoice.name);
    });

    test('several slips go out in the order asked for', () async {
      final names = <String>[];
      final result = await ReceiptPrintService.printMany(
        orgId: org,
        kinds: const [
          ReceiptKind.token,
          ReceiptKind.invoice,
          ReceiptKind.restaurantCopy,
        ],
        context: ReceiptContext.sample(),
        send: (_) async => true,
      );
      names.addAll(result.printed);
      expect(names.length, 3);
      expect(names.first, StarterTemplates.largeToken.name);
      expect(names[1], StarterTemplates.classicInvoice.name);
    });

    test('a refused slip stops the batch instead of piling up failures',
        () async {
      var calls = 0;
      final result = await ReceiptPrintService.printMany(
        orgId: org,
        kinds: const [
          ReceiptKind.token,
          ReceiptKind.invoice,
          ReceiptKind.restaurantCopy,
        ],
        context: ReceiptContext.sample(),
        send: (_) async {
          calls++;
          return false;
        },
      );
      expect(calls, 1);
      expect(result.ok, isFalse);
      expect(result.failed.length, 1);
      expect(result.printed, isEmpty);
    });

    test('a printer that throws comes back as a result, not an exception',
        () async {
      final result = await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
        send: (_) async => throw StateError('bluetooth asleep'),
      );
      expect(result.error, isNotNull);
      expect(result.ok, isFalse);
    });

    test('extra copies are sent, and capped', () async {
      var calls = 0;
      await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
        copies: 3,
        send: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 3);

      calls = 0;
      await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
        copies: 99,
        send: (_) async {
          calls++;
          return true;
        },
      );
      expect(calls, 5, reason: 'nobody meant to print ninety-nine bills');
    });

    test('the mapped template is the one that prints', () async {
      await ReceiptTemplateStore.setMapping(org, ReceiptKind.invoice,
          'Takeaway', StarterTemplates.invoiceCompactId);
      final result = await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        channel: 'Takeaway',
        context: ReceiptContext.sample(),
        send: (_) async => true,
      );
      expect(result.printed.single, StarterTemplates.compactInvoice.name);
    });

    test('80 mm paper produces different bytes from 58 mm', () async {
      List<int>? narrow;
      List<int>? wide;
      await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
        send: (b) async {
          narrow = b;
          return true;
        },
      );
      await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
        paperSize: '80mm',
        send: (b) async {
          wide = b;
          return true;
        },
      );
      expect(narrow, isNotNull);
      expect(wide, isNotNull);
      expect(wide!.length == narrow!.length && wide.toString() == narrow.toString(),
          isFalse);
    });

    test('a broken template is reported, not swallowed', () async {
      const broken = ReceiptTemplate(
        id: 'broken_invoice',
        name: 'Broken',
        kind: ReceiptKind.invoice,
        blocks: [
          ReceiptBlock(type: BlockType.text, props: {'value': '{{nope.at.all}}X'}),
        ],
      );
      await ReceiptTemplateStore.save(org, broken);
      await ReceiptTemplateStore.setMapping(
          org, ReceiptKind.invoice, 'Dine-In', 'broken_invoice');

      final result = await ReceiptPrintService.printOne(
        orgId: org,
        kind: ReceiptKind.invoice,
        channel: 'Dine-In',
        context: ReceiptContext.sample(),
        send: (_) async => true,
      );
      expect(result.warnings.any((w) => w.contains('nope.at.all')), isTrue);
      expect(result.ok, isTrue, reason: 'a warning is not a reason to refuse '
          'to print the bill');
    });

    test('the text version reads like the slip', () async {
      final text = await ReceiptPrintService.asText(
        orgId: org,
        kind: ReceiptKind.invoice,
        context: ReceiptContext.sample(),
      );
      expect(text, contains('SPICE GARDEN'));
      expect(text, contains('TOTAL AMOUNT:'));
      expect(text.split('\n').every((l) => l.length <= 32), isTrue);
    });

    test('paper sizes map to the right width', () {
      expect(ReceiptPrintService.charsFor('58mm'), Paper.mm58);
      expect(ReceiptPrintService.charsFor('80mm'), Paper.mm80);
      expect(ReceiptPrintService.charsFor('anything else'), Paper.mm58);
    });
  });
}
