import 'dart:io';

import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

class _EmptyMonthStore extends MonthStore {
  @override
  Future<List<MonthRecord>> loadMonths() async => [];
}

class _CurrentMonthStore extends MonthStore {
  _CurrentMonthStore(this.month);

  final MonthRecord month;

  @override
  Future<List<MonthRecord>> loadMonths() async => [month];
}

class _MandatoryAttendanceModeStore extends AttendanceModeStore {
  @override
  Future<AttendanceMode> load() async => AttendanceMode.mandatory;
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

  testWidgets('employee month list applies the manager-selected mandatory mode',
      (tester) async {
    await initializeDateFormatting('ar');
    final now = DateTime.now();
    final month = MonthRecord(year: now.year, month: now.month);
    await tester.pumpWidget(
      MaterialApp(
        home: MonthsPage(
          store: _CurrentMonthStore(month),
          employeeMode: true,
          attendanceModeStore: _MandatoryAttendanceModeStore(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.text(DateFormat('MMMM yyyy', 'ar').format(now)),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining(DateFormat('d/M/yyyy', 'ar').format(now)),
      300,
    );

    expect(find.text('حضور'), findsOneWidget);
    expect(find.text('انصراف'), findsOneWidget);
  });
}
