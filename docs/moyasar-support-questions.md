# Moyasar support — questions before building on splits

Everything here is blocked on Moyasar, not on us. Send this, then implement.

**Where to send:** `support@moyasar.com`, or the dashboard helpdesk. Question 1 and
question 4 are commercial, so sales may need to answer those — say so up front and
ask them to route it.

**Before sending:** fill in the account name / merchant id in the first line.
**Never** paste an `sk_` secret key into a support ticket.

---

## Arabic (send this one)

**الموضوع:** تفعيل Split Payments وتسجيل المستلمين — حساب `<اسم الحساب / رقم التاجر>`

السلام عليكم ورحمة الله،

نطوّر تطبيق iOS باسم **تمرين** لتنظيم التمارين الرياضية الجماعية. المنظّم ينشئ
تمرينًا برسم اشتراك، واللاعبون يدفعون حصصهم. اليوم يتم الدفع بتحويل بنكي يدوي،
ونريد الانتقال إلى الدفع بالبطاقة عبر Moyasar بحيث **يصل المبلغ إلى حساب المنظّم
نفسه** لا إلى حسابنا — أي عبر Split Payments.

حسابنا في وضع الاختبار، وأنشأنا فاتورة تجريبية بنجاح. الأسئلة التالية لم نجد لها
إجابة في الوثائق، وبعضها تجاري فنرجو تحويله للجهة المختصة.

**١. نوع الحساب**

وثائقكم تفرّق بين *aggregation merchants* و *facilitation merchants*، وتنص أن
Transfers API "حصري لتجّار التجميع". هل حسابنا مسجّل كـ aggregation merchant؟
وإن لم يكن، ما إجراءات التحويل ومتطلباته؟

**٢. تفعيل Split Payments على حسابنا**

عند إرسال `splits` إلى `POST /v1/payments` بمعرّف مستلم وهمي، يرجع:

```
400 validation_error
"splits.0.recipient_id": ["Must be a valid recipient (Entity, Platform or Beneficiary) UUID."]
```

هذا يثبت أن الـ API يعرف الحقل، لكنه لا يثبت أن حسابنا **مخوّل** باستخدامه، لأن
التحقق من صحة الحقول يسبق التحقق من الصلاحيات.

**سؤالنا: هل ميزة splits مفعّلة على حسابنا لإرسال مدفوعات مقسّمة؟**

نلاحظ في صفحة Create Payment ملاحظة داخل قسم الاستجابة:
> "This field is returned for entities created after 2025-10, if you need to
> recieve it, please contact support team."

نفهم أنها تخص **ظهور الحقل في الاستجابة**. نرجو توضيح ما إذا كانت تنطبق كذلك على
**إرسال** الأقسام.

**٣. كيف يُنشأ `recipient_id`؟**

لم نجد في وثائقكم أي endpoint لإنشاء أو سرد Entities أو Beneficiaries أو
Recipients — والحقل يظهر في استجابات القراءة فقط (`/settlements/:id/lines`
و `/transfers`). كما أن `POST /v1/payouts` يستقبل الوجهة **مضمّنة**
(IBAN والاسم) دون كائن مستفيد له معرّف.

- ما الطريقة الرسمية للحصول على `recipient_id` صالح؟
- هل تتم عبر الـ Dashboard، أم من طرفكم يدويًا، أم عبر API غير موثّق؟
- هل يمكن أتمتتها؟ نتوقع تسجيل عدد كبير من المنظّمين، والإدخال اليدوي لكل واحد
  لا يتوسّع.

**٤. تسجيل الأفراد كمستلمين — الأهم بالنسبة لنا**

جمهورنا أفراد ينظّمون تمارين لأصدقائهم، وغالبيتهم بلا سجل تجاري. في أسئلتكم
الشائعة: "سجل تجاري سعودي ساري **أو وثيقة عمل حر**، وحساب بنكي تجاري مرتبط به".

- هل يُقبل صاحب **وثيقة العمل الحر** مستلمًا لـ splits؟
- ما المستندات المطلوبة بالضبط، وكم يستغرق الاعتماد؟
- هل يوجد حد أدنى لحجم المعاملات أو رسوم ثابتة على المستلم؟ (المبالغ صغيرة —
  غالبًا ٣٠ إلى ٨٠ ريالًا للاعب الواحد.)

**٥. قيود غير موثّقة على `splits`**

- هل يجب أن يساوي مجموع الأقسام مبلغ الدفعة تمامًا؟
- هل يجب إدراج حصة المنصة كقسم صريح، أم يُحتسب الباقي تلقائيًا؟
- هل يجب أن يحمل قسم واحد بالضبط `fee_source: true`؟ وماذا يحدث إن لم يُحدَّد؟
- ما الحد الأقصى لعدد الأقسام في الدفعة الواحدة؟

**٦. `splits` مع التفويض اليدوي**

نعتمد `manual: true` كضمانة أمنية: التطبيق يفوّض، ثم خادمنا يتحقق من المبلغ
والمستلم بالمفتاح السري قبل التحصيل، ويُبطل عند أي اختلاف.

- هل تعمل `splits` مع التفويض اليدوي؟
- هل تُطبَّق الأقسام كما فُوّضت عند الـ capture، أم يمكن تعديلها عنده؟

**٧. توقيت التسوية للمستلمين**

متى يصل المبلغ فعليًا إلى مستلم الـ split؟ هل ينطبق شرط "٧ أيام عمل من بلوغ
الرصيد ١٠٠ ريال" الوارد في شروط المنصة؟ نحتاج معرفة ذلك لنضبط توقعات المنظّمين،
لأن التحويل البنكي اليوم فوري.

**٨. نموذج البائع الأصيل (merchant of record) — هل تسمحون به؟**

كبديل عن splits: هل تسمحون بأن تحصّل تمرين كامل المبلغ على حسابها، ثم تصرف
حصص المنظّمين عبر Payouts API؟

نسأل لأن شروط التاجر لديكم (المادة الخامسة، ١٤) تمنع "السماح باستخدام خدمة
التجارة الإلكترونية من قِبل أي طرف ثالث أو بالنيابة عنه"، والمادة (١١) تجعل
التاجر هو البائع المسؤول عن الخدمة وعن خدمة عملائها. كما تنص شروط المنصة
(١٦.٢) على أن التسوية تذهب **مباشرة إلى الحساب البنكي للتاجر المستفيد**.

- هل يوجد ترتيب معتمد لديكم يسمح بهذا النموذج، وبأي شروط؟
- هل يتطلب نشاطًا محددًا في السجل التجاري أو موافقة مسبقة؟
- من يتحمل الـ chargeback إذا اعترض اللاعب بعد صرف حصة المنظّم؟

نطرح السؤال لنستبعد الخيار أو نعتمده بوضوح، لا لنفترض جوابًا.

شكرًا لتعاونكم.

---

## English (attach or send if they prefer)

**Subject:** Enabling split payments and onboarding recipients — account
`<account name / merchant id>`

Hello,

We are building an iOS app, **Tamrin**, for organising group sports sessions. An
organiser creates a session with a fee and players pay their share. Today that is a
manual bank transfer; we want to move to card payments through Moyasar so the money
lands in **the organiser's own account**, not ours — i.e. via split payments.

Our account is in test mode and we have successfully created a test invoice. The
following are not answered in the documentation. Questions 1 and 4 are commercial —
please route them as needed.

**1. Account type.** Your docs distinguish aggregation merchants from facilitation
merchants, and state the Transfers API is "exclusively available for Moyasar
aggregation merchants". Is our account an aggregation merchant? If not, what is the
process to become one?

**2. Is `splits` enabled for our account?** Sending `splits` to `POST /v1/payments`
with a dummy recipient returns:

```
400 validation_error
"splits.0.recipient_id": ["Must be a valid recipient (Entity, Platform or Beneficiary) UUID."]
```

That proves the API knows the field, but not that our account is entitled to use it,
since field validation precedes entitlement checks. Please confirm whether we may
**send** split payments.

The Create Payment page notes, in the response section: *"This field is returned for
entities created after 2025-10, if you need to recieve it, please contact support
team."* We read that as governing response visibility — does it also apply to
sending?

**3. How is a `recipient_id` created?** We found no endpoint to create or list
entities, beneficiaries or recipients; the field appears only in read responses
(`/settlements/:id/lines`, `/transfers`). `POST /v1/payouts` takes the destination
inline (IBAN, name) with no stored beneficiary object.

- What is the official way to obtain a valid `recipient_id`?
- Dashboard, manual on your side, or an undocumented API?
- Can it be automated? We expect to onboard many organisers.

**4. Onboarding individuals as recipients — most important for us.** Our users are
individuals organising sessions for friends; most have no commercial registration.
Your FAQ states a valid Saudi CR **or freelance license**, plus a linked Saudi
commercial bank account.

- Can a holder of a freelance license (وثيقة العمل الحر) be a split recipient?
- Exactly which documents, and what is the approval time?
- Any minimum transaction volume or fixed fees on the recipient? Amounts are small —
  typically SAR 30–80 per player.

**5. Undocumented `splits` constraints.** Must split amounts sum exactly to the
payment amount? Must the platform share be an explicit split, or is the remainder
implicit? Must exactly one split set `fee_source: true`, and what happens if none
does? Is there a maximum number of splits?

**6. `splits` with manual authorization.** We rely on `manual: true`: the app
authorizes, our server verifies amount and recipient with the secret key, then
captures — or voids on any mismatch. Do splits work with manual authorization, and
are they applied at capture exactly as authorized?

**7. Settlement timing.** When do funds actually reach a split recipient? Does the
"7 business days once the balance reaches SAR 100" clause from the platform terms
apply? Bank transfers are instant today, so we need to set organiser expectations.

Thank you.

---

## What each answer unblocks

| Q | If the answer is bad | Effect on the build |
|---|---|---|
| 1 | Not an aggregation merchant, cannot become one | Splits are off the table entirely; revisit the money-flow decision |
| 2 | Splits not enabled | Card payments cannot reach an organiser; everything else still ships |
| 3 | Manual, no API | `workspace_moyasar_recipients` is operator-filled — already assumed in the design |
| 4 | Freelance license not accepted | Card payment serves only registered businesses — a product decision, not a code one |
| 5 | Strict summing rules | Only changes the splits builder in `create-payment` |
| 6 | Splits don't compose with `manual` | Fall back to server-created invoices — see "Risks" in the design |
| 7 | Slow settlement | Organiser-facing copy must set expectations; no code impact |
| 8 | Merchant-of-record refused | Closes the "Tamrin collects everything" alternative for good — worth knowing before anyone spends legal fees on it |

Design: [`docs/superpowers/specs/2026-09-06-moyasar-payments-design.md`](superpowers/specs/2026-09-06-moyasar-payments-design.md)
