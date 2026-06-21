// type -> Arabic notification copy. This is the ONLY place push wording lives.
export function copyFor(
  type: string,
  eventName: string,
): { title: string; body: string } | null {
  switch (type) {
    case "payment_submitted":
      return {
        title: "طلب انضمام جديد 🎉",
        body: `وصلك طلب دفع جديد لـ ${eventName}. راجعه وأكّده 👍`,
      };
    case "payment_confirmed":
      return {
        title: "تم تأكيد اشتراكك 🎉",
        body: `تم تأكيد دفعتك لـ ${eventName} — نراك هناك! 🙌`,
      };
    case "payment_rejected":
      return {
        title: "تحديث بخصوص دفعتك",
        body: `لم يتمكّن المنظّم من تأكيد دفعتك لـ ${eventName}. تواصل معه لمعرفة التفاصيل.`,
      };
    default:
      return null;
  }
}
