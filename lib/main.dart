import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

const _appDescription =
    'تطبيق ذكي يساعدك على إدارة رواتب الموظفين بسهولة يقوم بحساب ساعات العمل من خلال الحضور و الانصرف و يحدد إجمالي ساعات العمل الشهرية بدقة و يقوم بضرب ساعات العمل في قيمة الساعة لتحديد صافي الراتب.';
const _buildRole = String.fromEnvironment('APP_ROLE', defaultValue: 'combined');

AppRole? get _fixedRole => switch (_buildRole) {
      'employee' => AppRole.employee,
      'manager' => AppRole.manager,
      'combined' => null,
      _ => throw StateError('APP_ROLE must be employee, manager, or combined'),
    };

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting('ar');
  runApp(SalaryApp(fixedRole: _fixedRole));
}

class SalaryApp extends StatelessWidget {
  const SalaryApp({this.fixedRole, super.key});

  final AppRole? fixedRole;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: switch (fixedRole) {
        AppRole.employee => 'salary - الموظف',
        AppRole.manager => 'salary - المدير',
        null => 'salary',
      },
      debugShowCheckedModeBanner: false,
      locale: const Locale('ar'),
      supportedLocales: const [Locale('ar'), Locale('en')],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF176B5B),
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          isDense: true,
        ),
      ),
      home: RoleGate(fixedRole: fixedRole),
    );
  }
}

enum AppRole { employee, manager }

class SharedSalaryDirectory {
  static Future<Directory> get() async {
    final documents = await getApplicationDocumentsDirectory();
    final directory = Directory('${documents.path}/salary_shared_data');
    await directory.create(recursive: true);
    return directory;
  }
}

enum AttendanceMode { optional, mandatory }

class AttendanceModeStore {
  AttendanceModeStore({this.directory});

  final Directory? directory;

  Future<File> _settingsFile() async {
    final customDirectory = directory;
    if (customDirectory != null) {
      await customDirectory.create(recursive: true);
      return File('${customDirectory.path}/attendance_mode.json');
    }
    final sharedDirectory = await SharedSalaryDirectory.get();
    final settingsDirectory = Directory('${sharedDirectory.path}/settings');
    await settingsDirectory.create(recursive: true);
    return File('${settingsDirectory.path}/attendance_mode.json');
  }

  Future<AttendanceMode> load() async {
    final file = await _settingsFile();
    if (!await file.exists()) return AttendanceMode.optional;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid attendance mode setting');
    }
    final json = decoded;
    return switch (json['mode']) {
      'optional' => AttendanceMode.optional,
      'mandatory' => AttendanceMode.mandatory,
      _ => throw const FormatException('Invalid attendance mode setting'),
    };
  }

  Future<void> save(AttendanceMode mode) async {
    final file = await _settingsFile();
    await file.writeAsString(
      jsonEncode({'mode': mode.name}),
      flush: true,
    );
  }
}

class AppSettingsStore {
  AppSettingsStore({this.role, this.shared = false});

  final AppRole? role;
  final bool shared;

  Future<File> _settingsFile() async {
    if (shared) {
      final directory = await SharedSalaryDirectory.get();
      final settings = Directory('${directory.path}/settings');
      await settings.create(recursive: true);
      return File('${settings.path}/${role!.name}_settings.json');
    }
    final documents = await getApplicationDocumentsDirectory();
    return File('${documents.path}/app_settings.json');
  }

  Future<AppSettings?> loadSettings() async {
    final file = await _settingsFile();
    if (!await file.exists()) return null;
    final decoded =
        jsonDecode(await file.readAsString()) as Map<String, dynamic>;
    final role = switch (decoded['role']) {
      'employee' => AppRole.employee,
      'manager' => AppRole.manager,
      _ => null,
    };
    if (role == null || (this.role != null && role != this.role)) return null;
    return AppSettings(
      role: role,
      name: (decoded['name'] as String?)?.trim(),
      passwordSalt: decoded['passwordSalt'] as String?,
      passwordHash: decoded['passwordHash'] as String?,
    );
  }

  Future<void> saveSettings(
    AppRole role,
    String name, {
    String? passwordSalt,
    String? passwordHash,
  }) async {
    final file = await _settingsFile();
    await file.writeAsString(
      jsonEncode({
        'role': role.name,
        'name': name,
        if (passwordSalt != null) 'passwordSalt': passwordSalt,
        if (passwordHash != null) 'passwordHash': passwordHash,
      }),
      flush: true,
    );
  }
}

class AppSettings {
  const AppSettings({
    required this.role,
    required this.name,
    this.passwordSalt,
    this.passwordHash,
  });

  final AppRole role;
  final String? name;
  final String? passwordSalt;
  final String? passwordHash;

  bool get hasPassword => passwordSalt != null && passwordHash != null;
}

class _PasswordCredential {
  const _PasswordCredential({required this.salt, required this.hash});

  final String salt;
  final String hash;
}

Future<_PasswordCredential> _createPasswordCredential(String password) async {
  final random = Random.secure();
  final salt = List<int>.generate(16, (_) => random.nextInt(256));
  final saltHex =
      salt.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  final hash = await compute(_derivePasswordHash, [password, saltHex]);
  return _PasswordCredential(salt: saltHex, hash: hash);
}

Future<bool> _verifyPassword(
  String password,
  String salt,
  String expectedHash,
) async {
  final actualHash = await compute(_derivePasswordHash, [password, salt]);
  if (actualHash.length != expectedHash.length) return false;
  var difference = 0;
  for (var index = 0; index < actualHash.length; index++) {
    difference |= actualHash.codeUnitAt(index) ^ expectedHash.codeUnitAt(index);
  }
  return difference == 0;
}

String _derivePasswordHash(List<String> parameters) {
  final password = utf8.encode(parameters[0]);
  final salt = <int>[];
  final saltHex = parameters[1];
  for (var index = 0; index < saltHex.length; index += 2) {
    salt.add(int.parse(saltHex.substring(index, index + 2), radix: 16));
  }
  final hmac = Hmac(sha256, password);
  final block = [...salt, 0, 0, 0, 1];
  var value = hmac.convert(block).bytes;
  final result = List<int>.of(value);
  for (var iteration = 1; iteration < 120000; iteration++) {
    value = hmac.convert(value).bytes;
    for (var index = 0; index < result.length; index++) {
      result[index] ^= value[index];
    }
  }
  return result.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

class RoleGate extends StatefulWidget {
  const RoleGate({this.fixedRole, super.key});

  final AppRole? fixedRole;

  @override
  State<RoleGate> createState() => _RoleGateState();
}

class _RoleGateState extends State<RoleGate> {
  late final AppSettingsStore _settings;
  late Future<AppSettings?> _settingsFuture;
  bool _promptingForName = false;
  bool _promptingForPassword = false;
  bool _managerUnlocked = false;
  String? _managerPasswordSetupError;

  @override
  void initState() {
    super.initState();
    _settings = AppSettingsStore(
      role: widget.fixedRole,
      shared: widget.fixedRole != null,
    );
    _settingsFuture = widget.fixedRole == AppRole.employee
        ? Future.value(null)
        : _settings.loadSettings();
  }

  Future<void> _selectRole(AppRole role) async {
    final name = await _requestName();
    if (name == null) return;
    final credential = role == AppRole.manager
        ? await _requestPassword(
            title: 'إنشاء كلمة مرور المدير',
            confirmPassword: true,
            allowCancel: false,
          )
        : null;
    if (role == AppRole.manager && credential == null) return;
    final password = credential == null
        ? null
        : await _createPasswordCredential(credential.password!);
    await _settings.saveSettings(
      role,
      name,
      passwordSalt: password?.salt,
      passwordHash: password?.hash,
    );
    if (mounted) {
      setState(() {
        _managerUnlocked = role == AppRole.manager;
        _settingsFuture = Future.value(
          AppSettings(
            role: role,
            name: name,
            passwordSalt: password?.salt,
            passwordHash: password?.hash,
          ),
        );
      });
    }
  }

  Future<String?> _requestName() => showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const _UserNameDialog(),
      );

  Future<_PasswordDialogResult?> _requestPassword({
    required String title,
    bool confirmPassword = false,
    bool requireOldPassword = false,
    bool allowCancel = true,
    String? oldPasswordSalt,
    String? oldPasswordHash,
  }) =>
      showDialog<_PasswordDialogResult>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _PasswordDialog(
          title: title,
          confirmPassword: confirmPassword,
          requireOldPassword: requireOldPassword,
          allowCancel: allowCancel,
          oldPasswordSalt: oldPasswordSalt,
          oldPasswordHash: oldPasswordHash,
        ),
      );

  Future<void> _requestMissingManagerPassword(AppSettings settings) async {
    if (_promptingForPassword) return;
    _promptingForPassword = true;
    _managerPasswordSetupError = null;
    final result = await _requestPassword(
      title: 'إنشاء كلمة مرور المدير',
      confirmPassword: true,
      allowCancel: false,
    );
    if (result != null && mounted) {
      try {
        final password = await _createPasswordCredential(result.password!);
        await _settings.saveSettings(
          AppRole.manager,
          settings.name!,
          passwordSalt: password.salt,
          passwordHash: password.hash,
        );
        if (mounted) {
          setState(() {
            _managerUnlocked = true;
            _settingsFuture = Future.value(
              AppSettings(
                role: AppRole.manager,
                name: settings.name,
                passwordSalt: password.salt,
                passwordHash: password.hash,
              ),
            );
          });
        }
      } on FileSystemException catch (error) {
        if (mounted) {
          setState(() {
            _managerPasswordSetupError =
                'تعذر حفظ كلمة المرور: ${error.message}';
          });
        }
      }
    }
    _promptingForPassword = false;
  }

  Future<bool> _unlockManager(AppSettings settings, String password) async {
    final valid = await _verifyPassword(
      password,
      settings.passwordSalt!,
      settings.passwordHash!,
    );
    if (valid && mounted) setState(() => _managerUnlocked = true);
    return valid;
  }

  Future<void> _changeManagerPassword(AppSettings settings) async {
    final result = await _requestPassword(
      title: 'تعديل كلمة مرور المدير',
      confirmPassword: true,
      requireOldPassword: true,
      oldPasswordSalt: settings.passwordSalt,
      oldPasswordHash: settings.passwordHash,
    );
    if (result == null || !mounted) return;
    try {
      final password = await _createPasswordCredential(result.password!);
      await _settings.saveSettings(
        AppRole.manager,
        settings.name!,
        passwordSalt: password.salt,
        passwordHash: password.hash,
      );
      if (!mounted) return;
      setState(() {
        _settingsFuture = Future.value(
          AppSettings(
            role: AppRole.manager,
            name: settings.name,
            passwordSalt: password.salt,
            passwordHash: password.hash,
          ),
        );
      });
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('تم تعديل كلمة المرور')));
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ كلمة المرور: ${error.message}')),
        );
      }
    }
  }

  void _requestMissingName(AppRole role) {
    if (_promptingForName) return;
    _promptingForName = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final name = await _requestName();
      if (name != null) {
        try {
          final credential = role == AppRole.manager
              ? await _requestPassword(
                  title: 'إنشاء كلمة مرور المدير',
                  confirmPassword: true,
                )
              : null;
          if (role == AppRole.manager && credential == null) {
            _promptingForName = false;
            return;
          }
          final password = credential == null
              ? null
              : await _createPasswordCredential(credential.password!);
          await _settings.saveSettings(
            role,
            name,
            passwordSalt: password?.salt,
            passwordHash: password?.hash,
          );
          if (mounted) {
            setState(() {
              _settingsFuture = Future.value(
                AppSettings(
                  role: role,
                  name: name,
                  passwordSalt: password?.salt,
                  passwordHash: password?.hash,
                ),
              );
              _managerUnlocked = role == AppRole.manager;
            });
          }
        } on FileSystemException catch (error) {
          if (mounted) {
            setState(() => _settingsFuture = Future.value(null));
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('تعذر حفظ الاسم: ${error.message}')),
            );
          }
        }
      }
      _promptingForName = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fixedRole == AppRole.employee) {
      return EmployeeSelectionPage(
        store: EmployeeStore(shared: true),
        attendanceModeStore: AttendanceModeStore(),
      );
    }
    return FutureBuilder<AppSettings?>(
      future: _settingsFuture,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Scaffold(
            body: Center(child: Text('تعذر تحميل إعدادات التطبيق')),
          );
        }
        if (!snapshot.hasData &&
            snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final settings = snapshot.data;
        if (settings != null) {
          final role = settings.role;
          final name = settings.name;
          if (name == null || name.isEmpty) {
            _requestMissingName(role);
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          if (role == AppRole.manager) {
            if (!settings.hasPassword) {
              final setupError = _managerPasswordSetupError;
              if (setupError != null) {
                return Scaffold(
                  body: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            setupError,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                          const SizedBox(height: 16),
                          FilledButton(
                            onPressed: () {
                              setState(() => _managerPasswordSetupError = null);
                              _requestMissingManagerPassword(settings);
                            },
                            child: const Text('إعادة المحاولة'),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }
              _requestMissingManagerPassword(settings);
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }
            if (!_managerUnlocked) {
              return _ManagerLoginPage(
                onSubmit: (password) => _unlockManager(settings, password),
              );
            }
            return EmployeesPage(
              store: widget.fixedRole == AppRole.manager
                  ? EmployeeStore(shared: true)
                  : null,
              userName: name,
              onChangePassword: () => _changeManagerPassword(settings),
              attendanceModeStore: AttendanceModeStore(),
            );
          }
          if (role == AppRole.employee) return MonthsPage(userName: name);
        }
        return RoleSelectionPage(
          fixedRole: widget.fixedRole,
          onSelectRole: _selectRole,
        );
      },
    );
  }
}

class _UserNameDialog extends StatefulWidget {
  const _UserNameDialog();

  @override
  State<_UserNameDialog> createState() => _UserNameDialogState();
}

class _UserNameDialogState extends State<_UserNameDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_nameController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('من فضلك أدخل اسمك'),
        content: Form(
          key: _formKey,
          child: TextFormField(
            controller: _nameController,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'الاسم'),
            validator: (value) => value == null || value.trim().isEmpty
                ? 'اكتب اسمك للمتابعة'
                : null,
            onFieldSubmitted: (_) => _submit(),
          ),
        ),
        actions: [
          FilledButton(onPressed: _submit, child: const Text('متابعة')),
        ],
      ),
    );
  }
}

class _PasswordDialogResult {
  const _PasswordDialogResult(this.password, {this.remove = false});

  final String? password;
  final bool remove;
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({
    required this.title,
    this.confirmPassword = false,
    this.requireOldPassword = false,
    this.removePassword = false,
    this.allowCancel = true,
    this.oldPasswordSalt,
    this.oldPasswordHash,
  });

  final String title;
  final bool confirmPassword;
  final bool requireOldPassword;
  final bool removePassword;
  final bool allowCancel;
  final String? oldPasswordSalt;
  final String? oldPasswordHash;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _oldPasswordController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmationController = TextEditingController();
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _passwordController.dispose();
    _confirmationController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    if (widget.requireOldPassword &&
        !await _verifyPassword(
          _oldPasswordController.text,
          widget.oldPasswordSalt!,
          widget.oldPasswordHash!,
        )) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'كلمة المرور القديمة غير صحيحة';
        });
      }
      return;
    }
    if (widget.removePassword) {
      if (mounted) {
        Navigator.of(context)
            .pop(const _PasswordDialogResult(null, remove: true));
      }
      return;
    }
    if (mounted) {
      Navigator.of(context)
          .pop(_PasswordDialogResult(_passwordController.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: widget.allowCancel,
      child: AlertDialog(
        title: Text(widget.title),
        content: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.requireOldPassword) ...[
                TextFormField(
                  controller: _oldPasswordController,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور القديمة',
                  ),
                  validator: (value) => value == null || value.isEmpty
                      ? 'اكتب كلمة المرور القديمة'
                      : null,
                ),
                const SizedBox(height: 12),
              ],
              if (!widget.removePassword)
                TextFormField(
                  controller: _passwordController,
                  autofocus: !widget.requireOldPassword,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور الجديدة',
                  ),
                  validator: (value) => value == null || value.length < 4
                      ? 'كلمة المرور لازم تكون ٤ أحرف على الأقل'
                      : null,
                  onFieldSubmitted: (_) {
                    if (widget.confirmPassword) _submit();
                  },
                ),
              if (widget.confirmPassword && !widget.removePassword) ...[
                const SizedBox(height: 12),
                TextFormField(
                  controller: _confirmationController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'تأكيد كلمة المرور الجديدة',
                  ),
                  validator: (value) => value != _passwordController.text
                      ? 'كلمة المرور غير متطابقة'
                      : null,
                  onFieldSubmitted: (_) => _submit(),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
        actions: [
          if (widget.allowCancel)
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('إلغاء'),
            ),
          FilledButton(
            onPressed: _saving ? null : _submit,
            child: Text(_saving ? 'جارٍ الحفظ...' : 'حفظ'),
          ),
        ],
      ),
    );
  }
}

class _ManagerLoginPage extends StatefulWidget {
  const _ManagerLoginPage({required this.onSubmit});

  final Future<bool> Function(String password) onSubmit;

  @override
  State<_ManagerLoginPage> createState() => _ManagerLoginPageState();
}

class _ManagerLoginPageState extends State<_ManagerLoginPage> {
  final _passwordController = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_passwordController.text.isEmpty) {
      setState(() => _error = 'اكتب كلمة المرور');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final valid = await widget.onSubmit(_passwordController.text);
    if (!mounted) return;
    if (!valid) {
      setState(() {
        _checking = false;
        _error = 'كلمة المرور غير صحيحة';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('تسجيل دخول المدير')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: _passwordController,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'كلمة المرور',
                    prefixIcon: Icon(Icons.lock_outline),
                  ),
                  onFieldSubmitted: (_) => _submit(),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _checking ? null : _submit,
                    child: Text(_checking ? 'جارٍ التحقق...' : 'دخول'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RoleSelectionPage extends StatefulWidget {
  const RoleSelectionPage({
    required this.onSelectRole,
    this.fixedRole,
    super.key,
  });

  final Future<void> Function(AppRole role) onSelectRole;
  final AppRole? fixedRole;

  @override
  State<RoleSelectionPage> createState() => _RoleSelectionPageState();
}

class _RoleSelectionPageState extends State<RoleSelectionPage> {
  bool _saving = false;
  String? _error;

  Future<void> _selectRole(AppRole role) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSelectRole(role);
    } on FileSystemException catch (error) {
      if (mounted) {
        setState(() => _error = 'تعذر حفظ الاختيار: ${error.message}');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('salary')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.badge_outlined, size: 64),
              const SizedBox(height: 16),
              Text(
                widget.fixedRole == AppRole.manager
                    ? 'تسجيل دخول المدير'
                    : 'اختار طريقة الاستخدام',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 20),
              if (widget.fixedRole != AppRole.manager)
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed:
                        _saving ? null : () => _selectRole(AppRole.employee),
                    icon: const Icon(Icons.person_outline),
                    label: const Text('استخدام موظف'),
                  ),
                ),
              if (widget.fixedRole != AppRole.manager)
                const SizedBox(height: 12),
              if (widget.fixedRole != AppRole.employee)
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed:
                        _saving ? null : () => _selectRole(AppRole.manager),
                    icon: const Icon(Icons.manage_accounts_outlined),
                    label: Text(
                      widget.fixedRole == AppRole.manager
                          ? 'متابعة كمدير'
                          : 'استخدام مدير',
                    ),
                  ),
                ),
              if (_saving) ...[
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class EmployeeRecord {
  const EmployeeRecord({
    required this.id,
    required this.name,
    this.passwordSalt,
    this.passwordHash,
  });

  final String id;
  final String name;
  final String? passwordSalt;
  final String? passwordHash;

  bool get hasPassword => passwordSalt != null && passwordHash != null;

  EmployeeRecord withPassword({String? salt, String? hash}) => EmployeeRecord(
        id: id,
        name: name,
        passwordSalt: salt,
        passwordHash: hash,
      );

  factory EmployeeRecord.fromJson(Map<String, dynamic> json) => EmployeeRecord(
        id: json['id'] as String,
        name: json['name'] as String,
        passwordSalt: json['passwordSalt'] as String?,
        passwordHash: json['passwordHash'] as String?,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        if (passwordSalt != null) 'passwordSalt': passwordSalt,
        if (passwordHash != null) 'passwordHash': passwordHash,
      };
}

Widget _homeAppBarTitle(String? userName, {String appTitle = 'salary'}) {
  final greeting =
      userName == null || userName.isEmpty ? 'مرحبًا' : 'مرحبًا، $userName';
  return Row(
    children: [
      Expanded(
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(appTitle, style: TextStyle(fontSize: 16)),
        ),
      ),
      Expanded(
        flex: 2,
        child: Center(
          child: Text(
            greeting,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14),
          ),
        ),
      ),
      const Expanded(
        child: Align(
          alignment: AlignmentDirectional.centerEnd,
          child: Text(
            'Made by Moro',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.grey,
              fontSize: 10,
              fontStyle: FontStyle.italic,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ],
  );
}

class EmployeeStore {
  EmployeeStore({this.directory, this.shared = false});

  final Directory? directory;
  final bool shared;

  Future<Directory> _employeesDirectory() async {
    final customDirectory = directory;
    if (customDirectory != null) {
      await customDirectory.create(recursive: true);
      return customDirectory;
    }
    if (shared) {
      final root = await SharedSalaryDirectory.get();
      final employees = Directory('${root.path}/employees');
      await employees.create(recursive: true);
      return employees;
    }
    final documents = await getApplicationDocumentsDirectory();
    final employeeDirectory = Directory('${documents.path}/employees');
    await employeeDirectory.create(recursive: true);
    return employeeDirectory;
  }

  Future<List<EmployeeRecord>> loadEmployees() async {
    final root = await _employeesDirectory();
    final entities = await root.list(followLinks: false).toList();
    final employees = <EmployeeRecord>[];
    for (final entity in entities.whereType<Directory>()) {
      final file = File('${entity.path}/employee.json');
      if (!await file.exists()) continue;
      final decoded = jsonDecode(await file.readAsString());
      employees.add(EmployeeRecord.fromJson(decoded as Map<String, dynamic>));
    }
    employees.sort(
      (first, second) =>
          first.name.toLowerCase().compareTo(second.name.toLowerCase()),
    );
    return employees;
  }

  Future<EmployeeRecord> createEmployee(String name) async {
    final normalizedName = name.trim();
    if (normalizedName.isEmpty) {
      throw ArgumentError.value(name, 'name', 'Employee name is required');
    }
    final root = await _employeesDirectory();
    final safeName = Uri.encodeComponent(normalizedName)
        .replaceAll('.', '%2E')
        .replaceAll(RegExp(r'[^A-Za-z0-9_%\-]'), '_');
    final id = '$safeName-${DateTime.now().microsecondsSinceEpoch}';
    final employee = EmployeeRecord(id: id, name: normalizedName);
    final directory = Directory('${root.path}/$id');
    await directory.create(recursive: true);
    await File('${directory.path}/employee.json')
        .writeAsString(jsonEncode(employee.toJson()), flush: true);
    await Directory('${directory.path}/months').create(recursive: true);
    return employee;
  }

  Future<void> setPassword(EmployeeRecord employee, String? password) async {
    if (!RegExp(r'^[A-Za-z0-9_%\-]+$').hasMatch(employee.id)) {
      throw ArgumentError.value(
        employee.id,
        'employee.id',
        'Invalid employee ID',
      );
    }
    final current = employee.hasPassword
        ? employee
        : EmployeeRecord(id: employee.id, name: employee.name);
    final updated = password == null
        ? current.withPassword()
        : await _createPasswordCredential(password).then(
            (credential) => current.withPassword(
              salt: credential.salt,
              hash: credential.hash,
            ),
          );
    final root = await _employeesDirectory();
    final file = File('${root.path}/${employee.id}/employee.json');
    await file.writeAsString(jsonEncode(updated.toJson()), flush: true);
  }

  Future<void> deleteEmployee(EmployeeRecord employee) async {
    if (!RegExp(r'^[A-Za-z0-9_%\-]+$').hasMatch(employee.id)) {
      throw ArgumentError.value(
        employee.id,
        'employee.id',
        'Invalid employee ID',
      );
    }
    final root = await _employeesDirectory();
    final directory = Directory('${root.path}/${employee.id}');
    if (!await directory.exists()) {
      throw FileSystemException(
        'Employee directory does not exist',
        directory.path,
      );
    }
    await directory.delete(recursive: true);
  }

  Future<Directory> monthsDirectory(EmployeeRecord employee) async {
    if (!RegExp(r'^[A-Za-z0-9_%\-]+$').hasMatch(employee.id)) {
      throw ArgumentError.value(
        employee.id,
        'employee.id',
        'Invalid employee ID',
      );
    }
    final root = await _employeesDirectory();
    final directory = Directory('${root.path}/${employee.id}/months');
    await directory.create(recursive: true);
    return directory;
  }
}

class EmployeeSelectionPage extends StatefulWidget {
  const EmployeeSelectionPage({
    required this.store,
    this.attendanceModeStore,
    super.key,
  });

  final EmployeeStore store;
  final AttendanceModeStore? attendanceModeStore;

  @override
  State<EmployeeSelectionPage> createState() => _EmployeeSelectionPageState();
}

class _EmployeeSelectionPageState extends State<EmployeeSelectionPage> {
  late Future<List<EmployeeRecord>> _employeesFuture;

  @override
  void initState() {
    super.initState();
    _employeesFuture = widget.store.loadEmployees();
  }

  Future<void> _openEmployee(EmployeeRecord employee) async {
    if (employee.hasPassword) {
      final unlocked = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _EmployeePasswordDialog(
          employeeName: employee.name,
          onSubmit: (password) => _verifyPassword(
            password,
            employee.passwordSalt!,
            employee.passwordHash!,
          ),
        ),
      );
      if (unlocked != true || !mounted) return;
    }
    try {
      final directory = await widget.store.monthsDirectory(employee);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MonthsPage(
            store: MonthStore(directory: directory),
            userName: employee.name,
            appTitle: 'تطبيق الموظفين',
            employeeMode: true,
            attendanceModeStore: widget.attendanceModeStore,
          ),
        ),
      );
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر فتح سجل الموظف: ${error.message}')),
        );
      }
    }
  }

  Future<void> _manageEmployeePasswords() async {
    final employees = await _employeesFuture;
    if (!mounted || employees.isEmpty) return;
    final employee = await showModalBottomSheet<EmployeeRecord>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'اختار الموظف لإدارة كلمة المرور',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final employee in employees)
              ListTile(
                leading: Icon(
                  employee.hasPassword
                      ? Icons.lock_outline
                      : Icons.lock_open_outlined,
                ),
                title: Text(employee.name),
                subtitle: Text(
                  employee.hasPassword
                      ? 'كلمة المرور مفعّلة'
                      : 'بدون كلمة مرور',
                ),
                onTap: () => Navigator.of(context).pop(employee),
              ),
          ],
        ),
      ),
    );
    if (employee == null || !mounted) return;

    var removePassword = false;
    if (employee.hasPassword) {
      final action = await showModalBottomSheet<_EmployeePasswordAction>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('تعديل كلمة المرور'),
                onTap: () =>
                    Navigator.of(context).pop(_EmployeePasswordAction.change),
              ),
              ListTile(
                leading: const Icon(Icons.lock_open_outlined),
                title: const Text('إلغاء كلمة المرور'),
                onTap: () =>
                    Navigator.of(context).pop(_EmployeePasswordAction.remove),
              ),
            ],
          ),
        ),
      );
      if (action == null || !mounted) return;
      removePassword = action == _EmployeePasswordAction.remove;
    }

    final result = await showDialog<_PasswordDialogResult>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordDialog(
        title: removePassword
            ? 'إلغاء كلمة مرور ${employee.name}'
            : employee.hasPassword
                ? 'تعديل كلمة مرور ${employee.name}'
                : 'إنشاء كلمة مرور ${employee.name}',
        confirmPassword: !removePassword,
        requireOldPassword: employee.hasPassword,
        removePassword: removePassword,
        oldPasswordSalt: employee.passwordSalt,
        oldPasswordHash: employee.passwordHash,
      ),
    );
    if (result == null || !mounted) return;
    try {
      await widget.store.setPassword(
        employee,
        result.remove ? null : result.password,
      );
      if (!mounted) return;
      setState(() {
        _employeesFuture = widget.store.loadEmployees();
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.remove
                ? 'تم إلغاء كلمة مرور ${employee.name}'
                : 'تم حفظ كلمة مرور ${employee.name}',
          ),
        ),
      );
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ كلمة المرور: ${error.message}')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('تطبيق الموظفين'),
        actions: [
          IconButton(
            tooltip: 'تحديث قائمة الموظفين',
            onPressed: () {
              setState(() {
                _employeesFuture = widget.store.loadEmployees();
              });
            },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<EmployeeRecord>>(
        future: _employeesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('تعذر تحميل قائمة الموظفين'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final employees = snapshot.data!;
          if (employees.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_outline, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'لا يوجد موظفون مضافون بعد.\nافتح تطبيق المدير لإضافة الموظفين أولًا.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: employees.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final employee = employees[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(employee.name),
                  subtitle: const Text('فتح سجل الحضور والراتب'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _openEmployee(employee),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 8),
          child: Align(
            heightFactor: 1,
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton.icon(
              onPressed: _manageEmployeePasswords,
              icon: const Icon(Icons.password_outlined),
              label: const Text('تعديل الباسورد'),
            ),
          ),
        ),
      ),
    );
  }
}

enum _EmployeePasswordAction { change, remove }

class _EmployeePasswordDialog extends StatefulWidget {
  const _EmployeePasswordDialog({
    required this.employeeName,
    required this.onSubmit,
  });

  final String employeeName;
  final Future<bool> Function(String password) onSubmit;

  @override
  State<_EmployeePasswordDialog> createState() =>
      _EmployeePasswordDialogState();
}

class _EmployeePasswordDialogState extends State<_EmployeePasswordDialog> {
  final _passwordController = TextEditingController();
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_passwordController.text.isEmpty) {
      setState(() => _error = 'اكتب كلمة المرور');
      return;
    }
    setState(() {
      _checking = true;
      _error = null;
    });
    final valid = await widget.onSubmit(_passwordController.text);
    if (!mounted) return;
    if (valid) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _checking = false;
        _error = 'كلمة المرور غير صحيحة';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('كلمة مرور ${widget.employeeName}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _passwordController,
            autofocus: true,
            obscureText: true,
            decoration: const InputDecoration(labelText: 'كلمة المرور'),
            onSubmitted: (_) => _submit(),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: _checking ? null : () => Navigator.of(context).pop(false),
          child: const Text('إلغاء'),
        ),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: Text(_checking ? 'جارٍ التحقق...' : 'فتح'),
        ),
      ],
    );
  }
}

class EmployeesPage extends StatefulWidget {
  const EmployeesPage({
    super.key,
    this.store,
    this.userName,
    this.appTitle = 'salary',
    this.onChangePassword,
    this.attendanceModeStore,
  });

  final EmployeeStore? store;
  final String? userName;
  final String appTitle;
  final Future<void> Function()? onChangePassword;
  final AttendanceModeStore? attendanceModeStore;

  @override
  State<EmployeesPage> createState() => _EmployeesPageState();
}

class _EmployeeNameDialog extends StatefulWidget {
  const _EmployeeNameDialog();

  @override
  State<_EmployeeNameDialog> createState() => _EmployeeNameDialogState();
}

class _EmployeeNameDialogState extends State<_EmployeeNameDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop(_nameController.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('إضافة موظف'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _nameController,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'اسم الموظف'),
          validator: (value) =>
              value == null || value.trim().isEmpty ? 'اكتب اسم الموظف' : null,
          onFieldSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        FilledButton(onPressed: _submit, child: const Text('إضافة')),
      ],
    );
  }
}

class _EmployeesPageState extends State<EmployeesPage> {
  late final EmployeeStore _employeeStore;
  late final AttendanceModeStore _attendanceModeStore;
  late Future<List<EmployeeRecord>> _employeesFuture;

  @override
  void initState() {
    super.initState();
    _employeeStore = widget.store ?? EmployeeStore();
    _attendanceModeStore = widget.attendanceModeStore ?? AttendanceModeStore();
    _employeesFuture = _employeeStore.loadEmployees();
  }

  Future<void> _addEmployee() async {
    final name = await showDialog<String>(
      context: context,
      builder: (_) => const _EmployeeNameDialog(),
    );
    if (name == null || !mounted) return;

    try {
      await _employeeStore.createEmployee(name);
      if (!mounted) return;
      setState(() {
        _employeesFuture = _employeeStore.loadEmployees();
      });
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر إضافة الموظف: ${error.message}');
    }
  }

  Future<void> _deleteEmployee() async {
    final employees = await _employeesFuture;
    if (!mounted) return;
    if (employees.isEmpty) {
      _showMessage('مفيش موظفين لحذفهم');
      return;
    }

    final employee = await showModalBottomSheet<EmployeeRecord>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'اختار الموظف المراد حذفه',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final employee in employees)
              ListTile(
                leading: const Icon(Icons.person_remove_outlined),
                title: Text(employee.name),
                onTap: () => Navigator.of(context).pop(employee),
              ),
          ],
        ),
      ),
    );
    if (employee == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الموظف؟'),
        content: Text(
          'سيتم حذف ${employee.name} وكل الشهور وسجلات الحضور والرواتب الخاصة به نهائيًا.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف نهائيًا'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _employeeStore.deleteEmployee(employee);
      if (!mounted) return;
      setState(() {
        _employeesFuture = _employeeStore.loadEmployees();
      });
      _showMessage('تم حذف الموظف وكل بياناته');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حذف الموظف: ${error.message}');
    }
  }

  Future<void> _manageAttendanceMode() async {
    final AttendanceMode currentMode;
    try {
      currentMode = await _attendanceModeStore.load();
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر تحميل نظام الحضور: ${error.message}');
      return;
    } on FormatException {
      if (mounted) _showMessage('إعداد نظام الحضور غير صالح');
      return;
    }
    if (!mounted) return;

    final selectedMode = await showDialog<AttendanceMode>(
      context: context,
      builder: (context) {
        var selected = currentMode;
        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: const Text('نظام الحضور والانصراف'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    selected == AttendanceMode.optional
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: const Text('نظام اختياري'),
                  subtitle: const Text('اختيار وقت الحضور والانصراف يدويًا'),
                  onTap: () => setDialogState(
                    () => selected = AttendanceMode.optional,
                  ),
                ),
                ListTile(
                  leading: Icon(
                    selected == AttendanceMode.mandatory
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                  ),
                  title: const Text('نظام إجباري'),
                  subtitle: const Text(
                    'تسجيل الوقت تلقائيًا لليوم الحالي ومنع تعديله',
                  ),
                  onTap: () => setDialogState(
                    () => selected = AttendanceMode.mandatory,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'يُطبّق على جميع الموظفين ولا يغيّر السجلات الموجودة.',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('إلغاء'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(selected),
                child: const Text('حفظ النظام'),
              ),
            ],
          ),
        );
      },
    );
    if (selectedMode == null || !mounted) return;

    try {
      await _attendanceModeStore.save(selectedMode);
      if (mounted) {
        _showMessage(
          selectedMode == AttendanceMode.optional
              ? 'تم تفعيل نظام الحضور الاختياري'
              : 'تم تفعيل نظام الحضور الإجباري',
        );
      }
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حفظ نظام الحضور: ${error.message}');
    }
  }

  Future<void> _openEmployee(EmployeeRecord employee) async {
    try {
      final directory = await _employeeStore.monthsDirectory(employee);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MonthsPage(
            store: MonthStore(directory: directory),
            userName: widget.userName,
            appTitle: widget.appTitle,
          ),
        ),
      );
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر فتح سجل الموظف: ${error.message}');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _homeAppBarTitle(widget.userName, appTitle: widget.appTitle),
        actions: [
          TextButton.icon(
            onPressed: _manageAttendanceMode,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('نظام الحضور والانصراف'),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'add-employee',
            onPressed: _addEmployee,
            icon: const Icon(Icons.person_add_alt_1),
            label: const Text('إضافة موظف'),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.extended(
            heroTag: 'delete-employee',
            onPressed: _deleteEmployee,
            icon: const Icon(Icons.person_remove_outlined),
            label: const Text('حذف موظف'),
          ),
          const SizedBox(width: 8),
          FloatingActionButton.small(
            heroTag: 'manager-info',
            tooltip: 'الإنفو',
            onPressed: () => _showInfoDialog(context),
            child: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<EmployeeRecord>>(
        future: _employeesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('حصلت مشكلة أثناء تحميل الموظفين'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final employees = snapshot.data!;
          if (employees.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.people_outline, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'مفيش موظفين مضافين لسه\nاضغط «إضافة موظف» للبدء',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: employees.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final employee = employees[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.person_outline),
                  ),
                  title: Text(employee.name),
                  subtitle: const Text('فتح سجل الرواتب'),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () => _openEmployee(employee),
                ),
              );
            },
          );
        },
      ),
      bottomNavigationBar: widget.onChangePassword == null
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 4, 16, 8),
                child: Align(
                  heightFactor: 1,
                  alignment: AlignmentDirectional.centerEnd,
                  child: TextButton.icon(
                    onPressed: widget.onChangePassword,
                    icon: const Icon(Icons.password_outlined),
                    label: const Text('تعديل الباسورد'),
                  ),
                ),
              ),
            ),
    );
  }
}

Future<void> _showInfoDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (context) => DefaultTabController(
      length: 2,
      child: Dialog(
        child: SizedBox(
          height: 360,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 16, 8, 0),
                child: Row(
                  children: [
                    const Expanded(
                      child: Text(
                        'الإنفو',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'إغلاق',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: 'عن التطبيق'),
                  Tab(text: 'عن المطور'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(_appDescription),
                          const Spacer(),
                          Text(
                            'تاريخ الإصدار: ${DateFormat('d MMMM yyyy', 'ar').format(DateTime(2026, 10, 1))}',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    ),
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircleAvatar(
                            radius: 30,
                            child: Icon(Icons.person_outline, size: 32),
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'Mohamed Hamed',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text('01141973426'),
                          const SizedBox(height: 8),
                          const Text('mohamed.hamed306247@gmail.com'),
                          const SizedBox(height: 8),
                          TextButton.icon(
                            onPressed: () => _openWhatsApp(context),
                            icon: const Icon(Icons.chat),
                            label: const Text('ابدأ محادثة على واتساب'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _openWhatsApp(BuildContext context) async {
  final opened = await launchUrl(
    Uri.parse('https://wa.me/201141973426'),
    mode: LaunchMode.externalApplication,
  );
  if (!opened && context.mounted) {
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('تعذر فتح واتساب')));
  }
}

class MonthRecord {
  MonthRecord({
    required this.year,
    required this.month,
    this.hourlyRate,
    this.vacationDays = 0,
    this.workDays = 30,
    this.defaultArrival,
    this.defaultDeparture,
    Map<int, DayRecord>? days,
  }) : days = days ?? {};

  final int year;
  final int month;
  double? hourlyRate;
  int vacationDays;
  int workDays;
  String? defaultArrival;
  String? defaultDeparture;
  final Map<int, DayRecord> days;

  String get id => '$year-${month.toString().padLeft(2, '0')}';

  DayRecord dayRecord(int dayNumber) {
    final record = days[dayNumber] ?? const DayRecord();
    return DayRecord(
      arrival: record.arrival ?? defaultArrival,
      departure: record.departure ?? defaultDeparture,
      isWorking: record.isWorking,
    );
  }

  int get leaveDays {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    return List.generate(
      daysInMonth,
      (index) => index + 1,
    ).where((dayNumber) => !dayRecord(dayNumber).isWorking).length;
  }

  double get totalHours {
    final daysInMonth = DateTime(year, month + 1, 0).day;
    return List.generate(
      daysInMonth,
      (index) => index + 1,
    ).fold(0, (sum, dayNumber) => sum + dayRecord(dayNumber).hours);
  }

  factory MonthRecord.fromJson(Map<String, dynamic> json) {
    final daysJson = json['days'] as Map<String, dynamic>? ?? {};
    return MonthRecord(
      year: json['year'] as int,
      month: json['month'] as int,
      hourlyRate: (json['hourlyRate'] as num?)?.toDouble(),
      vacationDays: (json['vacationDays'] as num?)?.toInt() ?? 0,
      workDays: (json['workDays'] as num?)?.toInt() ?? 30,
      defaultArrival: json['defaultArrival'] as String?,
      defaultDeparture: json['defaultDeparture'] as String?,
      days: {
        for (final entry in daysJson.entries)
          int.parse(entry.key): DayRecord.fromJson(
            entry.value as Map<String, dynamic>,
          ),
      },
    );
  }

  Map<String, dynamic> toJson() => {
        'year': year,
        'month': month,
        'hourlyRate': hourlyRate,
        'vacationDays': vacationDays,
        'workDays': workDays,
        'defaultArrival': defaultArrival,
        'defaultDeparture': defaultDeparture,
        'days': {
          for (final entry in days.entries)
            entry.key.toString(): entry.value.toJson(),
        },
      };
}

class DayRecord {
  const DayRecord({this.arrival, this.departure, this.isWorking = true});

  final String? arrival;
  final String? departure;
  final bool isWorking;

  DayRecord copyWith({String? arrival, String? departure, bool? isWorking}) =>
      DayRecord(
        arrival: arrival ?? this.arrival,
        departure: departure ?? this.departure,
        isWorking: isWorking ?? this.isWorking,
      );

  factory DayRecord.fromJson(Map<String, dynamic> json) => DayRecord(
        arrival: json['arrival'] as String?,
        departure: json['departure'] as String?,
        isWorking: json['isWorking'] as bool? ?? true,
      );

  Map<String, dynamic> toJson() => {
        'arrival': arrival,
        'departure': departure,
        'isWorking': isWorking,
      };

  double get hours {
    if (!isWorking || arrival == null || departure == null) return 0;
    final start = _minutesFromTime(arrival!);
    var end = _minutesFromTime(departure!);
    if (end < start) end += 24 * 60;
    return (end - start) / 60;
  }
}

int _minutesFromTime(String value) {
  final parts = value.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

class MonthStore {
  MonthStore({this.directory});

  final Directory? directory;
  Future<void> _saveQueue = Future<void>.value();

  Future<Directory> _monthsDirectory() async {
    final customDirectory = directory;
    if (customDirectory != null) {
      await customDirectory.create(recursive: true);
      return customDirectory;
    }
    final documents = await getApplicationDocumentsDirectory();
    final monthsDirectory = Directory('${documents.path}/employee_months');
    await monthsDirectory.create(recursive: true);
    return monthsDirectory;
  }

  Future<List<MonthRecord>> loadMonths() async {
    final directory = await _monthsDirectory();
    final entities = await directory.list(followLinks: false).toList();
    final records = <MonthRecord>[];
    for (final entity in entities.whereType<Directory>()) {
      final file = File('${entity.path}/data.json');
      if (!await file.exists()) continue;
      final decoded = jsonDecode(await file.readAsString());
      records.add(MonthRecord.fromJson(decoded as Map<String, dynamic>));
    }
    records.sort((a, b) => b.id.compareTo(a.id));
    return records;
  }

  Future<void> save(MonthRecord record) {
    final write = _saveQueue.then((_) async {
      final root = await _monthsDirectory();
      final directory = Directory('${root.path}/${record.id}');
      await directory.create(recursive: true);
      await File('${directory.path}/data.json')
          .writeAsString(jsonEncode(record.toJson()), flush: true);
    });
    _saveQueue = write.catchError((Object _) {});
    return write;
  }

  Future<void> delete(MonthRecord record) {
    final operation = _saveQueue.then((_) async {
      if (!RegExp(r'^\d{4}-(0[1-9]|1[0-2])$').hasMatch(record.id)) {
        throw ArgumentError.value(record.id, 'record.id', 'Invalid month ID');
      }
      final root = await _monthsDirectory();
      final directory = Directory('${root.path}/${record.id}');
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
    });
    _saveQueue = operation.catchError((Object _) {});
    return operation;
  }
}

class MonthsPage extends StatefulWidget {
  const MonthsPage({
    this.store,
    this.userName,
    this.appTitle = 'salary',
    this.employeeMode = false,
    this.attendanceModeStore,
    super.key,
  });

  final MonthStore? store;
  final String? userName;
  final String appTitle;
  final bool employeeMode;
  final AttendanceModeStore? attendanceModeStore;

  @override
  State<MonthsPage> createState() => _MonthsPageState();
}

class _MonthsPageState extends State<MonthsPage> {
  late final MonthStore _store;
  late Future<List<MonthRecord>> _monthsFuture;

  @override
  void initState() {
    super.initState();
    _store = widget.store ?? MonthStore();
    _monthsFuture = _store.loadMonths();
  }

  Future<void> _addMonth() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: 'اختار أي يوم من الشهر المطلوب',
    );
    if (selected == null || !mounted) return;

    final record = MonthRecord(year: selected.year, month: selected.month);
    final existing = await _monthsFuture;
    if (existing.any((month) => month.id == record.id)) {
      if (mounted) _showMessage('الشهر ده مضاف بالفعل');
      return;
    }

    try {
      await _store.save(record);
      if (!mounted) return;
      setState(() {
        _monthsFuture = _store.loadMonths();
      });
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حفظ الشهر: ${error.message}');
    }
  }

  Future<void> _deleteMonth() async {
    final months = await _monthsFuture;
    if (!mounted) return;
    if (months.isEmpty) {
      _showMessage('مفيش شهور لحذفها');
      return;
    }

    final selected = await showModalBottomSheet<MonthRecord>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'اختار الشهر المراد حذفه',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final month in months)
              ListTile(
                leading: const Icon(Icons.folder_outlined),
                title: Text(
                  DateFormat(
                    'MMMM yyyy',
                    'ar',
                  ).format(DateTime(month.year, month.month)),
                ),
                onTap: () => Navigator.of(context).pop(month),
              ),
          ],
        ),
      ),
    );
    if (selected == null || !mounted) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('حذف الشهر؟'),
        content: Text(
          'هيتم حذف بيانات ${DateFormat('MMMM yyyy', 'ar').format(DateTime(selected.year, selected.month))} نهائيًا.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      await _store.delete(selected);
      if (!mounted) return;
      setState(() {
        _monthsFuture = _store.loadMonths();
      });
      _showMessage('تم حذف الشهر');
    } on FileSystemException catch (error) {
      if (mounted) _showMessage('تعذر حذف الشهر: ${error.message}');
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _homeAppBarTitle(widget.userName, appTitle: widget.appTitle),
      ),
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'add-month',
            onPressed: _addMonth,
            icon: const Icon(Icons.add),
            label: const Text('إضافة شهر'),
          ),
          if (!widget.employeeMode) ...[
            const SizedBox(width: 12),
            FloatingActionButton.extended(
              heroTag: 'delete-month',
              onPressed: _deleteMonth,
              icon: const Icon(Icons.delete_outline),
              label: const Text('حذف شهر'),
            ),
          ],
          const SizedBox(width: 8),
          FloatingActionButton.small(
            heroTag: 'app-info',
            tooltip: 'الإنفو',
            onPressed: () => _showInfoDialog(context),
            child: const Icon(Icons.info_outline),
          ),
        ],
      ),
      body: FutureBuilder<List<MonthRecord>>(
        future: _monthsFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('حصلت مشكلة أثناء تحميل الشهور'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final months = snapshot.data!;
          if (months.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.calendar_month_outlined, size: 64),
                    SizedBox(height: 16),
                    Text(
                      'مفيش شهور مضافة لسه\nاضغط «إضافة شهر» للبدء',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: months.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, index) {
              final month = months[index];
              return Card(
                child: ListTile(
                  leading: const CircleAvatar(
                    child: Icon(Icons.folder_outlined),
                  ),
                  title: Text(
                    DateFormat(
                      'MMMM yyyy',
                      'ar',
                    ).format(DateTime(month.year, month.month)),
                  ),
                  subtitle: Text(
                    'إجمالي الساعات: ${_formatNumber(_monthHours(month))}',
                  ),
                  trailing: const Icon(Icons.chevron_left),
                  onTap: () async {
                    final navigator = Navigator.of(context);
                    var attendanceMode = AttendanceMode.optional;
                    if (widget.employeeMode &&
                        widget.attendanceModeStore != null) {
                      try {
                        attendanceMode =
                            await widget.attendanceModeStore!.load();
                      } on FileSystemException catch (error) {
                        if (mounted) {
                          _showMessage(
                            'تعذر تحميل نظام الحضور: ${error.message}',
                          );
                        }
                        return;
                      } on FormatException {
                        if (mounted) {
                          _showMessage('إعداد نظام الحضور غير صالح');
                        }
                        return;
                      }
                    }
                    if (!mounted) return;
                    await navigator.push(
                      MaterialPageRoute<void>(
                        builder: (_) => MonthPage(
                          month: month,
                          store: _store,
                          employeeMode: widget.employeeMode,
                          attendanceMode: attendanceMode,
                          attendanceModeStore: widget.attendanceModeStore,
                        ),
                      ),
                    );
                    if (mounted) {
                      setState(() {
                        _monthsFuture = _store.loadMonths();
                      });
                    }
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }
}

double _monthHours(MonthRecord month) => month.totalHours;

String _formatNumber(num value) =>
    value.toStringAsFixed(2).replaceFirst(RegExp(r'\.?0+$'), '');

class MonthPage extends StatefulWidget {
  const MonthPage({
    required this.month,
    required this.store,
    this.employeeMode = false,
    this.attendanceMode = AttendanceMode.optional,
    this.attendanceModeStore,
    super.key,
  });

  final MonthRecord month;
  final MonthStore store;
  final bool employeeMode;
  final AttendanceMode attendanceMode;
  final AttendanceModeStore? attendanceModeStore;

  @override
  State<MonthPage> createState() => _MonthPageState();
}

class _MonthPageState extends State<MonthPage> {
  late final TextEditingController _rateController;
  late final TextEditingController _vacationDaysController;
  late final TextEditingController _workDaysController;
  late AttendanceMode _attendanceMode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _attendanceMode = widget.attendanceMode;
    _rateController = TextEditingController(
      text: widget.month.hourlyRate?.toString() ?? '',
    );
    _vacationDaysController = TextEditingController(
      text: widget.month.vacationDays.toString(),
    );
    _workDaysController = TextEditingController(
      text: widget.month.workDays.toString(),
    );
  }

  @override
  void dispose() {
    _rateController.dispose();
    _vacationDaysController.dispose();
    _workDaysController.dispose();
    super.dispose();
  }

  Future<void> _updateDay(
    int dayNumber, {
    String? arrival,
    String? departure,
    bool? isWorking,
  }) async {
    final previous = widget.month.days[dayNumber] ?? const DayRecord();
    setState(() {
      widget.month.days[dayNumber] = previous.copyWith(
        arrival: arrival,
        departure: departure,
        isWorking: isWorking,
      );
    });
    await _save();
  }

  Future<void> _saveDays({String? vacationDays, String? workDays}) async {
    final vacation = vacationDays == null
        ? widget.month.vacationDays
        : int.tryParse(_normalizeNumber(vacationDays)) ?? 0;
    final work = workDays == null
        ? widget.month.workDays
        : int.tryParse(_normalizeNumber(workDays)) ?? 0;
    setState(() {
      widget.month.vacationDays = vacation.clamp(0, 31).toInt();
      widget.month.workDays = work.clamp(0, 31).toInt();
    });
    await _save();
  }

  Future<void> _chooseTime(int dayNumber, bool isArrival) async {
    if (widget.employeeMode && widget.attendanceModeStore != null) {
      final mode = await _syncAttendanceMode();
      if (!mounted || mode != AttendanceMode.optional) return;
    }
    final record = widget.month.dayRecord(dayNumber);
    final current = isArrival ? record.arrival : record.departure;
    final initialTime = current == null
        ? TimeOfDay.now()
        : TimeOfDay(
            hour: _minutesFromTime(current) ~/ 60,
            minute: _minutesFromTime(current) % 60,
          );
    final selected = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: isArrival ? 'اختار وقت الحضور' : 'اختار وقت الانصراف',
    );
    if (selected == null || !mounted) return;
    final value =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    if (isArrival) {
      await _updateDay(dayNumber, arrival: value);
    } else {
      await _updateDay(dayNumber, departure: value);
    }
  }

  Future<void> _recordAttendance(int dayNumber, bool isArrival) async {
    final mode = widget.attendanceModeStore == null
        ? _attendanceMode
        : await _syncAttendanceMode();
    if (!mounted || mode != AttendanceMode.mandatory) return;
    final now = DateTime.now();
    final date = DateTime(widget.month.year, widget.month.month, dayNumber);
    if (date.year != now.year ||
        date.month != now.month ||
        date.day != now.day) {
      return;
    }
    final previous = widget.month.days[dayNumber] ?? const DayRecord();
    if (!previous.isWorking ||
        (isArrival ? previous.arrival : previous.departure) != null ||
        _saving) {
      return;
    }
    final value =
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';
    if (isArrival) {
      await _updateDay(dayNumber, arrival: value);
    } else {
      await _updateDay(dayNumber, departure: value);
    }
  }

  Future<AttendanceMode?> _syncAttendanceMode() async {
    final store = widget.attendanceModeStore;
    if (store == null) return _attendanceMode;
    try {
      final mode = await store.load();
      if (!mounted) return null;
      if (_attendanceMode != mode) {
        setState(() => _attendanceMode = mode);
      }
      return mode;
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر تحميل نظام الحضور: ${error.message}')),
        );
      }
      return null;
    } on FormatException {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('إعداد نظام الحضور غير صالح')),
        );
      }
      return null;
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      await widget.store.save(widget.month);
    } on FileSystemException catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('تعذر حفظ البيانات: ${error.message}')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveRate(String value) async {
    final normalized = _normalizeNumber(value);
    setState(() {
      widget.month.hourlyRate =
          normalized.isEmpty ? null : double.tryParse(normalized);
    });
    await _save();
  }

  Future<void> _chooseMonthDefault(bool isArrival) async {
    final current =
        isArrival ? widget.month.defaultArrival : widget.month.defaultDeparture;
    final initialTime = current == null
        ? TimeOfDay.now()
        : TimeOfDay(
            hour: _minutesFromTime(current) ~/ 60,
            minute: _minutesFromTime(current) % 60,
          );
    final selected = await showTimePicker(
      context: context,
      initialTime: initialTime,
      helpText: isArrival
          ? 'اختار وقت الحضور الافتراضي'
          : 'اختار وقت الانصراف الافتراضي',
    );
    if (selected == null || !mounted) return;
    final value =
        '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}';
    setState(() {
      if (isArrival) {
        widget.month.defaultArrival = value;
      } else {
        widget.month.defaultDeparture = value;
      }
    });
    await _save();
  }

  Future<void> _clearMonthDefault(bool isArrival) async {
    setState(() {
      if (isArrival) {
        widget.month.defaultArrival = null;
      } else {
        widget.month.defaultDeparture = null;
      }
    });
    await _save();
  }

  @override
  Widget build(BuildContext context) {
    final month = widget.month;
    final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
    final now = DateTime.now();
    final isMandatoryEmployeeMode =
        widget.employeeMode && _attendanceMode == AttendanceMode.mandatory;
    var hours = _monthHours(month);
    if (isMandatoryEmployeeMode &&
        month.year == now.year &&
        month.month == now.month) {
      final savedToday = month.days[now.day] ?? const DayRecord();
      final storedHours = DayRecord(
        arrival: savedToday.arrival,
        departure: savedToday.departure,
        isWorking: savedToday.isWorking,
      ).hours;
      hours += storedHours - month.dayRecord(now.day).hours;
    }
    final netWorkDays = month.workDays - month.vacationDays;
    final salary =
        netWorkDays > 0 ? hours / netWorkDays * (month.hourlyRate ?? 0) : 0;
    final leaveDays = month.leaveDays;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          DateFormat(
            'MMMM yyyy',
            'ar',
          ).format(DateTime(month.year, month.month)),
        ),
        actions: [
          if (_saving)
            const Padding(
              padding: EdgeInsetsDirectional.only(end: 16),
              child: Center(
                child: SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
              itemCount: daysInMonth + 1,
              itemBuilder: (context, index) {
                if (index == 0 && !widget.employeeMode) {
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'مواعيد افتراضية للشهر',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: _MonthDefaultTime(
                                  title: 'الحضور',
                                  value: month.defaultArrival,
                                  onTap: () => _chooseMonthDefault(true),
                                  onClear: month.defaultArrival == null
                                      ? null
                                      : () => _clearMonthDefault(true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _MonthDefaultTime(
                                  title: 'الانصراف',
                                  value: month.defaultDeparture,
                                  onTap: () => _chooseMonthDefault(false),
                                  onClear: month.defaultDeparture == null
                                      ? null
                                      : () => _clearMonthDefault(false),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'تُستخدم للأيام غير المعدلة، ويمكن تغيير وقت أي يوم يدويًا.',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  );
                }
                final dayNumber = index;
                final date = DateTime(month.year, month.month, dayNumber);
                final isToday = date.year == now.year &&
                    date.month == now.month &&
                    date.day == now.day;
                final savedRecord = month.days[dayNumber] ?? const DayRecord();
                final record = isMandatoryEmployeeMode && isToday
                    ? DayRecord(
                        arrival: savedRecord.arrival,
                        departure: savedRecord.departure,
                        isWorking: savedRecord.isWorking,
                      )
                    : month.dayRecord(dayNumber);
                return Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 12,
                    ),
                    child: Column(
                      children: [
                        Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            '${DateFormat('EEEE', 'ar').format(date)}  •  ${DateFormat('d/M/yyyy', 'ar').format(date)}',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            SizedBox(
                              width: 32,
                              child: Checkbox(
                                value: record.isWorking,
                                onChanged: (value) {
                                  if (value != null) {
                                    _updateDay(dayNumber, isWorking: value);
                                  }
                                },
                                semanticLabel: 'يوم عمل',
                                visualDensity: VisualDensity.compact,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                            const SizedBox(width: 4),
                            if (isMandatoryEmployeeMode && isToday) ...[
                              Expanded(
                                child: _AttendancePunchButton(
                                  title: 'حضور',
                                  time: savedRecord.arrival,
                                  enabled: isToday &&
                                      record.isWorking &&
                                      savedRecord.arrival == null &&
                                      !_saving,
                                  onPressed: () =>
                                      _recordAttendance(dayNumber, true),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _AttendancePunchButton(
                                  title: 'انصراف',
                                  time: savedRecord.departure,
                                  enabled: isToday &&
                                      record.isWorking &&
                                      savedRecord.departure == null &&
                                      !_saving,
                                  onPressed: () =>
                                      _recordAttendance(dayNumber, false),
                                ),
                              ),
                            ] else if (isMandatoryEmployeeMode) ...[
                              Expanded(
                                child: _TimeEntry(
                                  title: 'الحضور',
                                  value: record.arrival,
                                  onTap: null,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _TimeEntry(
                                  title: 'الانصراف',
                                  value: record.departure,
                                  onTap: null,
                                ),
                              ),
                            ] else ...[
                              Expanded(
                                child: _TimeEntry(
                                  title: 'الحضور',
                                  value: record.arrival,
                                  onTap: record.isWorking
                                      ? () => _chooseTime(dayNumber, true)
                                      : null,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: _TimeEntry(
                                  title: 'الانصراف',
                                  value: record.departure,
                                  onTap: record.isWorking
                                      ? () => _chooseTime(dayNumber, false)
                                      : null,
                                ),
                              ),
                            ],
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 58,
                              child: Column(
                                children: [
                                  const Text('الساعات'),
                                  Text(
                                    _formatNumber(record.hours),
                                    style:
                                        Theme.of(context).textTheme.titleMedium,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          Material(
            elevation: 8,
            color: Theme.of(context).colorScheme.surface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Column(
                  children: [
                    Row(
                      children: [
                        const Expanded(child: Text('إجمالي ساعات الشهر')),
                        Text(
                          '${_formatNumber(hours)} ساعة',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                    if (widget.employeeMode) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Expanded(child: Text('أيام الإجازة')),
                          Text(
                            '$leaveDays يوم',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                        ],
                      ),
                    ] else ...[
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _rateController,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                decimal: true,
                              ),
                              decoration: const InputDecoration(
                                labelText: 'سعر الساعة',
                                suffixText: 'جنيه',
                              ),
                              onChanged: _saveRate,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _vacationDaysController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'أيام الإجازة',
                                suffixText: 'يوم',
                              ),
                              onChanged: (value) =>
                                  _saveDays(vacationDays: value),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: _workDaysController,
                              keyboardType: TextInputType.number,
                              decoration: const InputDecoration(
                                labelText: 'أيام العمل',
                                suffixText: 'يوم',
                              ),
                              onChanged: (value) => _saveDays(workDays: value),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('إجمالي المرتب'),
                                Text(
                                  '${_formatNumber(salary)} جنيه',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                          ),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              const Text('أيام الإجازة من الجدول'),
                              Text(
                                '$leaveDays يوم',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (netWorkDays <= 0) ...[
                        const SizedBox(height: 8),
                        const Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            'أيام العمل يجب أن تكون أكبر من أيام الإجازة',
                            style: TextStyle(color: Colors.red),
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AttendancePunchButton extends StatelessWidget {
  const _AttendancePunchButton({
    required this.title,
    required this.time,
    required this.enabled,
    required this.onPressed,
  });

  final String title;
  final String? time;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          child: FilledButton.tonalIcon(
            onPressed: enabled ? onPressed : null,
            icon: Icon(title == 'حضور' ? Icons.login : Icons.logout, size: 18),
            label: Text(title),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            ),
          ),
        ),
        Text(time ?? '--:--'),
      ],
    );
  }
}

class _TimeEntry extends StatelessWidget {
  const _TimeEntry({
    required this.title,
    required this.value,
    required this.onTap,
  });

  final String title;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: title,
          enabled: onTap != null,
          suffixIcon: const Icon(Icons.access_time, size: 18),
        ),
        child: Text(
          value ?? '--:--',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12),
        ),
      ),
    );
  }
}

class _MonthDefaultTime extends StatelessWidget {
  const _MonthDefaultTime({
    required this.title,
    required this.value,
    required this.onTap,
    required this.onClear,
  });

  final String title;
  final String? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: title,
          suffixIcon: value == null
              ? const Icon(Icons.access_time, size: 18)
              : IconButton(
                  tooltip: 'مسح وقت $title الافتراضي',
                  onPressed: onClear,
                  icon: const Icon(Icons.close, size: 18),
                ),
        ),
        child: Text(value ?? 'غير محدد', textAlign: TextAlign.center),
      ),
    );
  }
}

String _normalizeNumber(String value) {
  const arabicIndic = '٠١٢٣٤٥٦٧٨٩';
  const persian = '۰۱۲۳۴۵۶۷۸۹';
  var normalized = value.trim().replaceAll('٫', '.').replaceAll(',', '.');
  for (var i = 0; i < 10; i++) {
    normalized = normalized
        .replaceAll(arabicIndic[i], '$i')
        .replaceAll(persian[i], '$i');
  }
  return normalized;
}
