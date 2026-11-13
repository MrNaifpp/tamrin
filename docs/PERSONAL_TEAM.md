# تشغيل نسخة التطوير بالحساب المجاني

تستخدم نسخة Debug البندل والفريق المحددين في `Config/Local.xcconfig`، بما في ذلك بندل إضافة Live Activity. الملف محلي وغير مرفوع إلى Git.

لتفعيل دعم Personal Team أضف السطرين معًا:

```xcconfig
TAMRIN_DEBUG_ENTITLEMENTS = Sirr/PersonalTeam.entitlements
TAMRIN_DEBUG_SWIFT_FLAGS = TAMRIN_PERSONAL_TEAM
```

يفصل هذا الخيار صلاحيات التوقيع المدفوعة عن Debug، ويخفي تسجيل الدخول بأبل ويوقف طلب الإشعارات البعيدة. يبقى تسجيل الدخول بالبريد متاحًا. تستخدم Release وStaging ملف `Sirr/Sirr.entitlements` الأصلي. النشاط المباشر المحلي لا يطلب رمز Push.

في Xcode اختر Scheme `Sirr` ثم الجوال واضغط Run. يجب إضافة حساب Apple في Settings → Apple Accounts وتفعيل Developer Mode على الجوال. عند طلب الوثوق بالمطوّر افتح إعدادات الجوال → عام → VPN وإدارة الجهاز.

توقيع Personal Team صالح لمدة سبعة أيام؛ أعد البناء والتثبيت من Xcode عند انتهائه. للبناء بحساب مدفوع، احذف السطرين المحليين أعلاه لتعود Debug إلى إعداداتها الأصلية.

فحص حماية صلاحيات النسخة الرسمية:

```sh
bash scripts/check-signing-capabilities.sh
```
