// type -> Arabic notification copy. This is the ONLY place push wording lives.
//
// No em dashes in any of it. Arabic joins clauses with «و» or ends them with a
// full stop; the dash is an English habit that reads as a foreign mark here.
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
    case "payment_declared":
      return {
        title: "قطة بانتظار تأكيدك 💸",
        body: `لاعب يقول إنه حوّل قطة ${eventName}. راجعها وأكّدها 👍`,
      };
    case "payment_confirmed":
      return {
        title: "قطتك وصلت 💵",
        body: `أكد المشرف قطتك لـ ${eventName} وأمورك طيبة`,
      };
    case "payment_rejected":
      return {
        title: "تحديث بخصوص قطتك",
        body: `ما قدر المشرف يأكد قطتك لـ ${eventName}. تواصل معه لمعرفة التفاصيل.`,
      };
    case "registration_reminder":
      return {
        title: "باقي مكانك ⚽",
        body: `باقي ما سجّلت في ${eventName}، احجز مكانك قبل ما تكتمل المقاعد.`,
      };
    case "payment_reminder":
      return {
        title: "تذكير بالقطة 💸",
        body: `المشرف يذكّرك بقطة ${eventName}. سدّدها قبل الموعد 🙏`,
      };
    case "event_reminder":
      return {
        title: "تذكير بتمرينك ⏰",
        body: `لا تنسى ${eventName} القادم. نشوفك في الملعب🏃‍♂️`,
      };
    case "event_opened":
      return {
        title: "انفتح التسجيل ⚽",
        body: `انفتح التسجيل لتمرين ${eventName}. احجز مكانك.`,
      };
    case "event_invited":
      return {
        title: "جتك دعوة للتمرين ⚽",
        body: `دعاك المشرف لحضور ${eventName}، افتح التطبيق لتأكيد حضورك.`,
      };
    case "event_fill_25":
      return {
        title: "التمرين بدأ يمتلئ ⚽",
        body: `ربع مقاعد ${eventName} انحجزت`,
      };
    case "event_fill_50":
      return {
        title: "نص العدد اكتمل 🔥",
        body: `نص مقاعد ${eventName} انحجزت`,
      };
    case "event_fill_75":
      return {
        title: "٣ أرباع المقاعد راحت ⏳",
        body: `${eventName} قارب يكتمل. باقي ربع المقاعد.`,
      };
    case "event_full":
      return {
        title: "اكتمل العدد 🎉",
        body: `امتلأت مقاعد ${eventName}`,
      };
    case "seat_available":
      return {
        title: "توفر مقعد الآن 🎟️",
        body: `توفر مقعد في ${eventName}. احجزه قبل ما يروح.`,
      };
    case "waitlist_promoted":
      return {
        title: "لاعب اعتذر، أنت في القائمة✨",
        body: "انضممت من قائمة الانتظار إلى القائمة الرئيسية. جهز عمرك 🏃‍♂️",
      };
    case "member_declined":
      return {
        title: "اعتذر لاعب 🏳️",
        body: `اعتذر أحد اللاعبين عن ${eventName}، افتح التمرين لمراجعة القائمة.`,
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
