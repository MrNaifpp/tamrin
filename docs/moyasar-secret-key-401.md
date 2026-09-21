# Moyasar support — test secret key returns 401

Send only after `./scripts/moyasar-account-check.sh` also reports the key rejected.
If that script says the key is valid, the fault is in how the secret is stored on
our side, not Moyasar's.

**Before sending:** fill in the account name / merchant id, the payment id, and the
time of the failure. **Never** paste the `sk_` key itself. If they ask to identify
it, give only its first and last four characters.

---

## Arabic (send this one)

**الموضوع:** المفتاح السري في وضع الاختبار يرجع 401 — حساب `<اسم الحساب / رقم التاجر>`

السلام عليكم ورحمة الله،

نطوّر تطبيق **تمرين** على iOS، ونستخدم Moyasar في وضع الاختبار. واجهتنا حالة
نرجو مساعدتكم فيها.

**ما ينجح:** الدفع نفسه. أنشأنا عملية Apple Pay من تطبيق iOS باستخدام
**المفتاح العام** (`pk_test_…`) عبر الـ SDK الرسمي، ونجحت العملية وظهرت في
لوحة التحكم.

**ما يفشل:** كل طلب من خادمنا يستخدم **المفتاح السري** (`sk_test_…`). الطلب:

```
GET https://api.moyasar.com/v1/payments/{payment_id}
Authorization: Basic base64("<sk_test_…>:")
```

والرد في كل مرة:

```
HTTP 401
{"type":"authentication_error","message":"Invalid authorization credentials","errors":null}
```

المفتاح منسوخ من لوحة التحكم (Settings → API Keys) في وضع الاختبار، ونستخدم
المصادقة الأساسية (Basic) بالمفتاح كاسم مستخدم وكلمة مرور فارغة، كما في وثائقكم.

**تفاصيل للرجوع إليها:**

- معرّف العملية الناجحة: `<payment_id>`
- وقت محاولات الخادم الفاشلة (UTC): `<التاريخ والوقت>`
- أول وآخر أربعة أحرف من المفتاح المستخدم: `<sk_t… …xxxx>`

**أسئلتنا:**

١. هل المفتاح السري لوضع الاختبار على حسابنا **فعّال**؟ وهل جرى تدويره أو
إيقافه في وقت سابق دون إشعار؟

٢. هل يتطلب حسابنا تفعيلًا إضافيًا للوصول إلى الـ API من الخادم، منفصلًا عن
استخدام المفتاح العام من التطبيق؟

٣. هل ما زالت المصادقة الأساسية (المفتاح كاسم مستخدم وكلمة مرور فارغة) هي
الطريقة الصحيحة، أم تغيّرت؟

٤. هل تظهر لديكم محاولات الـ 401 في السجلات في الوقت المذكور أعلاه؟ وما السبب
الذي تسجّلونه لها؟

٥. هل يمكن أن تكون عملية أُنشئت بالمفتاح العام غير قابلة للقراءة بالمفتاح
السري لأي سبب متعلق بنطاق الصلاحيات؟

٦. إن كان المفتاح تالفًا، ما الطريقة الصحيحة لإصدار مفتاح سري جديد لوضع
الاختبار دون التأثير على المفتاح العام المستخدم حاليًا؟

نحتاج المفتاح السري تحديدًا لأن تصميمنا لا يعتمد على ما يقوله الجهاز: التطبيق
يفوّض العملية فقط، ثم يتحقق خادمنا من المبلغ بالمفتاح السري قبل التحصيل.

شكرًا لتعاونكم.

---

## English (attach or send if they prefer)

**Subject:** Test-mode secret key returns 401 — account `<account name / merchant id>`

Hello,

We are building an iOS app, **Tamrin**, and are integrating Moyasar in test mode.

**What works:** the payment itself. We created an Apple Pay payment from the iOS
app using the **publishable** key (`pk_test_…`) via your official SDK. It
succeeded and appears in the dashboard.

**What fails:** every server-side request using the **secret** key (`sk_test_…`):

```
GET https://api.moyasar.com/v1/payments/{payment_id}
Authorization: Basic base64("<sk_test_…>:")
```

returns, every time:

```
HTTP 401
{"type":"authentication_error","message":"Invalid authorization credentials","errors":null}
```

The key was copied from Settings → API Keys in test mode, and we use HTTP Basic
with the key as the username and an empty password, as your docs specify.

**For your reference:**

- Successful payment id: `<payment_id>`
- Time of the failing server calls (UTC): `<date and time>`
- First and last four characters of the key used: `<sk_t… …xxxx>`

**Our questions:**

1. Is the test-mode secret key on our account **active**? Has it been rotated or
   revoked at any point?
2. Does our account need any additional enablement for server-side API access,
   separately from publishable-key use in the app?
3. Is HTTP Basic (key as username, empty password) still correct, or has it
   changed?
4. Do you see these 401s in your logs at the time above, and what reason is
   recorded?
5. Could a payment created with the publishable key be unreadable by the secret
   key for any scope-related reason?
6. If the key is bad, what is the correct way to issue a new test secret key
   without disturbing the publishable key we are already using?

We depend on the secret key specifically because our design never trusts the
device: the app only authorizes, and our server verifies the amount with the
secret key before capturing.

Thank you.
