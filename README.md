# salary

تطبيق Flutter لتسجيل حضور وانصراف الموظف وحساب ساعات العمل والمرتب الشهري، مع نسختين منفصلتين للكمبيوتر: تطبيق المدير وتطبيق الموظفين.

## تشغيل التطبيق على Android

1. ثبّت Flutter وAndroid SDK.
2. من مجلد المشروع أنشئ ملفات منصة Android إذا لم تكن موجودة:
   `flutter create --platforms=android --project-name employee_salary .`
3. شغّل `flutter pub get` ثم `flutter run`.

## التشغيل والتجربة على Fedora/Linux

ثبّت متطلبات Flutter لتطوير Linux desktop:

```bash
sudo dnf install clang cmake ninja-build pkgconf-pkg-config gtk3-devel gcc-c++
```

اعرض الأجهزة المتاحة بـ `flutter devices` ثم شغّل كل تطبيق من مجلد المشروع في Terminal مستقل:

```bash
flutter run -d linux --dart-define=APP_ROLE=manager
flutter run -d linux --dart-define=APP_ROLE=employee
```

ابنِ نسختي Linux القابلتين للتشغيل على Fedora بالأوامر التالية:

```bash
flutter build linux --release --dart-define=APP_ROLE=manager
mkdir -p dist/manager-linux
cp -a build/linux/x64/release/bundle/. dist/manager-linux/
mv dist/manager-linux/employee_salary dist/manager-linux/manager-app
flutter build linux --release --dart-define=APP_ROLE=employee
mkdir -p dist/employee-linux
cp -a build/linux/x64/release/bundle/. dist/employee-linux/
mv dist/employee-linux/employee_salary dist/employee-linux/employee-app
```

## بناء تطبيقات Windows

يجب تنفيذ بناء Windows على Windows؛ Flutter لا يدعم إنتاج نسخة Windows من Fedora مباشرة. يمكنك بناء النسختين محليًا على Windows بعد تثبيت Flutter وVisual Studio مع workload «Desktop development with C++»:

1. من مجلد المشروع شغّل:
   `powershell -ExecutionPolicy Bypass -File .\tool\build_windows_apps.ps1`
2. ستجد نسختين جاهزتين للتشغيل في `dist\employee\employee-app.exe` و`dist\manager\manager-app.exe`.
3. شغّل التطبيقين على Windows. على أول تشغيل لتطبيق المدير، سجّل اسم المدير ثم أضف الموظفين. يفتح تطبيق الموظفين قائمة الموظفين التي جهزها المدير، ويعرض لكل موظف سجل الحضور والراتب نفسه.

### البناء تلقائيًا على GitHub

بعد رفع المشروع إلى GitHub، سيعمل workflow تلقائيًا مع كل `push`، ويمكن تشغيله يدويًا من تبويب **Actions** عبر **Build Windows apps** ثم **Run workflow**. عند نجاح البناء، نزّل `employee-app-windows` و`manager-app-windows` من قسم **Artifacts** في صفحة تشغيل الـ workflow؛ يحتوي كل ملف مضغوط على التطبيق التنفيذي وملفات التشغيل اللازمة له. تُحذف هذه الملفات بعد 90 يومًا.

يحفظ التطبيقان بياناتهما محليًا في مجلد `salary_shared_data` داخل مجلد Documents الخاص بمستخدم Windows الحالي؛ لذلك تظهر التغييرات بين التطبيقين على الجهاز وحساب Windows نفسيهما، ولا يحتاجان إلى خادم أو اتصال إنترنت لمشاركة البيانات. بيانات Android تظل في مساحة التطبيق المعتادة.

## الاستخدام

- في نسخة Android، عند أول تشغيل اختر «استخدام موظف» أو «استخدام مدير». اختيار الدور محفوظ ولا يظهر مجددًا.
- في نسخة الكمبيوتر للموظفين، اختر اسمك من قائمة الموظفين التي جهزها المدير.
- في نسخة الكمبيوتر للمدير، سجّل اسم المدير ثم أضف الموظفين وافتح سجلاتهم.
- في سجل الموظف، يمكن للموظف تسجيل الحضور والانصراف وتحديد يوم الإجازة ومراجعة إجمالي ساعات الشهر وأيام إجازته؛ تفاصيل سعر الساعة وأيام العمل والراتب متاحة في تطبيق المدير فقط.
- في وضع المدير، اضغط «إضافة موظف» واكتب الاسم، ثم افتح الموظف لإدارة شهوره وحضوره ومرتبه.
- اضغط «إضافة شهر» واختر تاريخًا داخل الشهر المطلوب.
- افتح الشهر، ويمكنك ضبط وقت حضور وانصراف افتراضيين للشهر كله؛ أي يوم يمكن تعديل وقته يدويًا بشكل مستقل.
- استخدم «حذف شهر» لاختيار شهر وحذفه بعد تأكيد العملية.
- اضغط زر «الإنفو» للاطلاع على معلومات التطبيق والمطور وبدء محادثة واتساب.
- ساعات اليوم وإجمالي ساعات الشهر والمرتب تُحسب تلقائيًا.
- أدخل سعر الساعة وأيام الإجازة وأيام العمل؛ المرتب يساوي (إجمالي الساعات ÷ (أيام العمل - أيام الإجازة)) × سعر الساعة.
- تُحفظ بيانات كل شهر محليًا في مجلد مستقل. في Windows، يستخدم التطبيقان مجلد البيانات المشترك نفسه.
