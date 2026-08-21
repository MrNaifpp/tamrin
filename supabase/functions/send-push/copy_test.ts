import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { copyFor } from "./copy.ts";

Deno.test("payment_submitted copy interpolates the event name", () => {
  const c = copyFor("payment_submitted", "تمرين كرة قدم");
  assertEquals(c, {
    title: "طلب انضمام جديد 🎉",
    body: "وصلك طلب دفع جديد لـ تمرين كرة قدم. راجعه وأكّده 👍",
  });
});

Deno.test("payment_confirmed copy interpolates the event name", () => {
  const c = copyFor("payment_confirmed", "تمرين كرة قدم");
  assertEquals(c, {
    title: "قطتك وصلت 💵",
    body: "أكد المشرف قطتك لـ تمرين كرة قدم وأمورك طيبة",
  });
});

Deno.test("payment_rejected copy interpolates the event name", () => {
  const c = copyFor("payment_rejected", "تمرين كرة قدم");
  assertEquals(c, {
    title: "تحديث بخصوص قطتك",
    body: "ما قدر المشرف يأكد قطتك لـ تمرين كرة قدم. تواصل معه لمعرفة التفاصيل.",
  });
});

Deno.test("event_reminder copy interpolates the event name", () => {
  const c = copyFor("event_reminder", "تمرين كرة قدم");
  assertEquals(c, {
    title: "تذكير بتمرينك ⏰",
    body: "لا تنسى تمرين كرة قدم القادم. نشوفك في الملعب🏃‍♂️",
  });
});

Deno.test("event_opened copy interpolates the event name", () => {
  const c = copyFor("event_opened", "تمرين الأربعاء");
  assertEquals(c, {
    title: "انفتح التسجيل ⚽",
    body: "انفتح التسجيل لتمرين تمرين الأربعاء — احجز مكانك",
  });
});

Deno.test("event_invited copy interpolates the event name", () => {
  const c = copyFor("event_invited", "تمرين الخميس");
  assertEquals(c, {
    title: "جتك دعوة للتمرين ⚽",
    body: "دعاك المشرف لحضور تمرين الخميس، افتح التطبيق لتأكيد حضورك.",
  });
});

Deno.test("event_cancelled copy interpolates the event name", () => {
  const c = copyFor("event_cancelled", "تمرين الخميس");
  assertEquals(c, {
    title: "تمرين هذا الأسبوع متخطّى",
    body: "أُلغي تمرين الخميس. افتح التمرين لمعرفة السبب والتفاصيل.",
  });
});

Deno.test("payment_reminder copy interpolates the event name", () => {
  const c = copyFor("payment_reminder", "تمرين الخميس");
  assertEquals(c, {
    title: "تذكير بالقطة 💸",
    body: "المشرف يذكّرك بقطة تمرين الخميس. سدّدها قبل الموعد 🙏",
  });
});

Deno.test("registration_reminder copy interpolates the event name", () => {
  const c = copyFor("registration_reminder", "تمرين الخميس");
  assertEquals(c, {
    title: "باقي مكانك ⚽",
    body: "باقي ما سجّلت في تمرين الخميس، احجز مكانك قبل ما تكتمل المقاعد.",
  });
});

Deno.test("payment_declared copy interpolates the event name", () => {
  const c = copyFor("payment_declared", "تمرين كرة قدم");
  assertEquals(c, {
    title: "قطة بانتظار تأكيدك 💸",
    body: "لاعب يقول إنه حوّل قطة تمرين كرة قدم. راجعها وأكّدها 👍",
  });
});

Deno.test("waitlist_promoted copy does not need the event name", () => {
  const c = copyFor("waitlist_promoted", "تمرين الخميس");
  assertEquals(c, {
    title: "لاعب اعتذر، أنت في القائمة✨",
    body: "انضممت من قائمة الانتظار إلى القائمة الرئيسية. جهز عمرك 🏃‍♂️",
  });
});

Deno.test("member_declined copy interpolates the event name", () => {
  const c = copyFor("member_declined", "تمرين الخميس");
  assertEquals(c, {
    title: "اعتذر لاعب 🏳️",
    body: "اعتذر أحد اللاعبين عن تمرين الخميس، افتح التمرين لمراجعة القائمة.",
  });
});

Deno.test("unknown type returns null", () => {
  assertEquals(copyFor("nope", "x"), null);
});
