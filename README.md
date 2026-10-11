# salary

تطبيق Flutter لإدارة الموظفين والحضور والانصراف والرواتب. يحتفظ المشروع بالواجهات العربية الحالية، ويحوّل بيانات المؤسسات والموظفين والحضور إلى Supabase حتى يشاركها تطبيق المدير والهاتف وتطبيق الموظفين على Windows.

## التطبيقات والمنصات

- **تطبيق المدير:** Android وiOS. يسجل المدير الدخول ببيانات المدير الخاصة بالمؤسسة، ثم يضيف الموظفين ويدير شهورهم وساعاتهم ورواتبهم.
- **تطبيق الموظفين:** Windows. يسجل حساب الموظفين الخاص بالمؤسسة مرة واحدة لربط هذا الجهاز بها؛ بعد ذلك يختار الموظف اسمه ويسجل الحضور والانصراف.
- **تطبيق سوبر أدمن:** Fedora/Linux. يسجل سوبر أدمن الدخول، وينشئ المؤسسات وبيانات دخول منفصلة للمدير والموظفين، ويوقف المؤسسة أو يفعّلها ويغير بياناتها.

يعرض سوبر أدمن بيانات دخول المؤسسة. كلمات المرور مشفّرة في قاعدة البيانات بمفتاح محفوظ في Supabase Vault، كما يُحفظ hash للتحقق من تسجيل الدخول. لا تضع مفتاح التشفير في التطبيق أو المستودع، ولا تحذفه أو تدوّره دون إعادة تشفير كلمات المرور. تحفظ الجلسة في التخزين الآمن على الجهاز، ويجدد التطبيق قفل الجهاز كل دقيقة. تنتهي الجلسة تلقائيًا بعد 10 دقائق من انقطاع الاتصال، أو مباشرة عند تسجيل الخروج بنجاح.

## إعداد قاعدة البيانات السحابية

1. أنشئ مشروع Supabase.
2. نفّذ ملف `supabase/migrations/20261011000000_initial_tenant_backend.sql` في SQL Editor. ينشئ المؤسسات والمستخدمين وسجلات الحضور والجلسات ووظائف API؛ بيانات كل مؤسسة معزولة في الخادم.
3. أنشئ مفتاح تشفير عشوائيًا في Supabase Vault من SQL Editor. لا تنسخ المفتاح إلى ملفات المشروع أو التطبيق:

   ```sql
   select vault.create_secret(
     encode(extensions.gen_random_bytes(32), 'base64'),
     'company-password-encryption-key',
     'Key used to encrypt company login passwords'
   );
   ```

   احتفظ بنسخة احتياطية آمنة من المفتاح؛ من دونه لن يمكن فك تشفير كلمات مرور المؤسسات.
4. أنشئ حساب سوبر أدمن مرة واحدة من SQL Editor باستخدام اسم المستخدم `Mohamed306` وكلمة المرور التي حددتها، وخزّن كلمة المرور كـ bcrypt hash. لا تضف كلمة المرور إلى ملفات المشروع أو المستودع:

   ```sql
   insert into public.superadmin_accounts(username, password_hash)
   values ('Mohamed306', extensions.crypt('<أدخل كلمة المرور يدويًا هنا>', extensions.gen_salt('bf')))
   on conflict (username) do update
   set password_hash = excluded.password_hash;
   ```

   استبدل النص بين علامتي الزاوية بكلمة المرور في لوحة Supabase فقط، ولا تحفظ الاستعلام أو تشاركه.
5. استخدم **Project URL** ومعه **Publishable key** أو مفتاح **Legacy `anon`** العام من إعدادات Supabase عند تشغيل التطبيق أو بنائه. لا تضع مفتاح `service_role` أو secret key في تطبيق Flutter.

## التشغيل والبناء

مرّر الإعدادات من البيئة عند البناء، ولا تكتبها في ملفات Dart:

```bash
flutter pub get
flutter run -d linux \
  --dart-define=APP_ROLE=superadmin \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
```

### سوبر أدمن على Fedora/Linux

ثبّت متطلبات Flutter والتخزين الآمن على Fedora:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel gcc-c++ libsecret-devel
```

ثم ابنِ التطبيق:

```bash
flutter build linux --release \
  --dart-define=APP_ROLE=superadmin \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
```

الملفات في `build/linux/x64/release/bundle/`.

### تطبيق الموظفين على Windows

ابنِه على Windows بعد تثبيت Flutter وVisual Studio مع workload **Desktop development with C++**:

```powershell
$env:SUPABASE_URL = "https://YOUR_PROJECT.supabase.co"
$env:SUPABASE_ANON_KEY = "YOUR_PUBLIC_ANON_KEY"
powershell -ExecutionPolicy Bypass -File .\tool\build_windows_apps.ps1
```

يكون التطبيق التنفيذي في `dist\employee\employee-app.exe`.

للبناء عبر GitHub Actions، أضف `SUPABASE_URL` وواحدًا من `SUPABASE_PUBLISHABLE_KEY` أو `SUPABASE_ANON_KEY` كمتغيري مستودع.

### تطبيق المدير على Android وiOS

Android APK:

```bash
flutter build apk --release \
  --dart-define=APP_ROLE=manager \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
```

iOS يتطلب جهاز macOS وXcode:

```bash
flutter build ios --release \
  --dart-define=APP_ROLE=manager \
  --dart-define=SUPABASE_URL="$SUPABASE_URL" \
  --dart-define=SUPABASE_ANON_KEY="$SUPABASE_ANON_KEY"
```

## تفاصيل الاستخدام

- عند أول تشغيل لتطبيق المدير أو الموظفين، أدخل اسم المستخدم وكلمة المرور المناسبة للمؤسسة. الربط يبقى محفوظًا إلى أن تسجل الخروج أو تحذف التطبيق.
- لكل مؤسسة حساب موظفين واحد يربط نسخة Windows، وحساب مدير منفصل يربط نسخة المدير. يمنع الخادم وجود جلستين نشطتين للحساب نفسه.
- عند تسجيل الخروج بنجاح يتحرر الحساب فورًا. عند إغلاق التطبيق أو فقد الاتصال، تنتهي الجلسة بعد 10 دقائق دون تجديد heartbeat.
- من سوبر أدمن أضف اسم المؤسسة وبيانات الموظفين وبيانات المدير. تعرض بطاقة المؤسسة بيانات الدخول وحالتها؛ عند تسجيل الدخول يتحقق الخادم من bcrypt hash، وتُفك كلمة المرور المعروضة باستخدام مفتاح Vault.
- يمكن للمدير إضافة الموظفين وإدارة شهورهم وسعر الساعة وأيام العمل والإجازة والحضور والانصراف. يستطيع الموظف تعديل الحضور فقط، ولا ترسل قاعدة البيانات تفاصيل الراتب إليه.
- الراتب يُحسب وفق المعادلة الموجودة في التطبيق: (إجمالي الساعات ÷ (أيام العمل - أيام الإجازة)) × سعر الساعة.
- وضع `APP_ROLE=combined` يبقي وضع التطوير المحلي القديم متاحًا للاختبارات اليدوية؛ لا تستخدمه لتوزيع النسخ.

## الاختبارات

```bash
flutter test test/day_record_test.dart test/employee_add_test.dart test/months_page_test.dart
flutter analyze
```
