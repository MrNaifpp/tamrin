# Moyasar support — the test secret key is refused while the publishable key works

**Before sending:** confirm the Edge Function actually receives the key. Its logs
print, once per cold start:

    verify-payment: MOYASAR_SECRET_KEY { length: …, sha256: "…" }

If `length` is 0, or that hash does not match the DIGEST column of
`supabase secrets list`, the fault is ours and there is nothing to ask Moyasar.
Only send this once the function is proven to hold the right key.

**Fill in** the account name / merchant id, the payment id, and the timestamps.
**Never** paste the `sk_` key. If they need it identified, give its first and
last four characters only.

---

## Arabic (send this one)

**الموضوع:** المفتاح السري لوضع الاختبار يرجع 401 بينما المفتاح العام يعمل — حساب `<اسم الحساب / رقم التاجر>`

السلام عليكم ورحمة الله،

نطوّر تطبيق **تمرين** على iOS، ونتكامل مع Moyasar في **وضع الاختبار**. لدينا
حالة واضحة المعالم نرجو مساعدتكم فيها.

### الخلاصة

المفتاح **العام** من حسابنا يعمل: أنشأنا عملية Apple Pay من التطبيق ونجحت.
المفتاح **السري** من **الحساب نفسه وفي الوضع نفسه** يُرفض في كل طلب برسالة
`authentication_error`. أي أن الحساب سليم والعملية سليمة، والمشكلة محصورة في
قبول المفتاح السري.

### ما نجح

- التطبيق أنشأ عملية Apple Pay بالمفتاح العام (`pk_test_…`) عبر الـ iOS SDK
  الرسمي، مع التفويض اليدوي (`manual: true`).
- العملية **موجودة في لوحة التحكم بحالة `authorized`**، وهو السلوك المتوقع
  تمامًا من التفويض اليدوي.
- معرّف العملية: `<payment_id>`
- وقت الإنشاء (UTC): `<التاريخ والوقت>`

### ما فشل

خادمنا يحاول بعدها قراءة العملية بالمفتاح السري (`sk_test_…`) ليتحقق من المبلغ
قبل التحصيل. الطلب:

```
GET https://api.moyasar.com/v1/payments/{payment_id}
Authorization: Basic base64("<sk_test_…>:")
```

والرد في كل مرة، دون استثناء:

```
HTTP 401
{"type":"authentication_error","message":"Invalid authorization credentials","errors":null}
```

أوقات المحاولات الفاشلة (UTC): `<التاريخ والوقت>`

### ما استبعدناه، وكيف

| الاحتمال | كيف استُبعد |
|---|---|
| المفتاح المخزّن لدينا يختلف عن مفتاح لوحة التحكم | قارنّا بصمة SHA‑256 للقيمة المخزّنة مع بصمة المفتاح المنسوخ من لوحة التحكم: متطابقتان حرفًا بحرف، بلا مسافات أو أسطر زائدة |
| ترويسة المصادقة مبنية بشكل خاطئ | الترويسة التي نرسلها مطابقة بايتًا ببايت لما يرسله `curl -u "<key>:"`، أي المفتاح اسم مستخدم وكلمة مرور فارغة، كما في وثائقكم |
| المفتاح لا يصل إلى الخادم أصلًا | سجّلنا بصمة القيمة التي يستلمها الخادم فعليًا وقت التشغيل، وطابقناها مع المخزّن |
| خلط بين وضعي الاختبار والإنتاج | المفتاحان العام والسري مأخوذان من الشاشة نفسها في وضع الاختبار، والعملية نفسها أُنشئت في وضع الاختبار وظهرت في لوحة الاختبار |
| المفتاح السري هو نفسه المفتاح العام بالخطأ | بصمتاهما مختلفتان، فهما قيمتان مختلفتان فعلًا |

### كل النداءات التي نرسلها إلى Moyasar

خمس نقاط نهاية فقط، لا غير:

- `POST /v1/payments` (مصدر `applepay`، بالمفتاح **العام** من التطبيق) — يُرسَل لحظة تأكيد اللاعب للدفع في Apple Pay.
- `POST /v1/payments` (مصدر `creditcard`، بالمفتاح **العام** من التطبيق) — يُرسَل لحظة إرسال اللاعب لنموذج البطاقة.
- `GET /v1/payments/{id}` (بالمفتاح **السري** من خادمنا) — يُرسَل مباشرة بعد نجاح أي من النداءين أعلاه، ليتحقق الخادم من المبلغ قبل التحصيل. **هنا يقع الخطأ 401.**
- `POST /v1/payments/{id}/capture` (بالمفتاح **السري**) — يُرسَل فقط إذا طابق المبلغ والعملة والمستلم ما يقوله سجلنا. **لم نصل إليه قط.**
- `POST /v1/payments/{id}/void` (بالمفتاح **السري**) — يُرسَل فقط إذا لم تطابق، لتحرير المبلغ المحجوز. **لم نصل إليه قط.**

ونداء سادس بالمفتاح السري أيضًا: `GET /v1/payments/{id}` من مستقبل الـ webhook،
يُرسَل عند كل إشعار منكم لأننا لا نعتمد على محتوى الإشعار بل نعيد قراءة العملية.

يعني أن المفتاح السري لم يُستخدم فعليًا إلا على `GET /v1/payments/{id}`، ويفشل
عندها، فلا يمكننا القول إن التحصيل أو الإلغاء معطّلان — لم يُنفَّذا أصلًا.

### أسئلتنا

١. هل المفتاح السري لوضع الاختبار على حسابنا **فعّال حاليًا**؟ وهل جرى تدويره
أو إيقافه؟

٢. تظهر لديكم محاولات 401 في الأوقات المذكورة أعلاه — **ما السبب المسجّل لها
عندكم؟** هذا أكثر ما يفيدنا، لأننا استنفدنا ما يمكن فحصه من طرفنا.

٣. هل يحتاج حسابنا تفعيلًا منفصلًا للوصول إلى الـ API من الخادم، غير استخدام
المفتاح العام من التطبيق؟

٤. هل ما زالت المصادقة الأساسية (المفتاح اسم مستخدم وكلمة مرور فارغة) هي
الطريقة الصحيحة؟

٥. ما الطريقة الصحيحة لإصدار مفتاح سري جديد لوضع الاختبار **دون** تغيير
المفتاح العام المستخدم حاليًا في التطبيق؟

### لماذا هذا معطّل لنا

تصميمنا لا يثق بما يقوله الجهاز: التطبيق **يفوّض** فقط، ثم يتحقق خادمنا من
المبلغ والمستلم **بالمفتاح السري** قبل **التحصيل**. بدون مفتاح سري صالح تبقى
العمليات معلّقة على حالة `authorized` ولا تُحصَّل، ولا يمكننا إكمال الاختبار.

شكرًا لتعاونكم.

---

## English (attach or send if they prefer)

**Subject:** Test secret key returns 401 while the publishable key works — account `<account name / merchant id>`

Hello,

We are building an iOS app, **Tamrin**, integrating Moyasar in **test mode**.

### Summary

Our account's **publishable** key works: we created an Apple Pay payment and it
succeeded. The **secret** key from the **same account in the same mode** is
rejected on every request with `authentication_error`. The account and the
payment are both fine; the problem is isolated to the secret key being accepted.

### What works

- The app created an Apple Pay payment with the publishable key (`pk_test_…`)
  through your official iOS SDK, using manual authorization (`manual: true`).
- The payment is **visible in the dashboard with status `authorized`**, exactly
  as manual authorization should behave.
- Payment id: `<payment_id>`
- Created at (UTC): `<date and time>`

### What fails

Our server then reads that payment with the secret key (`sk_test_…`) to verify
the amount before capturing:

```
GET https://api.moyasar.com/v1/payments/{payment_id}
Authorization: Basic base64("<sk_test_…>:")
```

Every time, without exception:

```
HTTP 401
{"type":"authentication_error","message":"Invalid authorization credentials","errors":null}
```

Failing attempts at (UTC): `<date and time>`

### What we have ruled out, and how

| Possibility | How it was eliminated |
|---|---|
| Our stored key differs from the dashboard key | We compared the SHA-256 of the stored value with the SHA-256 of the key copied from the dashboard. Identical, so no stray whitespace or newline |
| Our Authorization header is malformed | The header we send is byte-identical to `curl -u "<key>:"`, i.e. key as username and empty password, as your docs specify |
| The key never reaches our server | We log a fingerprint of the value the server receives at runtime and matched it against the stored one |
| Test and live modes mixed up | Both keys were taken from the same test-mode screen, and the payment itself was created in test mode and appears in the test dashboard |
| The secret key is accidentally the publishable key | Their fingerprints differ, so they are genuinely different values |

### Every call we make to Moyasar

Five endpoints, and no others:

- `POST /v1/payments` (`applepay` source, **publishable** key, from the app) — sent the moment the player confirms in the Apple Pay sheet.
- `POST /v1/payments` (`creditcard` source, **publishable** key, from the app) — sent the moment the player submits the card form.
- `GET /v1/payments/{id}` (**secret** key, from our server) — sent immediately after either of the above succeeds, so the server can check the amount before taking money. **This is where the 401 occurs.**
- `POST /v1/payments/{id}/capture` (**secret** key) — sent only if the amount, currency and recipient match our record. **Never reached.**
- `POST /v1/payments/{id}/void` (**secret** key) — sent only if they do not match, to release the hold. **Never reached.**

A sixth call uses the secret key too: `GET /v1/payments/{id}` from our webhook
receiver, sent on every notification from you, because we re-read the payment
rather than trusting the notification body.

So the secret key has only ever been exercised on `GET /v1/payments/{id}`, and it
fails there. We cannot say capture or void are broken; they have never run.

### Our questions

1. Is the test-mode secret key on our account **currently active**? Has it been
   rotated or revoked?
2. You should see these 401s at the times above. **What reason is recorded on
   your side?** This is the most useful thing you can tell us, as we have
   exhausted what we can check ourselves.
3. Does our account need separate enablement for server-side API access, beyond
   publishable-key use from the app?
4. Is HTTP Basic with the key as username and an empty password still correct?
5. What is the correct way to issue a new test secret key **without** changing
   the publishable key the app currently uses?

### Why this blocks us

Our design never trusts the device. The app only **authorizes**; our server then
verifies the amount and recipient **with the secret key** before **capturing**.
Without a working secret key, payments sit at `authorized` and are never
captured, and we cannot complete testing.

Thank you.
