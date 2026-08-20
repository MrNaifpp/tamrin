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
    title: "اشتراكك مؤكد 🎉",
    body: "دفعتك لـ تمرين كرة قدم مؤكدة — نراك هناك! 🙌",
  });
});

Deno.test("payment_rejected copy interpolates the event name", () => {
  const c = copyFor("payment_rejected", "تمرين كرة قدم");
  assertEquals(c, {
    title: "تحديث بخصوص دفعتك",
    body: "لم يتمكّن المنظّم من تأكيد دفعتك لـ تمرين كرة قدم. تواصل معه لمعرفة التفاصيل.",
  });
});

Deno.test("event_reminder copy interpolates the event name", () => {
  const c = copyFor("event_reminder", "تمرين كرة قدم");
  assertEquals(c, {
    title: "تذكير بتمرينك ⏰",
    body: "لا تنسَ تمرين كرة قدم القادم. نراك هناك! 🙌",
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
    title: "دعوة لتمرين ⚽",
    body: "دعاك المشرف لحضور تمرين الخميس — افتح التطبيق لتأكيد حضورك.",
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
    body: "ما سجّلت في تمرين الخميس بعد — احجز مكانك قبل ما تكتمل المقاعد.",
  });
});

Deno.test("waitlist_promoted copy interpolates the event name", () => {
  const c = copyFor("waitlist_promoted", "تمرين الخميس");
  assertEquals(c, {
    title: "تحرر مقعد — أنت داخل 🎉",
    body: "انضممت من قائمة الانتظار إلى تمرين الخميس. نراك هناك! 🙌",
  });
});

Deno.test("member_declined copy interpolates the event name", () => {
  const c = copyFor("member_declined", "تمرين الخميس");
  assertEquals(c, {
    title: "اعتذار عن التمرين",
    body: "اعتذر أحد اللاعبين عن تمرين الخميس. افتح التمرين لمراجعة القائمة.",
  });
});

Deno.test("unknown type returns null", () => {
  assertEquals(copyFor("nope", "x"), null);
});
