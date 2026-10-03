import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

class _NoopMonthStore extends MonthStore {
  @override
  Future<void> save(MonthRecord record) async {}
}

void main() {
  group('DayRecord.hours', () {
    test('calculates a same-day shift to the minute', () {
      expect(
        const DayRecord(arrival: '09:15', departure: '17:45').hours,
        8.5,
      );
    });

    test('calculates a shift that ends after midnight', () {
      expect(
        const DayRecord(arrival: '22:30', departure: '06:00').hours,
        7.5,
      );
    });

    test('returns zero until both times are entered', () {
      expect(const DayRecord(arrival: '09:00').hours, 0);
      expect(const DayRecord(departure: '17:00').hours, 0);
    });

    test('returns zero for a non-working day even when times are set', () {
      expect(
        const DayRecord(
          arrival: '09:00',
          departure: '17:00',
          isWorking: false,
        ).hours,
        0,
      );
    });
  });

  test('MonthRecord preserves daily times and hourly rate in JSON', () {
    final month = MonthRecord(
      year: 2026,
      month: 10,
      hourlyRate: 50,
      vacationDays: 2,
      workDays: 22,
      defaultArrival: '09:00',
      defaultDeparture: '17:00',
      days: {
        1: const DayRecord(arrival: '10:00', departure: '17:00'),
      },
    );

    final restored = MonthRecord.fromJson(month.toJson());

    expect(restored.id, '2026-10');
    expect(restored.hourlyRate, 50);
    expect(restored.vacationDays, 2);
    expect(restored.workDays, 22);
    expect(restored.defaultArrival, '09:00');
    expect(restored.defaultDeparture, '17:00');
    expect(restored.dayRecord(1).hours, 7);
    expect(restored.dayRecord(2).hours, 8);
    expect(restored.totalHours, 247);
  });

  test('MonthRecord counts unchecked days and persists their status', () {
    final month = MonthRecord(
      year: 2026,
      month: 10,
      defaultArrival: '09:00',
      defaultDeparture: '17:00',
      days: {
        2: const DayRecord(isWorking: false),
      },
    );

    final restored = MonthRecord.fromJson(month.toJson());

    expect(restored.leaveDays, 1);
    expect(restored.dayRecord(2).hours, 0);
    expect(restored.totalHours, 240);
  });

  test('old day records remain working days by default', () {
    final restored = DayRecord.fromJson({
      'arrival': '09:00',
      'departure': '17:00',
    });

    expect(restored.isWorking, isTrue);
    expect(restored.hours, 8);
  });

  testWidgets('unchecking a day disables its times and updates totals', (
    tester,
  ) async {
    await initializeDateFormatting('ar');
    final month = MonthRecord(
      year: 2026,
      month: 10,
      defaultArrival: '09:00',
      defaultDeparture: '17:00',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MonthPage(month: month, store: _NoopMonthStore()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('248 ساعة'), findsOneWidget);
    await tester.tap(find.byType(Checkbox).first);
    await tester.pumpAndSettle();

    expect(month.leaveDays, 1);
    expect(find.text('240 ساعة'), findsOneWidget);
    expect(find.text('1 يوم'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is InputDecorator && !widget.decoration.enabled,
      ),
      findsNWidgets(2),
    );
  });

  testWidgets('employee mode hides salary settings and shows attendance totals',
      (
    tester,
  ) async {
    await initializeDateFormatting('ar');
    final month = MonthRecord(
      year: 2026,
      month: 10,
      defaultArrival: '09:00',
      defaultDeparture: '17:00',
      days: {
        2: const DayRecord(isWorking: false),
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: MonthPage(
          month: month,
          store: _NoopMonthStore(),
          employeeMode: true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('إجمالي ساعات الشهر'), findsOneWidget);
    expect(find.text('240 ساعة'), findsOneWidget);
    expect(find.text('أيام الإجازة'), findsOneWidget);
    expect(find.text('1 يوم'), findsOneWidget);
    expect(find.text('سعر الساعة'), findsNothing);
    expect(find.text('أيام العمل'), findsNothing);
    expect(find.text('إجمالي المرتب'), findsNothing);
    expect(find.text('مواعيد افتراضية للشهر'), findsNothing);
    expect(find.byType(TextField), findsNothing);
  });
}
