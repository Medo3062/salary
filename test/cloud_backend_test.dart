import 'package:employee_salary/cloud_backend.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('cloud sessions can be restored from their secure-storage shape', () {
    const session = CloudAppSession(
      token: 'opaque-token',
      role: 'manager',
      companyId: 'company-id',
      companyName: 'Test company',
      username: 'manager-login',
    );

    expect(
        CloudAppSession.fromJson(session.toJson()).toJson(), session.toJson());
  });

  test('cloud login errors expose a readable message', () {
    const error = CloudLoginException('الحساب مفتوح بالفعل على جهاز آخر');

    expect(error.toString(), 'الحساب مفتوح بالفعل على جهاز آخر');
  });
}
