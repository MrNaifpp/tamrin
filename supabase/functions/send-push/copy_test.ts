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
    title: "تم تأكيد اشتراكك 🎉",
    body: "تم تأكيد دفعتك لـ تمرين كرة قدم — نراك هناك! 🙌",
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

Deno.test("unknown type returns null", () => {
  assertEquals(copyFor("nope", "x"), null);
});
