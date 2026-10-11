import 'dart:convert';
import 'dart:math';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _supabaseUrl = String.fromEnvironment('SUPABASE_URL');
const _supabasePublishableKey =
    String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
const _supabaseAnonKey = String.fromEnvironment('SUPABASE_ANON_KEY');

String get _supabaseClientKey => _supabasePublishableKey.isNotEmpty
    ? _supabasePublishableKey
    : _supabaseAnonKey;

class CloudBackend {
  static const _storage = FlutterSecureStorage();
  static const _sessionKey = 'salary.cloud.session';
  static const _deviceKey = 'salary.cloud.device';

  static bool get isConfigured =>
      _supabaseUrl.startsWith('https://') && _supabaseClientKey.isNotEmpty;

  static SupabaseClient get client => Supabase.instance.client;

  static Future<void> initialize() async {
    if (!isConfigured) return;
    await Supabase.initialize(
      url: _supabaseUrl,
      publishableKey: _supabaseClientKey,
    );
  }

  static Future<String> _deviceId() async {
    final existing = await _storage.read(key: _deviceKey);
    if (existing != null) return existing;
    final random = Random.secure();
    final id = List<int>.generate(32, (_) => random.nextInt(256))
        .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
        .join();
    await _storage.write(key: _deviceKey, value: id);
    return id;
  }

  static Future<CloudAppSession?> restoreSession() async {
    final encoded = await _storage.read(key: _sessionKey);
    if (encoded == null) return null;
    final session = CloudAppSession.fromJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
    final active = await client.rpc(
      'app_session_heartbeat',
      params: {'p_session_token': session.token},
    );
    if (active != true) {
      await clearSession();
      return null;
    }
    return session;
  }

  static Future<CloudAppSession> login({
    required String role,
    required String username,
    required String password,
  }) async {
    final response = await client.rpc(
      role == 'superadmin' ? 'superadmin_login' : 'company_login',
      params: {
        'p_username': username.trim(),
        'p_password': password,
        'p_role': role,
        'p_device_id': await _deviceId(),
      },
    );
    final result = Map<String, dynamic>.from(response as Map);
    switch (result['status']) {
      case 'invalid':
        throw const CloudLoginException(
            'اسم المستخدم أو كلمة المرور غير صحيحة');
      case 'disabled':
        throw const CloudLoginException('المؤسسة غير مفعلة');
      case 'locked':
        throw const CloudLoginException('الحساب مفتوح بالفعل على جهاز آخر');
      case 'ok':
        final session = CloudAppSession.fromJson(result);
        await _storage.write(
          key: _sessionKey,
          value: jsonEncode(session.toJson()),
        );
        return session;
      default:
        throw const CloudLoginException('تعذر إكمال تسجيل الدخول');
    }
  }

  static Future<void> heartbeat(CloudAppSession session) async {
    final active = await client.rpc(
      'app_session_heartbeat',
      params: {'p_session_token': session.token},
    );
    if (active != true) {
      await clearSession();
      throw const CloudLoginException('انتهت الجلسة، سجّل الدخول مرة أخرى');
    }
  }

  static Future<void> logout(CloudAppSession session) async {
    await client.rpc(
      'app_session_logout',
      params: {'p_session_token': session.token},
    );
    await clearSession();
  }

  static Future<void> clearSession() => _storage.delete(key: _sessionKey);
}

class CloudAppSession {
  const CloudAppSession({
    required this.token,
    required this.role,
    required this.companyId,
    required this.companyName,
    required this.username,
  });

  final String token;
  final String role;
  final String? companyId;
  final String? companyName;
  final String username;

  factory CloudAppSession.fromJson(Map<String, dynamic> json) =>
      CloudAppSession(
        token: json['session_token'] as String? ?? json['token'] as String,
        role: json['role'] as String,
        companyId: json['company_id'] as String?,
        companyName: json['company_name'] as String?,
        username: json['username'] as String,
      );

  Map<String, dynamic> toJson() => {
        'session_token': token,
        'role': role,
        'company_id': companyId,
        'company_name': companyName,
        'username': username,
      };
}

class CloudLoginException implements Exception {
  const CloudLoginException(this.message);

  final String message;

  @override
  String toString() => message;
}

class CloudDataStore {
  CloudDataStore(this.session);

  final CloudAppSession session;

  Future<List<Map<String, dynamic>>> loadEmployees() async {
    final response = await CloudBackend.client.rpc(
      'company_list_employees',
      params: {'p_session_token': session.token},
    );
    return (response as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createEmployee(String name) async {
    final response = await CloudBackend.client.rpc(
      'company_create_employee',
      params: {'p_session_token': session.token, 'p_name': name},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<List<Map<String, dynamic>>> loadMonths(String employeeId) async {
    final response = await CloudBackend.client.rpc(
      'company_list_months',
      params: {
        'p_session_token': session.token,
        'p_employee_id': employeeId,
      },
    );
    return (response as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<void> saveMonth(String employeeId, Map<String, dynamic> data) async {
    await CloudBackend.client.rpc(
      'company_save_month',
      params: {
        'p_session_token': session.token,
        'p_employee_id': employeeId,
        'p_year': data['year'],
        'p_month': data['month'],
        'p_data': data,
      },
    );
  }

  Future<void> deleteMonth(String employeeId, int year, int month) async {
    await CloudBackend.client.rpc(
      'company_delete_month',
      params: {
        'p_session_token': session.token,
        'p_employee_id': employeeId,
        'p_year': year,
        'p_month': month,
      },
    );
  }

  Future<List<Map<String, dynamic>>> listCompanies() async {
    final response = await CloudBackend.client.rpc(
      'superadmin_list_companies',
      params: {'p_session_token': session.token},
    );
    return (response as List)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
  }

  Future<Map<String, dynamic>> createCompany({
    required String name,
    required String employeeUsername,
    required String employeePassword,
    required String managerUsername,
    required String managerPassword,
  }) async {
    final response = await CloudBackend.client.rpc(
      'superadmin_create_company',
      params: {
        'p_session_token': session.token,
        'p_name': name.trim(),
        'p_employee_username': employeeUsername.trim(),
        'p_employee_password': employeePassword,
        'p_manager_username': managerUsername.trim(),
        'p_manager_password': managerPassword,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> updateCompany({
    required String companyId,
    required bool? active,
    required String employeeUsername,
    required String employeePassword,
    required String managerUsername,
    required String managerPassword,
  }) async {
    await CloudBackend.client.rpc(
      'superadmin_update_company',
      params: {
        'p_session_token': session.token,
        'p_company_id': companyId,
        'p_active': active,
        'p_employee_username': employeeUsername.trim(),
        'p_employee_password': employeePassword,
        'p_manager_username': managerUsername.trim(),
        'p_manager_password': managerPassword,
      },
    );
  }
}
