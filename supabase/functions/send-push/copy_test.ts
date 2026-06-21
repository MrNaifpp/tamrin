import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { copyFor } from "./copy.ts";

Deno.test("payment_submitted copy interpolates the event name", () => {
  const c = copyFor("payment_submitted", "تمرين كرة قدم");
  assertEquals(c, { title: "طلب دفع جديد", body: "طلب دفع جديد لحدث تمرين كرة قدم" });
});

Deno.test("unknown type returns null", () => {
  assertEquals(copyFor("nope", "x"), null);
});
