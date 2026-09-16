/// The shape of a printed slip, as data the owner can edit.
///
/// A template is an ordered list of blocks. Rendering never reaches into the
/// app's models — it reads a [ReceiptContext] of resolved values — so the same
/// template prints on paper, previews on screen, and renders into a PDF for
/// e-mail without three layouts drifting apart.
library;

/// The four kinds of slip. A tenant can have several templates of each kind
/// and map them to order types.
enum ReceiptKind { invoice, restaurantCopy, token, kot }

extension ReceiptKindX on ReceiptKind {
  String get id => name;

  String get label {
    switch (this) {
      case ReceiptKind.invoice:
        return 'Customer bill';
      case ReceiptKind.restaurantCopy:
        return 'Restaurant copy';
      case ReceiptKind.token:
        return 'Token slip';
      case ReceiptKind.kot:
        return 'Kitchen ticket';
    }
  }

  static ReceiptKind parse(String? raw) {
    switch ((raw ?? '').trim()) {
      case 'restaurantCopy':
        return ReceiptKind.restaurantCopy;
      case 'token':
        return ReceiptKind.token;
      case 'kot':
        return ReceiptKind.kot;
      default:
        return ReceiptKind.invoice;
    }
  }
}

/// Everything a block can be. This is the whole vocabulary: if a slip cannot
/// be expressed with these, the vocabulary grows — the renderer never gains a
/// special case for one template.
enum BlockType {
  text,
  field,
  columns,
  items,
  totals,
  payments,
  divider,
  spacer,
  logo,
  qr,
  barcode,
  cut,
  raw,
}

BlockType _parseType(String? raw) => BlockType.values.firstWhere(
      (t) => t.name == (raw ?? '').trim(),
      orElse: () => BlockType.text,
    );

enum TextAlign_ { left, center, right }

/// Character-cell sizes an ESC/POS printer can do. `xl` is double width and
/// double height — what a token number wants.
enum TextSize { s, m, l, xl }

class BlockStyle {
  final TextAlign_ align;
  final TextSize size;
  final bool bold;
  final bool underline;
  final bool invert;

  const BlockStyle({
    this.align = TextAlign_.left,
    this.size = TextSize.m,
    this.bold = false,
    this.underline = false,
    this.invert = false,
  });

  /// How many character cells one glyph occupies at this size. The renderer
  /// needs it to wrap and to fit columns.
  int get widthFactor => (size == TextSize.l || size == TextSize.xl) ? 2 : 1;

  BlockStyle copyWith({
    TextAlign_? align,
    TextSize? size,
    bool? bold,
    bool? underline,
    bool? invert,
  }) =>
      BlockStyle(
        align: align ?? this.align,
        size: size ?? this.size,
        bold: bold ?? this.bold,
        underline: underline ?? this.underline,
        invert: invert ?? this.invert,
      );

  factory BlockStyle.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const BlockStyle();
    return BlockStyle(
      align: TextAlign_.values.firstWhere(
        (a) => a.name == (j['align'] ?? 'left'),
        orElse: () => TextAlign_.left,
      ),
      size: TextSize.values.firstWhere(
        (s) => s.name == (j['size'] ?? 'm'),
        orElse: () => TextSize.m,
      ),
      bold: j['bold'] == true,
      underline: j['underline'] == true,
      invert: j['invert'] == true,
    );
  }

  Map<String, dynamic> toJson() => {
        if (align != TextAlign_.left) 'align': align.name,
        if (size != TextSize.m) 'size': size.name,
        if (bold) 'bold': true,
        if (underline) 'underline': true,
        if (invert) 'invert': true,
      };
}

/// One column inside a [BlockType.columns] row.
class ColumnSpec {
  /// Share of the paper width, as a weight. Two cells of 1 and 3 split the
  /// line a quarter / three quarters.
  final int width;
  final TextAlign_ align;
  final String value;

  const ColumnSpec({required this.value, this.width = 1, this.align = TextAlign_.left});

  factory ColumnSpec.fromJson(Map<String, dynamic> j) => ColumnSpec(
        value: (j['value'] ?? '').toString(),
        width: (j['width'] is num) ? (j['width'] as num).toInt() : 1,
        align: TextAlign_.values.firstWhere(
          (a) => a.name == (j['align'] ?? 'left'),
          orElse: () => TextAlign_.left,
        ),
      );

  Map<String, dynamic> toJson() => {
        'value': value,
        if (width != 1) 'width': width,
        if (align != TextAlign_.left) 'align': align.name,
      };
}

class ReceiptBlock {
  final BlockType type;
  final BlockStyle style;

  /// Boolean expression over placeholders. Empty means always.
  final String when;

  /// Type-specific settings. Kept as a loose map so a new block option does
  /// not force a schema migration on every saved template.
  final Map<String, dynamic> props;

  const ReceiptBlock({
    required this.type,
    this.style = const BlockStyle(),
    this.when = '',
    this.props = const {},
  });

  String get value => (props['value'] ?? '').toString();
  String get label => (props['label'] ?? '').toString();

  List<ColumnSpec> get columns => ((props['cells'] as List?) ?? const [])
      .whereType<Map>()
      .map((m) => ColumnSpec.fromJson(Map<String, dynamic>.from(m)))
      .toList();

  List<String> get rows =>
      ((props['rows'] as List?) ?? const []).map((e) => e.toString()).toList();

  factory ReceiptBlock.fromJson(Map<String, dynamic> j) {
    final props = Map<String, dynamic>.from(j)
      ..remove('type')
      ..remove('style')
      ..remove('when');
    return ReceiptBlock(
      type: _parseType(j['type']?.toString()),
      style: BlockStyle.fromJson(
          j['style'] is Map ? Map<String, dynamic>.from(j['style'] as Map) : null),
      when: (j['when'] ?? '').toString(),
      props: props,
    );
  }

  Map<String, dynamic> toJson() {
    final style = this.style.toJson();
    return {
      'type': type.name,
      if (style.isNotEmpty) 'style': style,
      if (when.isNotEmpty) 'when': when,
      ...props,
    };
  }
}

/// Paper width in character cells at normal size.
class Paper {
  Paper._();
  static const int mm58 = 32;
  static const int mm80 = 48;

  static int cellsFor(String paper, {int fallback = mm58}) {
    switch (paper.trim()) {
      case '58':
      case '58mm':
        return mm58;
      case '80':
      case '80mm':
        return mm80;
      default:
        return fallback;
    }
  }
}

class ReceiptTemplate {
  /// Bumped only when a saved template needs migrating.
  final int version;
  final ReceiptKind kind;
  final String id;
  final String name;

  /// '58', '80', or 'auto' to follow the connected printer.
  final String paper;
  final List<ReceiptBlock> blocks;
  final DateTime? updatedAt;

  const ReceiptTemplate({
    required this.id,
    required this.name,
    required this.kind,
    required this.blocks,
    this.version = 1,
    this.paper = 'auto',
    this.updatedAt,
  });

  ReceiptTemplate copyWith({
    String? name,
    String? paper,
    List<ReceiptBlock>? blocks,
  }) =>
      ReceiptTemplate(
        id: id,
        name: name ?? this.name,
        kind: kind,
        blocks: blocks ?? this.blocks,
        version: version,
        paper: paper ?? this.paper,
        updatedAt: DateTime.now(),
      );

  factory ReceiptTemplate.fromJson(Map<String, dynamic> j) => ReceiptTemplate(
        id: (j['id'] ?? '').toString(),
        name: (j['name'] ?? 'Untitled').toString(),
        kind: ReceiptKindX.parse(j['kind']?.toString()),
        version: (j['version'] is num) ? (j['version'] as num).toInt() : 1,
        paper: (j['paper'] ?? 'auto').toString(),
        updatedAt: DateTime.tryParse((j['updatedAt'] ?? '').toString()),
        blocks: ((j['blocks'] as List?) ?? const [])
            .whereType<Map>()
            .map((m) => ReceiptBlock.fromJson(Map<String, dynamic>.from(m)))
            .toList(),
      );

  Map<String, dynamic> toJson() => {
        'version': version,
        'id': id,
        'name': name,
        'kind': kind.name,
        'paper': paper,
        if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
        'blocks': blocks.map((b) => b.toJson()).toList(),
      };
}
