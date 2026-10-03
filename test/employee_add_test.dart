import 'dart:io';

import 'package:employee_salary/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeEmployeeStore extends EmployeeStore {
  final _employees = <EmployeeRecord>[];

  @override
  Future<List<EmployeeRecord>> loadEmployees() async => List.of(_employees);

  @override
  Future<EmployeeRecord> createEmployee(String name) async {
    final employee = EmployeeRecord(id: '${_employees.length}', name: name);
    _employees.add(employee);
    return employee;
  }
}

void main() {
  testWidgets('adding an employee closes the dialog and refreshes the list', (
    tester,
  ) async {
    final store = _FakeEmployeeStore();
    await tester.pumpWidget(
      MaterialApp(home: EmployeesPage(store: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.person_add_alt_1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'Test Employee');
    await tester.tap(find.widgetWithText(FilledButton, 'إضافة'));
    await tester.pumpAndSettle();

    expect(find.text('Test Employee'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('employee app shows employees created in the manager app', (
    tester,
  ) async {
    final store = _FakeEmployeeStore();
    await store.createEmployee('Shared Employee');

    await tester.pumpWidget(
      MaterialApp(home: EmployeeSelectionPage(store: store)),
    );
    await tester.pumpAndSettle();

    expect(find.text('تطبيق الموظفين'), findsOneWidget);
    expect(find.text('Shared Employee'), findsOneWidget);
  });

  test('manager and employee stores share employee month records', () async {
    final directory = await Directory.systemTemp.createTemp('salary-shared-');
    try {
      final managerStore = EmployeeStore(
        directory: Directory('${directory.path}/employees'),
      );
      final employeeStore = EmployeeStore(
        directory: Directory('${directory.path}/employees'),
      );

      final employee = await managerStore.createEmployee('Test Employee');
      final visibleEmployees = await employeeStore.loadEmployees();
      final managerMonths = await managerStore.monthsDirectory(employee);
      final employeeMonths = await employeeStore.monthsDirectory(
        visibleEmployees.single,
      );
      final month = MonthRecord(year: 2026, month: 10, hourlyRate: 50);

      await MonthStore(directory: managerMonths).save(month);

      expect(visibleEmployees.single.id, employee.id);
      expect(await MonthStore(directory: employeeMonths).loadMonths(), [
        isA<MonthRecord>()
            .having((record) => record.id, 'id', '2026-10')
            .having((record) => record.hourlyRate, 'hourlyRate', 50),
      ]);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
