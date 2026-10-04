import 'dart:io';

import 'package:employee_salary/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('employee passwords are hashed and older records remain unlocked',
      () async {
    final legacy = EmployeeRecord.fromJson({'id': 'legacy', 'name': 'Legacy'});
    expect(legacy.hasPassword, isFalse);
    expect(legacy.toJson(), {'id': 'legacy', 'name': 'Legacy'});

    final directory = await Directory.systemTemp.createTemp('salary-password-');
    try {
      final store = EmployeeStore(
        directory: Directory('${directory.path}/employees'),
      );
      final employee = await store.createEmployee('Protected');

      await store.setPassword(employee, 'secret123');

      final stored = (await store.loadEmployees()).single;
      expect(stored.hasPassword, isTrue);
      expect(stored.passwordHash, isNot('secret123'));
      expect(stored.passwordSalt, isNotEmpty);
      final employeeFile = File(
        '${directory.path}/employees/${stored.id}/employee.json',
      );
      expect(await employeeFile.readAsString(), isNot(contains('secret123')));

      await store.setPassword(stored, null);
      expect((await store.loadEmployees()).single.hasPassword, isFalse);
    } finally {
      await directory.delete(recursive: true);
    }
  });
}
