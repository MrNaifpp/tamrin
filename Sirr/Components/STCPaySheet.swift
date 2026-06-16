//
//  STCPaySheet.swift
//  Sirr
//
//  Joiner sheet shown after submit_payment succeeds. Displays the creator's
//  STC Pay number + amount and a primary "I sent it" dismiss button. The
//  pending event_participants row has already been created by submit_payment
//  — this sheet is informational.
//

import SwiftUI

struct STCPaySheet: View {
    let eventName: String
    let amount: Double
    let stcPayNumber: String

    @Environment(\.dismiss) private var dismiss

    @State private var showCopiedToast = false

    private var prettyNumber: String { STCPay.displayForm(stcPayNumber) }

    var body: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 12)

                Spacer().frame(height: 20)

                Text("ادفع عبر STC Pay")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)

                Text(eventName)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(white: 0.7))
                    .padding(.top, 4)

                // Amount card
                VStack(spacing: 4) {
                    Text("المبلغ")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.6))
                    Text(String(format: "%.0f ر.س", amount))
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .padding(.horizontal, 20)
                .padding(.top, 28)

                // STC Pay number card with copy
                VStack(spacing: 8) {
                    Text("أرسل إلى رقم STC Pay")
                        .font(.system(size: 13))
                        .foregroundStyle(Color(white: 0.6))

                    HStack(spacing: 12) {
                        Text(prettyNumber)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)

                        Button {
                            #if canImport(UIKit)
                            UIPasteboard.general.string = stcPayNumber
                            #endif
                            withAnimation { showCopiedToast = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation { showCopiedToast = false }
                            }
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .background(Color.white.opacity(0.15))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
                .padding(.horizontal, 20)
                .padding(.top, 16)

                // Steps reminder
                VStack(alignment: .trailing, spacing: 8) {
                    stepRow(index: 1, text: "افتح تطبيق STC Pay وأرسل المبلغ للرقم أعلاه.")
                    stepRow(index: 2, text: "ارجع لتمرين واضغط \"أرسلت المبلغ\".")
                    stepRow(index: 3, text: "سيؤكد صاحب الفعالية الدفعة، وستظهر لك بحالة \"مؤكد\".")
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer()

                // Primary action
                Button {
                    dismiss()
                } label: {
                    Text("أرسلت المبلغ")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .background(
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .fill(Color.white)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }

            if showCopiedToast {
                VStack {
                    Spacer()
                    Text("تم نسخ الرقم")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(Color.black.opacity(0.7))
                        )
                        .padding(.bottom, 120)
                }
                .transition(.opacity)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
    }

    private func stepRow(index: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(Color(white: 0.85))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ZStack {
                Circle().fill(Color.white.opacity(0.15)).frame(width: 24, height: 24)
                Text("\(index)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
    }
}

#if DEBUG
#Preview {
    STCPaySheet(eventName: "تمرين كرة قدم", amount: 50, stcPayNumber: "+966512345678")
}
#endif
