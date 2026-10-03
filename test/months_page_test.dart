import 'dart:io';

import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _EmptyMonthStore extends MonthStore {
  @override
  Future<List<MonthRecord>> loadMonths() async => [];
}

void main() {
  test('a fresh employee month store has no months', () async {
    final directory = await Directory.systemTemp.createTemp('salary-months-');
    try {
      expect(await MonthStore(directory: directory).loadMonths(), isEmpty);
    } finally {
      await directory.delete(recursive: true);
    }
  });

  testWidgets('a fresh employee month store is empty and greets the user', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: _EmptyMonthStore(),
          userName: 'Test User',
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('مرحبًا، Test User'), findsOneWidget);
    expect(find.textContaining('مفيش شهور مضافة لسه'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('employee month list does not show the delete-month button', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: _EmptyMonthStore(),
          userName: 'Test User',
          employeeMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إضافة شهر'), findsOneWidget);
    expect(find.text('حذف شهر'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });
}
