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
    body: "دفعتك لـ تمرين كرة قدم مؤكدة. نراك هناك! 🙌",
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
    body: "انفتح التسجيل لتمرين تمرين الأربعاء. احجز مكانك.",
  });
});

Deno.test("event_invited copy interpolates the event name", () => {
  const c = copyFor("event_invited", "تمرين الخميس");
  assertEquals(c, {
    title: "دعوة لتمرين ⚽",
    body: "دعاك المشرف لحضور تمرين الخميس. افتح التطبيق لتأكيد حضورك.",
  });
});

Deno.test("seat_available copy interpolates the event name", () => {
  const c = copyFor("seat_available", "تمرين الخميس");
  assertEquals(c, {
    title: "توفر مقعد الآن 🎟️",
    body: "توفر مقعد في تمرين الخميس. احجزه قبل ما يروح.",
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
    body: "ما سجّلت في تمرين الخميس بعد. احجز مكانك قبل ما تكتمل المقاعد.",
  });
});

Deno.test("event_capacity_progress uses early milestone copy", () => {
  const c = copyFor("event_capacity_progress", "التمرين الأسبوعي", {
    registered_count: 4,
    remaining_count: 12,
  });
  assertEquals(c, {
    title: "سجّل 4 🙌",
    body: "سجّل 4 في التمرين الأسبوعي. الحق مكانك.",
  });
});

Deno.test("event_capacity_progress uses middle milestone copy", () => {
  const c = copyFor("event_capacity_progress", "التمرين الأسبوعي", {
    registered_count: 8,
    remaining_count: 8,
  });
  assertEquals(c, {
    title: "صاروا 8 🔥",
    body: "الآن فيه 8 في التمرين الأسبوعي. لا يفوتك المكان.",
  });
});

Deno.test("event_capacity_progress includes the dynamic remaining count", () => {
  const c = copyFor("event_capacity_progress", "التمرين الأسبوعي", {
    registered_count: 12,
    remaining_count: 4,
  });
  assertEquals(c, {
    title: "صاروا 12 👀",
    body: "صار فيه 12 في التمرين الأسبوعي، وباقي 4 ويكتمل العدد.",
  });
});

Deno.test("event_capacity_progress has dedicated near-full copy", () => {
  const c = copyFor("event_capacity_progress", "التمرين الأسبوعي", {
    registered_count: 15,
    remaining_count: 1,
  });
  assertEquals(c, {
    title: "باقي مكان واحد 🔥",
    body: "العدد وصل 15 في التمرين الأسبوعي، وباقي واحد ويكتمل التمرين.",
  });
});

Deno.test("event_capacity_progress safely falls back without metadata", () => {
  const c = copyFor("event_capacity_progress", "التمرين الأسبوعي");
  assertEquals(c, {
    title: "التسجيل مستمر 🔥",
    body: "التسجيل مستمر في التمرين الأسبوعي. الحق مكانك قبل اكتمال العدد.",
  });
});

Deno.test("event_capacity_full interpolates the event name", () => {
  const c = copyFor("event_capacity_full", "التمرين الأسبوعي", {
    registered_count: 16,
    remaining_count: 0,
  });
  assertEquals(c, {
    title: "اكتمل العدد 🎉",
    body: "اكتمل العدد في التمرين الأسبوعي.",
  });
});

Deno.test("unknown type returns null", () => {
  assertEquals(copyFor("nope", "x"), null);
});
