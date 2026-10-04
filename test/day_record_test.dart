import 'dart:io';

import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';

class _NoopMonthStore extends MonthStore {
  @override
  Future<void> save(MonthRecord record) async {}
}

class _InMemoryAttendanceModeStore extends AttendanceModeStore {
  AttendanceMode mode = AttendanceMode.optional;

  @override
  Future<AttendanceMode> load() async => mode;

  @override
  Future<void> save(AttendanceMode mode) async {
    this.mode = mode;
  }
}

class _EmptyEmployeeStore extends EmployeeStore {
  @override
  Future<List<EmployeeRecord>> loadEmployees() async => [];
}

void main() {
  test('attendance mode defaults to optional and persists independently',
      () async {
    final directory = await Directory.systemTemp.createTemp('salary-mode-');
    try {
      final store = AttendanceModeStore(directory: directory);
      expect(await store.load(), AttendanceMode.optional);

      await store.save(AttendanceMode.mandatory);

      expect(
        await AttendanceModeStore(directory: directory).load(),
        AttendanceMode.mandatory,
      );
    } finally {
      await directory.delete(recursive: true);
    }
  });

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

  testWidgets('mandatory attendance records current time once for today', (
    tester,
  ) async {
    await initializeDateFormatting('ar');
    final now = DateTime.now();
    final month = MonthRecord(
      year: now.year,
      month: now.month,
      defaultArrival: '09:00',
      defaultDeparture: '17:00',
    );
    final store = _NoopMonthStore();
    await tester.pumpWidget(
      MaterialApp(
        home: MonthPage(
          month: month,
          store: store,
          employeeMode: true,
          attendanceMode: AttendanceMode.mandatory,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.textContaining(DateFormat('d/M/yyyy', 'ar').format(now)),
      300,
    );
    expect(find.text('حضور'), findsOneWidget);
    expect(find.text('انصراف'), findsOneWidget);
    expect(find.byType(TimePickerDialog), findsNothing);
    expect(month.defaultArrival, '09:00');
    expect(month.defaultDeparture, '17:00');
    expect(
      find.text(
        '${8 * (DateTime(now.year, now.month + 1, 0).day - 1)} ساعة',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('حضور'));
    await tester.pumpAndSettle();

    expect(
      month.days[now.day]?.arrival,
      matches(RegExp(r'^\d{2}:\d{2}$')),
    );
    expect(month.days[now.day]?.departure, isNull);
    expect(month.defaultDeparture, '17:00');
    final arrivalButton = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('حضور'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(arrivalButton.onPressed, isNull);
    expect(find.byType(TimePickerDialog), findsNothing);
  });

  testWidgets('manager can switch attendance mode for all employees', (
    tester,
  ) async {
    final modeStore = _InMemoryAttendanceModeStore();
    await tester.pumpWidget(
      MaterialApp(
        home: EmployeesPage(
          store: _EmptyEmployeeStore(),
          attendanceModeStore: modeStore,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(
      find.widgetWithText(TextButton, 'نظام الحضور والانصراف'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('نظام إجباري'));
    await tester.tap(find.text('حفظ النظام'));
    await tester.pumpAndSettle();

    expect(modeStore.mode, AttendanceMode.mandatory);
  });

  testWidgets('employee screen applies manager mode changes before recording',
      (tester) async {
    await initializeDateFormatting('ar');
    final now = DateTime.now();
    final month = MonthRecord(year: now.year, month: now.month);
    final modeStore = _InMemoryAttendanceModeStore();
    await tester.pumpWidget(
      MaterialApp(
        home: MonthPage(
          month: month,
          store: _NoopMonthStore(),
          employeeMode: true,
          attendanceModeStore: modeStore,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining(DateFormat('d/M/yyyy', 'ar').format(now)),
      300,
    );
    final todayCard = find.ancestor(
      of: find.textContaining(DateFormat('d/M/yyyy', 'ar').format(now)),
      matching: find.byType(Card),
    );

    modeStore.mode = AttendanceMode.mandatory;
    await tester.tap(
      find
          .descendant(
            of: todayCard.first,
            matching: find.text('--:--'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.text('حضور'), findsOneWidget);
    expect(find.byType(TimePickerDialog), findsNothing);

    modeStore.mode = AttendanceMode.optional;
    await tester.tap(find.text('حضور'));
    await tester.pumpAndSettle();
    expect(month.days[now.day]?.arrival, isNull);
    expect(find.text('حضور'), findsNothing);
    await tester.tap(
      find
          .descendant(
            of: todayCard.first,
            matching: find.text('--:--'),
          )
          .first,
    );
    await tester.pumpAndSettle();
    expect(find.byType(TimePickerDialog), findsOneWidget);
  });
}
