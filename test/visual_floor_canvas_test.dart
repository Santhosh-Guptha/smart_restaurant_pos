import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_restaurant_pos/core/restaurant_models.dart';
import 'package:smart_restaurant_pos/screens/restaurant/widgets/visual_floor_canvas.dart';

void main() {
  group('VisualFloorCanvas Widget Tests', () {
    testWidgets('Renders tables on canvas with shapes and handles tap', (tester) async {
      RestaurantTable? tappedTable;

      final tables = [
        RestaurantTable(
          id: 't1',
          organizationId: 'org_1',
          tableNumber: '1',
          name: 'Table 1',
          capacity: 4,
          status: TableStatus.vacant,
          shape: 'square',
          posX: 0.2,
          posY: 0.2,
        ),
        RestaurantTable(
          id: 't2',
          organizationId: 'org_1',
          tableNumber: '2',
          name: 'Table 2',
          capacity: 6,
          status: TableStatus.occupied,
          currentBillAmount: 1450.0,
          shape: 'round',
          posX: 0.5,
          posY: 0.5,
        ),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 800,
              height: 600,
              child: VisualFloorCanvas(
                tables: tables,
                onTableTap: (t) => tappedTable = t,
              ),
            ),
          ),
        ),
      );

      expect(find.text('Table 1'), findsOneWidget);
      expect(find.text('Table 2'), findsOneWidget);
      expect(find.text('₹1450'), findsOneWidget);

      await tester.tap(find.text('Table 1'));
      expect(tappedTable?.id, 't1');
    });
  });
}
