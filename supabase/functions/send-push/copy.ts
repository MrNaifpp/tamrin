// type -> Arabic notification copy. This is the ONLY place push wording lives.
//
// No em dashes in any of it. Arabic joins clauses with «و» or ends them with a
// full stop; the dash is an English habit that reads as a foreign mark here.
// Dynamic values come from the authoritative outbox row rather than from the
// caller that invokes the Edge Function.
type PushMetadata = Record<string, unknown> | null | undefined;

function nonnegativeInteger(
  metadata: PushMetadata,
  key: string,
): number | null {
  if (!metadata || typeof metadata !== "object") return null;
  const value = metadata[key];
  return typeof value === "number" &&
      Number.isSafeInteger(value) &&
      value >= 0
    ? value
    : null;
}

export function copyFor(
  type: string,
  eventName: string,
  metadata?: PushMetadata,
): { title: string; body: string } | null {
  const displayName = eventName.trim() || "التمرين";

  switch (type) {
    case "payment_submitted":
      return {
        title: "طلب انضمام جديد 🎉",
        body: `وصلك طلب دفع جديد لـ ${eventName}. راجعه وأكّده 👍`,
      };
    case "payment_confirmed":
      return {
        title: "اشتراكك مؤكد 🎉",
        body: `دفعتك لـ ${eventName} مؤكدة. نراك هناك! 🙌`,
      };
    case "payment_rejected":
      return {
        title: "تحديث بخصوص دفعتك",
        body: `لم يتمكّن المنظّم من تأكيد دفعتك لـ ${eventName}. تواصل معه لمعرفة التفاصيل.`,
      };
    case "registration_reminder":
      return {
        title: "باقي مكانك ⚽",
        body: `ما سجّلت في ${eventName} بعد. احجز مكانك قبل ما تكتمل المقاعد.`,
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
        body: `انفتح التسجيل لتمرين ${eventName}. احجز مكانك.`,
      };
    case "event_invited":
      return {
        title: "دعوة لتمرين ⚽",
        body: `دعاك المشرف لحضور ${eventName}. افتح التطبيق لتأكيد حضورك.`,
      };
    case "seat_available":
      return {
        title: "توفر مقعد الآن 🎟️",
        body: `توفر مقعد في ${eventName}. احجزه قبل ما يروح.`,
      };
    case "event_capacity_progress": {
      const registered = nonnegativeInteger(metadata, "registered_count");
      const remaining = nonnegativeInteger(metadata, "remaining_count");

      // Keep the notification useful if an old/malformed outbox row does not
      // contain the new metadata. Never expose "undefined" to the member.
      if (registered === null || remaining === null) {
        return {
          title: "التسجيل مستمر 🔥",
          body: `التسجيل مستمر في ${displayName}. الحق مكانك قبل اكتمال العدد.`,
        };
      }

      if (remaining === 1) {
        return {
          title: "باقي مكان واحد 🔥",
          body:
            `العدد وصل ${registered} في ${displayName}، وباقي واحد ويكتمل التمرين.`,
        };
      }

      const capacity = registered + remaining;
      const fillRatio = capacity > 0 ? registered / capacity : 0;
      if (fillRatio <= 0.25) {
        return {
          title: `سجّل ${registered} 🙌`,
          body: `سجّل ${registered} في ${displayName}. الحق مكانك.`,
        };
      }
      if (fillRatio <= 0.5) {
        return {
          title: `صاروا ${registered} 🔥`,
          body: `الآن فيه ${registered} في ${displayName}. لا يفوتك المكان.`,
        };
      }
      if (fillRatio <= 0.75) {
        return {
          title: `صاروا ${registered} 👀`,
          body:
            `صار فيه ${registered} في ${displayName}، وباقي ${remaining} ويكتمل العدد.`,
        };
      }
      return {
        title: "قرب يكتمل العدد 🔥",
        body:
          `العدد وصل ${registered} في ${displayName}، وباقي ${remaining} ويكتمل العدد.`,
      };
    }
    case "event_capacity_full":
      return {
        title: "اكتمل العدد 🎉",
        body: `اكتمل العدد في ${displayName}.`,
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
