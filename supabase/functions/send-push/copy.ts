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
    case "event_reminder":
      return {
        title: "تذكير بتمرينك ⏰",
        body: `لا تنسَ ${eventName} القادم. نراك هناك! 🙌`,
      };
    case "event_opened":
      return {
        title: "انفتح التسجيل ⚽",
        body: `انفتح التسجيل لتمرين ${eventName} — احجز مكانك`,
      };
    case "event_invited":
      return {
        title: "دعوة لتمرين ⚽",
        body: `دعاك المشرف لحضور ${eventName} — افتح التطبيق لتأكيد حضورك.`,
      };
    case "event_cancelled":
      return {
        title: "تم تخطي تمرين هذا الأسبوع",
        body: `أُلغي ${eventName}. افتح التمرين لمعرفة السبب والتفاصيل.`,
      };
    default:
      return null;
  }
}
