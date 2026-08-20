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
        title: "اشتراكك مؤكد 🎉",
        body: `دفعتك لـ ${eventName} مؤكدة — نراك هناك! 🙌`,
      };
    case "payment_rejected":
      return {
        title: "تحديث بخصوص دفعتك",
        body: `لم يتمكّن المنظّم من تأكيد دفعتك لـ ${eventName}. تواصل معه لمعرفة التفاصيل.`,
      };
    case "registration_reminder":
      return {
        title: "باقي مكانك ⚽",
        body: `ما سجّلت في ${eventName} بعد — احجز مكانك قبل ما تكتمل المقاعد.`,
      };
    case "payment_reminder":
      return {
        title: "تذكير بالقطة 💸",
        body: `المشرف يذكّرك بقطة ${eventName}. سدّدها قبل الموعد 🙏`,
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
    case "waitlist_promoted":
      return {
        title: "تحرر مقعد — أنت داخل 🎉",
        body: `انضممت من قائمة الانتظار إلى ${eventName}. نراك هناك! 🙌`,
      };
    case "member_declined":
      return {
        title: "اعتذار عن التمرين",
        body: `اعتذر أحد اللاعبين عن ${eventName}. افتح التمرين لمراجعة القائمة.`,
      };
    case "event_cancelled":
      return {
        title: "تمرين هذا الأسبوع متخطّى",
        body: `أُلغي ${eventName}. افتح التمرين لمعرفة السبب والتفاصيل.`,
      };
    default:
      return null;
  }
}
