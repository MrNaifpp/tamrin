//
//  ServerErrorMessage.swift
//  Sirr
//
//  What the person reads when the server refuses.
//
//  Every rule the database enforces raises in English, because that is where a
//  developer reads it. Those strings were going straight onto the screen under
//  an Arabic title, so a member who owed for last week was told "Previous event
//  payment is required" and left to work out what to do about it.
//
//  Two rules here. A refusal a member can actually reach gets Arabic that says
//  what to do next, not just what went wrong. Anything else — a rule only a
//  malformed request can trip, a provider string, a bug — gets the general
//  apology, because an English sentence from Postgres tells them nothing and
//  reads as a crash.
//

import Foundation

enum ServerErrorMessage {
    /// The fallback. Never show the raw text: if it is not in the table below,
    /// it is not a sentence anyone outside this repository can act on.
    static let general = String(localized: "تعذر إكمال العملية. حاول مرة أخرى.")

    static func arabic(for error: Error) -> String {
        // No connection is the most common failure of all, and it is not the
        // server refusing anything.
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return String(localized: "ما فيه اتصال بالإنترنت. تأكد من الشبكة وحاول مرة أخرى.")
            case .timedOut:
                return String(localized: "الاتصال تأخر. حاول مرة أخرى.")
            default:
                return String(localized: "تعذر الاتصال بالخادم. حاول مرة أخرى.")
            }
        }
        return arabic(forServerMessage: error.localizedDescription)
    }

    static func arabic(forServerMessage raw: String) -> String {
        let message = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty { return general }
        if let exact = table[message] { return exact }

        // Whole families differ only in which action they name, and the member
        // does not need to know which: the answer is the same either way.
        if message.hasPrefix("Not authorized") || message.hasPrefix("Only the ") {
            return String(localized: "هذا الإجراء للمشرف فقط.")
        }
        if message.hasPrefix("Not the ") {
            return String(localized: "هذا الإجراء لمنشئ التمرين فقط.")
        }
        return general
    }

    private static let table: [String: String] = [
        // Already Arabic, and already says what to do. Listed so nothing on the
        // way to the screen replaces it with the general apology.
        "عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل.":
            String(localized: "عليك قطة لم تُدفع من تمرين سابق. ادفعها أولاً عشان تسجّل."),

        // The one a member meets in ordinary use: he owes for a week that has
        // already happened. The sentence has to carry the way out, because the
        // registration he was trying to make stays refused until he declares.
        "Previous event payment is required":
            String(localized: "عندك قطة تمرين سابق ما أعلنت دفعها. افتح التمرين السابق واضغط «حوّلت المبلغ»، وبعدها تقدر تسجل."),

        // Registration and the exercise's own state.
        "Event has ended": String(localized: "انتهى هذا التمرين."),
        "Event is cancelled": String(localized: "هذا التمرين ملغى."),
        "Registration is closed for this event": String(localized: "التسجيل مقفل في هذا الموعد."),
        "This event closes at capacity and has no waiting list":
            String(localized: "اكتمل العدد، وما فيه قائمة انتظار لهذا الموعد."),
        "Series has ended": String(localized: "انتهت هذه السلسلة."),
        "Pending guest request must be resolved before self registration":
            String(localized: "عندك طلب ضيوف معلّق. أنهِه قبل ما تسجل نفسك."),
        "A guest must be added by a workspace member": String(localized: "الضيف لازم يضيفه عضو في التمرين."),
        "Guest registration mode is required": String(localized: "اختر طريقة تسجيل الضيوف."),
        "registration_not_open": String(localized: "التسجيل في هذا الموعد لم يفتح بعد."),
        "guests_not_allowed": String(localized: "تسجيل الضيوف موقف في هذا التمرين."),
        "approval_required": String(localized: "التسجيل في هذا التمرين بموافقة المشرف."),

        // Who you are, and where.
        "Not authenticated": String(localized: "انتهت جلستك. سجّل الدخول مرة ثانية."),
        "Not a workspace member": String(localized: "ما أنت عضو في هذا التمرين."),
        "Player is not a workspace member": String(localized: "هذا اللاعب مو عضو في التمرين."),
        "Invalid invite link": String(localized: "رابط الدعوة غير صالح."),
        "Event not found": String(localized: "ما لقينا الموعد. حدّث الصفحة وحاول مرة أخرى."),
        "Exercise not found": String(localized: "ما لقينا التمرين. حدّث الصفحة وحاول مرة أخرى."),
        "Workspace not found": String(localized: "ما لقينا التمرين. حدّث الصفحة وحاول مرة أخرى."),
        "Template not found": String(localized: "ما لقينا قالب التمرين."),
        "Owner cannot leave the workspace; delete it instead":
            String(localized: "المشرف ما يقدر يغادر تمرينه. احذف التمرين بدل كذا."),
        "Owner cannot remove themselves; delete the workspace instead":
            String(localized: "المشرف ما يقدر يشيل نفسه. احذف التمرين بدل كذا."),
        "Event creator cannot leave their own event": String(localized: "ما تقدر تغادر موعدًا أنت منشئه."),
        "Workspace owner cannot decline an event they administer":
            String(localized: "ما تقدر تعتذر عن موعد أنت مشرفه."),

        // What the organizer is told while filling a form in.
        "Workspace name is required": String(localized: "اسم التمرين مطلوب."),
        "Event name is required": String(localized: "اسم الموعد مطلوب."),
        "Event end must be after its start": String(localized: "وقت النهاية لازم يكون بعد وقت البداية."),
        "Total price cannot be negative": String(localized: "المبلغ ما يصير بالسالب."),
        "Player count must be greater than zero": String(localized: "عدد اللاعبين لازم يكون أكبر من صفر."),
        "Player count is required when total price is greater than zero":
            String(localized: "حدد عدد اللاعبين حتى نحسب قطة كل واحد."),
        "A payment method is required when total price is greater than zero":
            String(localized: "أضف طريقة دفع، لأن على التمرين قطة."),
        "Workspace sport symbol is invalid": String(localized: "اختر رياضة التمرين."),
        "Reason text is too long": String(localized: "السبب طويل. اختصره شوي."),

        // Payment destinations.
        "A valid Saudi mobile number is required": String(localized: "أدخل رقم جوال سعودي صحيح."),
        "A valid Saudi IBAN is required": String(localized: "أدخل آيبان سعودي صحيح."),
        "Account number must contain 6 to 24 digits": String(localized: "رقم الحساب لازم يكون من 6 إلى 24 رقمًا."),
        "Mobile wallet methods only accept a mobile number": String(localized: "محفظة الجوال تقبل رقم جوال فقط."),
        "Bank methods do not accept a mobile number": String(localized: "التحويل البنكي ما يقبل رقم جوال."),
        "Cash does not accept destination details": String(localized: "الدفع في الملعب ما يحتاج تفاصيل تحويل."),
        "Payment providers must be unique": String(localized: "ما ينفع تكرر نفس وسيلة الدفع."),
        "Unsupported payment provider": String(localized: "وسيلة الدفع هذي غير مدعومة."),
        "Unable to save payment method": String(localized: "ما قدرنا نحفظ طريقة الدفع. حاول مرة أخرى."),
        "Payment method does not belong to the event workspace":
            String(localized: "طريقة الدفع هذي مو تابعة لهذا التمرين."),

        // The lineup.
        "There is no lineup to publish yet": String(localized: "ما فيه تشكيلة تنشرها بعد."),
        "Every player in a lineup must hold a seat in this exercise":
            String(localized: "كل لاعب في التشكيلة لازم يكون مسجلًا في الموعد."),
        "A player cannot hold two places in one lineup": String(localized: "اللاعب ما يجي في الفريقين."),

        // Reachable by an organizer: the RPC folds "not found" and "not yours"
        // into one refusal so it cannot be used to probe for other people's
        // exercises. The Arabic keeps them folded for the same reason.
        "Event not found or you are not the creator":
            String(localized: "ما لقينا الموعد، أو ما أنت منشئه."),
        "Event not found or you are not the workspace owner":
            String(localized: "ما لقينا الموعد، أو ما أنت مشرف التمرين."),
        "Event not found, cancelled, or you are not the workspace owner":
            String(localized: "ما لقينا الموعد، أو هو ملغى، أو ما أنت مشرف التمرين."),
        "Only a manually added registration can be removed this way":
            String(localized: "هذا التسجيل ما ينشال بهذي الطريقة. شيله من قائمة المسجلين."),

        // Deleting an account while a shared exercise still depends on you.
        "OWNS_SHARED_WORKSPACE":
            String(localized: "عندك تمرين فيه أعضاء آخرين. احذف التمرين أو انقل ملكيته أولًا، ثم احذف الحساب.")
    ]
}
