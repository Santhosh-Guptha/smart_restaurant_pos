import 'package:flutter/material.dart';
import '../../../core/restaurant_models.dart';

/// Interactive 2D Visual Floor Plan Canvas.
///
/// Supports freeform table positioning, shape-aware rendering (square, round, rectangle),
/// live occupancy status coloring, running bill badges, and drag-and-drop designer mode.
class VisualFloorCanvas extends StatelessWidget {
  final List<RestaurantTable> tables;
  final bool isEditMode;
  final Function(RestaurantTable) onTableTap;
  final Function(RestaurantTable, double newX, double newY)? onTableMoved;

  const VisualFloorCanvas({
    super.key,
    required this.tables,
    bool isEditMode = false,
    bool? isDesignerMode,
    required this.onTableTap,
    Function(RestaurantTable, double newX, double newY)? onTableMoved,
    Function(RestaurantTable, double newX, double newY)? onTablePositionChanged,
  })  : isEditMode = isDesignerMode ?? isEditMode,
        onTableMoved = onTablePositionChanged ?? onTableMoved;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final canvasWidth = constraints.maxWidth;
        final canvasHeight = constraints.maxHeight;

        return Container(
          width: canvasWidth,
          height: canvasHeight,
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B), // Dark blueprint slate
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isEditMode ? Colors.amber.withValues(alpha: 0.6) : Colors.white12,
              width: isEditMode ? 2.0 : 1.0,
            ),
          ),
          child: Stack(
            children: [
              // 1. Grid Guidelines in Designer Mode
              if (isEditMode)
                CustomPaint(
                  size: Size(canvasWidth, canvasHeight),
                  painter: _FloorGridPainter(),
                ),

              // 2. Rendered Tables
              for (final table in tables)
                _buildPositionedTable(table, canvasWidth, canvasHeight),

              // 3. Edit Mode Banner Pill
              if (isEditMode)
                Positioned(
                  top: 14,
                  left: 14,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                    decoration: BoxDecoration(
                      color: Colors.amber.shade900.withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.amberAccent),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.touch_app, size: 16, color: Colors.white),
                        SizedBox(width: 6),
                        Text(
                          'Floor Designer Mode: Drag tables to reposition',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPositionedTable(
    RestaurantTable table,
    double canvasWidth,
    double canvasHeight,
  ) {
    // Calculate effective pixel coordinates from normalized 0.0 - 1.0 (with fallback defaults)
    final double defaultX = (table.tableNumber.hashCode % 10) * 0.08 + 0.1;
    final double defaultY = ((table.tableNumber.hashCode ~/ 10) % 8) * 0.10 + 0.15;

    final double normX = (table.posX ?? defaultX).clamp(0.05, 0.85);
    final double normY = (table.posY ?? defaultY).clamp(0.08, 0.85);

    final double left = normX * canvasWidth;
    final double top = normY * canvasHeight;

    final shape = table.shape.toLowerCase();
    final double width = table.tableWidth ?? (shape == 'rectangle' ? 130.0 : 96.0);
    final double height = table.tableHeight ?? (shape == 'rectangle' ? 85.0 : 96.0);

    return Positioned(
      left: left,
      top: top,
      child: isEditMode
          ? Draggable<RestaurantTable>(
              data: table,
              feedback: Material(
                color: Colors.transparent,
                child: _buildTableShapeWidget(table, width, height, isGhost: true),
              ),
              childWhenDragging: Opacity(
                opacity: 0.3,
                child: _buildTableShapeWidget(table, width, height),
              ),
              onDragEnd: (details) {
                if (onTableMoved != null) {
                  // Normalize coordinates back to 0.0 - 1.0
                  final newNormX = (details.offset.dx / canvasWidth).clamp(0.02, 0.88);
                  final newNormY = (details.offset.dy / canvasHeight).clamp(0.05, 0.88);
                  onTableMoved!(table, newNormX, newNormY);
                }
              },
              child: _buildTableShapeWidget(table, width, height),
            )
          : InkWell(
              onTap: () => onTableTap(table),
              borderRadius: BorderRadius.circular(shape == 'round' ? width / 2 : 12),
              child: _buildTableShapeWidget(table, width, height),
            ),
    );
  }

  Widget _buildTableShapeWidget(
    RestaurantTable table,
    double width,
    double height, {
    bool isGhost = false,
  }) {
    final statusColor = _getStatusColor(table.status);
    final shape = table.shape.toLowerCase();
    final isRound = shape == 'round';

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: isGhost ? 0.4 : 0.18),
        shape: isRound ? BoxShape.circle : BoxShape.rectangle,
        borderRadius: isRound ? null : BorderRadius.circular(12),
        border: Border.all(
          color: statusColor,
          width: table.status == TableStatus.occupied ? 2.5 : 1.5,
        ),
        boxShadow: isGhost
            ? []
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 6,
                  offset: const Offset(0, 3),
                ),
              ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _getShapeIcon(shape),
                  size: 13,
                  color: Colors.white70,
                ),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(
                    table.name.isNotEmpty ? table.name : 'T-${table.tableNumber}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '${table.capacity}p',
            style: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
          if (table.currentBillAmount > 0) ...[
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black45,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '₹${table.currentBillAmount.toStringAsFixed(0)}',
                style: const TextStyle(
                  color: Colors.amberAccent,
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  IconData _getShapeIcon(String shape) {
    switch (shape) {
      case 'round':
        return Icons.circle_outlined;
      case 'rectangle':
        return Icons.table_bar_outlined;
      default:
        return Icons.crop_square;
    }
  }

  Color _getStatusColor(TableStatus status) {
    switch (status) {
      case TableStatus.vacant:
        return Colors.greenAccent.shade400;
      case TableStatus.seated:
        return Colors.cyanAccent.shade400;
      case TableStatus.occupied:
        return Colors.amberAccent.shade400;
      case TableStatus.billed:
        return Colors.orangeAccent.shade400;
      case TableStatus.reserved:
        return Colors.purpleAccent.shade200;
      case TableStatus.cleaning:
        return Colors.blueGrey.shade400;
      case TableStatus.blocked:
        return Colors.redAccent.shade200;
    }
  }
}

class _FloorGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 1.0;

    const step = 40.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
