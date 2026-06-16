//
//  NewEventView.swift
//  Sirr
//
//  Created for adding new events
//

import SwiftUI
import MapKit
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

struct NewEventView: View {
    @Environment(\.dismiss) var dismiss
    
    // Form state
    @State private var exerciseName: String = ""
    @State private var exerciseLocation: String = ""
    @State private var description: String = ""
    @State private var startDate: Date? = nil
    @State private var endDate: Date? = nil
    @State private var selectedImageResource: ImageResource? = nil
    @State private var fieldValue: Int = 0
    @State private var numberOfPeople: Int = 0
    @State private var pricePerUnit: String = "00 إ"
    @State private var playerApprovalEnabled: Bool = false
    @State private var showPriceDialog: Bool = false
    @State private var showPeopleDialog: Bool = false
    @State private var showStartDateDialog: Bool = false
    @State private var showEndDateDialog: Bool = false
    @State private var showLocationDialog: Bool = false
    @State private var showImageSelectionDialog: Bool = false
    @State private var isCreating = false
    @State private var createError: String? = nil
    @State private var tempPriceValue: String = ""
    @State private var tempPeopleValue: String = ""
    @State private var tempLocationValue: String = ""

    // STC Pay guardrail state — shown when user tries to save a paid event without a profile number.
    @State private var showSTCPayGuardrail: Bool = false
    @State private var guardrailInput: String = ""
    @State private var guardrailError: String? = nil
    @State private var isSavingGuardrailNumber = false
    
    // Map location selection state
    @State private var selectedCoordinate: CLLocationCoordinate2D? = nil
    @State private var currentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 24.7136, longitude: 46.6753), // Riyadh default
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
    )
    @State private var searchResults: [MKMapItem] = []
    @State private var searchText: String = ""
    @State private var isSearching: Bool = false
    @State private var locationManager: CLLocationManager = CLLocationManager()
    @State private var isGeocoding: Bool = false

    
    // Form validation
    var isFormValid: Bool {
        !exerciseName.isEmpty &&
        !exerciseLocation.isEmpty &&
        !description.isEmpty &&
        fieldValue > 0 &&
        numberOfPeople > 0
    }
    
    // Date formatter helper
    private var dateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ar_SA")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
    
    var body: some View {
        ZStack {
            // Gradient background
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.55, green: 0.23, blue: 0.36), // Reddish-purple
                    Color(red: 0.10, green: 0.30, blue: 0.23)  // Dark green
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            
            ScrollView {
                Spacer()
                imageSelectionSection
                inputField
                    .padding(.horizontal,16).padding(.vertical,6)
                     Button {
                    tempLocationValue = exerciseLocation
                    showLocationDialog = true
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .fill(.white.opacity(0.1))
                            .frame(height: 60)
                        
                        HStack { 
                            if exerciseLocation.isEmpty {
                                Text("موقع التمرين")
                                    .foregroundStyle(.white.opacity(0.4))
                            } else {
                                Text(exerciseLocation)
                                    .font(.appBody)
                                    .foregroundStyle(.white)
                            }
                            
                            Spacer()
                            
                            
                        }
                        .padding(.horizontal, 18)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
               
                    
                 ZStack(alignment: .trailing) {
            if description.isEmpty {
                Text("وصف التمرين")
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("", text: $description)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal,16)
                .environment(\.layoutDirection, .leftToRight)


                
        }
        .frame(height: 50)
        .background(
            Capsule().fill(.white.opacity(0.1))
        )
                    .padding(.horizontal,16).padding(.vertical,6)
                customDateRangePicker
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                
                // Player approval toggle section
                playerApprovalToggle
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                
                Divider()
                    .background(Color.white.opacity(0.4))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                
                // Price and People section
                priceAndPeopleSection
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)

            // Section label: "القطة" shows price per person with SAR currency
            pricePerPersonSection
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
        .sheet(isPresented: $showPriceDialog) {
            numberInputDialog(
                title: "قيمة الملعب",
                subtitle: "قيمة حجز الملعب الإجمالية",
                value: $tempPriceValue,
                isPresented: $showPriceDialog,
                onSave: {
                    if let value = Int(tempPriceValue) {
                        fieldValue = value
                    }
                    tempPriceValue = ""
                },
                onDelete: {
                    fieldValue = 0
                    tempPriceValue = ""
                    showPriceDialog = false
                }
            )
        }
        .sheet(isPresented: $showPeopleDialog) {
            numberInputDialog(
                title: "العدد",
                subtitle: "عدد الأشخاص",
                value: $tempPeopleValue,
                isPresented: $showPeopleDialog,
                onSave: {
                    if let value = Int(tempPeopleValue) {
                        numberOfPeople = value
                    }
                    tempPeopleValue = ""
                },
                onDelete: {
                    numberOfPeople = 0
                    tempPeopleValue = ""
                    showPeopleDialog = false
                }
            )
        }
        .sheet(isPresented: $showStartDateDialog) {
            datePickerDialog(
                title: "يبدأ",
                subtitle: "تاريخ ووقت البداية",
                date: Binding(get: { startDate ?? Date() }, set: { startDate = $0 }),
                isPresented: $showStartDateDialog
            )
        }
        .sheet(isPresented: $showEndDateDialog) {
            datePickerDialog(
                title: "ينتهي",
                subtitle: "تاريخ ووقت النهاية",
                date: Binding(get: { endDate ?? Date() }, set: { endDate = $0 }),
                isPresented: $showEndDateDialog
            )
        }
        .sheet(isPresented: $showLocationDialog) {
            locationInputDialog(
                title: "موقع التمرين",
                subtitle: "أدخل موقع التمرين",
                value: $tempLocationValue,
                isPresented: $showLocationDialog,
                onSave: {
                    exerciseLocation = tempLocationValue
                    tempLocationValue = ""
                },
                onDelete: {
                    exerciseLocation = ""
                    tempLocationValue = ""
                    showLocationDialog = false
                }
            )
        }
        .sheet(isPresented: $showImageSelectionDialog) {
            imageSelectionDialog(isPresented: $showImageSelectionDialog)
        }
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: {
                    Task { await submitCreateEvent() }
                }, label: {
                    Group {
                        if isCreating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .black))
                                .scaleEffect(0.9)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.black)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                        }
                    }
                })
                .foregroundStyle(isFormValid ? .blue : .black)
                .disabled(!isFormValid || isCreating)
                .opacity(isFormValid ? 1 : 0.3)
            }
        }
        .alert("خطأ", isPresented: Binding(get: { createError != nil }, set: { if !$0 { createError = nil } })) {
            Button("حسناً") { createError = nil }
        } message: {
            if let msg = createError { Text(msg) }
        }
        .sheet(isPresented: $showSTCPayGuardrail) {
            stcPayGuardrailSheet
        }
    }

    /// Sheet shown when the user tries to save a paid event without a profile STC Pay number.
    private var stcPayGuardrailSheet: some View {
        ZStack {
            Color(white: 0.10).ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button {
                        showSTCPayGuardrail = false
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

                Spacer().frame(height: 24)

                Image(systemName: "creditcard.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.white)

                Text("أضف رقم STC Pay")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 16)

                Text("لاستلام مدفوعات الفعاليات المدفوعة، أضف رقم STC Pay الخاص بك.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(white: 0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 8)

                TextField(
                    "",
                    text: $guardrailInput,
                    prompt: Text("مثل 05XXXXXXXX").foregroundColor(Color(white: 0.5))
                )
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(.system(size: 16))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.white.opacity(0.12))
                )
                .padding(.horizontal, 24)
                .padding(.top, 24)

                if let err = guardrailError {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .padding(.top, 8)
                }

                Spacer()

                Button {
                    Task { await saveSTCPayAndContinue() }
                } label: {
                    HStack {
                        if isSavingGuardrailNumber { ProgressView().tint(.black) }
                        Text("حفظ ومتابعة")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.black)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(Color.white)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSavingGuardrailNumber || guardrailInput.trimmingCharacters(in: .whitespaces).isEmpty)
                .opacity(guardrailInput.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .environment(\.layoutDirection, .rightToLeft)
        .presentationDetents([.medium])
    }

    /// Asset name for DB (card1, card2, card3, card4). No upload; home page shows from assets.
    private func assetNameForSelectedImage() -> String? {
        guard let r = selectedImageResource else { return nil }
        if r == .card1 { return "card1" }
        if r == .card2 { return "card2" }
        if r == .card3 { return "card3" }
        if r == .card4 { return "card4" }
        return nil
    }

    private func submitCreateEvent() async {
        isCreating = true
        createError = nil
        defer { isCreating = false }

        // Guardrail: paid event requires the creator's STC Pay number on profile.
        if fieldValue > 0 {
            do {
                let profile = try await AuthService.shared.getCurrentUserProfile()
                let number = profile?.stcPayNumber?.trimmingCharacters(in: .whitespaces) ?? ""
                if number.isEmpty {
                    showSTCPayGuardrail = true
                    return
                }
            } catch {
                createError = "تعذر التحقق من رقم STC Pay الخاص بك"
                return
            }
        }

        do {
            let computedPricePerPerson: Double = (numberOfPeople > 0) ? Double(fieldValue) / Double(numberOfPeople) : 0
            let event = try await EventService.shared.createEvent(
                name: exerciseName,
                location: exerciseLocation,
                description: description,
                startDate: startDate ?? Date(),
                endDate: endDate,
                imageUrl: assetNameForSelectedImage(),
                maxParticipants: numberOfPeople > 0 ? numberOfPeople : nil,
                totalPrice: fieldValue,
                pricePerPerson: computedPricePerPerson
            )
            print("[CreateEvent] Success — id: \(event.id), name: \(event.name)")
            dismiss()
        } catch {
            print("[CreateEvent] Error — \(error.localizedDescription)")
            createError = error.localizedDescription
        }
    }

    /// Save the STC Pay number from the guardrail sheet, then proceed with event creation.
    private func saveSTCPayAndContinue() async {
        guardrailError = nil
        let trimmed = guardrailInput.trimmingCharacters(in: .whitespaces)
        guard let canonical = STCPay.normalize(trimmed) else {
            guardrailError = "رقم STC Pay غير صالح"
            return
        }
        isSavingGuardrailNumber = true
        defer { isSavingGuardrailNumber = false }
        do {
            try await AuthService.shared.updateSTCPayNumber(canonical)
            showSTCPayGuardrail = false
            guardrailInput = ""
            // Re-attempt event creation now that the number is saved.
            await submitCreateEvent()
        } catch {
            guardrailError = "تعذر حفظ الرقم. حاول مرة أخرى."
        }
    }

     // MARK: - Number Input Dialog
     func numberInputDialog(
        title: String,
        subtitle: String,
        value: Binding<String>,
        isPresented: Binding<Bool>,
        onSave: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented.wrappedValue = false
                }
            
            // Dialog container
            VStack(spacing: 0) {
                // Header
                HStack {
                   
                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.appHeadline)
                            .foregroundStyle(.white)
                        
                        Text(subtitle)
                            .font(.appBody)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()

                     // Close button
                    Button {
                        isPresented.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 0)
                .padding(.top, 20)
                .padding(.bottom, 24)
                
             
                
                // Number input field
                HStack {
                    TextField("", text: value, prompt: Text("0").foregroundColor(.white.opacity(0.5)))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundStyle(.white)
                    // If first row/field selected (field is for الملعب price input)
                    if title.contains("قيمة الملعب") {
                        Image("riyal")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 28, height: 28)
                            .padding(.leading, 4)
                    }
                }
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .frame(height: 80)
                    .padding(.horizontal, 24)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.5))
                    )
                    .padding(.horizontal, 20)
                
                Spacer()
                
                // Action buttons
                HStack(spacing: 12) {
                    // Delete button (left)
                    Button {
                        onDelete()
                    } label: {
                        Text("حذف")
                            .font(.appBodySemibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.gray.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    
                    // Save button (right)
                    Button {
                        onSave()
                        isPresented.wrappedValue = false
                    } label: {
                        Text("حفظ")
                            .font(.appBodySemibold)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: 340)
           
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    

    
    // MARK: - Image Selection Section
    private var imageSelectionSection: some View {
        ZStack(alignment: .bottomLeading) {
            // Background image area
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.gray.opacity(0.3))
                .frame(width: 322,height: 220)
                .overlay(
                    Group {
                        if let imageResource = selectedImageResource {
                            Image(imageResource)
                                .resizable()
                                .scaledToFill()
                        } else {
                            // Placeholder with sample image
                            Image(ImageResource.actnew)
                                .resizable()
                                .scaledToFill()
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            
            // Image picker button overlay
            HStack(alignment: .center, spacing: 16) {
                Button(action: {
                    showImageSelectionDialog = true
                }, label: {
                    HStack(spacing: 8) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16, weight: .medium))
                        Text("اختيار صورة")
                            .font(.appBodyMedium)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(white: 0.2, opacity: 0.7))
                    )
                })
            }
            .padding(.leading, 16)
            .padding(.bottom, 16)
            
        }
    }
    
    // MARK: - Input Fields Section
    private var inputField: some View {
        ZStack(alignment: .leading) {
            if exerciseName.isEmpty {
                Text("اسم التمرين")
                    .foregroundStyle(.white.opacity(0.35))
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            TextField("", text: $exerciseName)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal,16)
                .padding(.trailing, 16)
                .environment(\.layoutDirection, .rightToLeft)
                .multilineTextAlignment(.trailing)


                
        }
        .frame(height: 50)
        .background(
            Capsule().fill(.white.opacity(0.1))
        )
    }

    
    // MARK: - Additional Settings Button
    private var additionalSettingsButton: some View {
        Button(action: {
            // Additional settings action
        }, label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 18, weight: .medium))
                Text("إعدادات إضافية")
                    .font(.appBodySemibold)
            }
            .foregroundStyle(.black)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.gray.opacity(0.3))
            )
        })
    }
    
    // MARK: - Custom Date Range Picker
    private var customDateRangePicker: some View {
        ZStack {
            // Main container with dark reddish-purple translucent background
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(height: 120)
            
            VStack(spacing: 0) {
                // Top section - Start date
                Button {
                    showStartDateDialog = true
                } label: {
                    HStack {
                        HStack(spacing: 8) {
                            if let date = startDate {
                                Text(dateFormatter.string(from: date))
                                    .font(.appBodyMedium)
                                    .foregroundStyle(.white)
                            } else {
                                Text("يبدأ")
                                    .font(.appBodyMedium)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.leading, 36)
                        Spacer()
                    }
                    .frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                
                // Horizontal separator line
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 36)
                
                // Bottom section - End date
                Button {
                    showEndDateDialog = true
                } label: {
                    HStack {
                        HStack(spacing: 8) {
                            if let date = endDate {
                                Text(dateFormatter.string(from: date))
                                    .font(.appBodyMedium)
                                    .foregroundStyle(.white)
                            } else {
                                Text("ينتهي")
                                    .font(.appBodyMedium)
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.leading, 36)
                        Spacer()
                    }
                    .frame(height: 60)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            
            // Dashed vertical line connecting the circles (on the right side)
            HStack {
               
                
                VStack(spacing: 0) {
                    Circle()
                        .fill(.white.opacity(0.7))
                        .frame(width: 8, height: 8)
                    
                    // Dashed line using Path
                    Path { path in
                        let dashLength: CGFloat = 4
                        let dashGap: CGFloat = 4
                        var y: CGFloat = 0
                        let totalHeight: CGFloat = 40
                        
                        while y < totalHeight {
                            path.move(to: CGPoint(x: 0, y: y))
                            path.addLine(to: CGPoint(x: 0, y: min(y + dashLength, totalHeight)))
                            y += dashLength + dashGap
                        }
                    }
                    .stroke(.white.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: 1, height: 40)
                    
                    Circle()
                        .stroke(.white.opacity(0.7), lineWidth: 2)
                        .frame(width: 8, height: 8)
                }
                .padding(.leading, 20)
                Spacer()
            }
        }
    }
    
    // MARK: - Price Per Person Section
    private var pricePerPersonSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(height: 60)
            
            HStack { 
                Text("القطة")
                    .font(.appBody)
                    .foregroundStyle(.white)
                
                Spacer()
                
                let pricePerPerson: Double = (numberOfPeople > 0) ? Double(fieldValue) / Double(numberOfPeople) : 0
                if pricePerPerson > 0 {
                    HStack(spacing: 4) {
                        Text(String(format: "%.0f", pricePerPerson))
                            .font(.appBody)
                            .foregroundStyle(.white.opacity(0.7))
                            Image("riyal")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }
    
    // MARK: - Player Approval Toggle
    private var playerApprovalToggle: some View {
        HStack {
            Text("الموافقة على اللاعبين")
                .font(.appBody)
                .foregroundStyle(.white)
            
            Spacer()
            
            Toggle("", isOn: $playerApprovalEnabled)
                .labelsHidden()
                .tint(.blue)
        }
        .frame(height: 50)
        .padding(.horizontal, 18)
        .background(
            Capsule().fill(.white.opacity(0.1))
        )
    }
    
    // MARK: - Price and People Section
    private var priceAndPeopleSection: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.white.opacity(0.1))
                .frame(height: 120)
            
            VStack(spacing: 0) {
                // First row - Total Price
                Button {
                    tempPriceValue = fieldValue > 0 ? "\(fieldValue)" : ""
                    showPriceDialog = true
                } label: {
                    HStack {
                        Image("riyal")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 24, height: 24)
                            .foregroundStyle(.white.opacity(0.7))
                        
                        Text("قيمة الملعب")
                            .font(.appBody)
                            .foregroundStyle(.white)
                        
                        Spacer()
                        
                        if fieldValue > 0 {
                            HStack(spacing: 4) {
                                Text("\(fieldValue)")
                                    .font(.appBody)
                                    .foregroundStyle(.white.opacity(0.7))
                                Image("riyal")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 18, height: 18)
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 60)
                }
                .buttonStyle(.plain)
                
                // Horizontal separator line
                Rectangle()
                    .fill(.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 36)
                
                // Second row - Number of People
                Button {
                    tempPeopleValue = numberOfPeople > 0 ? "\(numberOfPeople)" : ""
                    showPeopleDialog = true
                } label: {
                    HStack {
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 24)
                        Spacer().frame(width: 16)
                        Text("العدد")
                            .font(.appBody)
                            .foregroundStyle(.white)
                        
                        Spacer()
                        
                        if numberOfPeople > 0 {
                            Text("\(numberOfPeople)")
                                .font(.appBody)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 60)
                }
                .buttonStyle(.plain)
            }
        }
    }
    
    // MARK: - Date Picker Dialog
    private func datePickerDialog(
        title: String,
        subtitle: String,
        date: Binding<Date>,
        isPresented: Binding<Bool>
    ) -> some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented.wrappedValue = false
                }
            
            // Dialog container
            VStack(spacing: 0) {
                // Header
                HStack {
                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.appHeadline)
                            .foregroundStyle(.white)
                        
                        Text(subtitle)
                            .font(.appBody)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    
                    // Close button
                    Button {
                        isPresented.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
                
                // Date picker
                DatePicker("", selection: date, displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .accentColor(.white)
                    .environment(\.layoutDirection, .rightToLeft)
                    .padding(.horizontal, 20)
                
                Spacer()
                
                // Save button
                Button {
                    isPresented.wrappedValue = false
                } label: {
                    Text("حفظ")
                        .font(.appBodySemibold)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: 340)
            .padding(.horizontal, 20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Image Selection Dialog
    private func imageSelectionDialog(isPresented: Binding<Bool>) -> some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented.wrappedValue = false
                }
            
            // Dialog container
            VStack(spacing: 0) {
                // Header
                HStack {
                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text("اختيار صورة")
                            .font(.appHeadline)
                            .foregroundStyle(.white)
                        
                        Text("اختر صورة للتمرين")
                            .font(.appBody)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    
                    // Close button
                    Button {
                        isPresented.wrappedValue = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 24)
                
                // Image grid
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 12),
                    GridItem(.flexible(), spacing: 12)
                ], spacing: 12) {
                    ForEach([ImageResource.card1, .card2, .card3, .card4], id: \.self) { imageResource in
                        Button {
                            selectedImageResource = imageResource
                            isPresented.wrappedValue = false
                        } label: {
                            ZStack {
                                Image(imageResource)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                
                                // Selection indicator
                                if selectedImageResource == imageResource {
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .stroke(Color.blue, lineWidth: 3)
                                        .frame(width: 140, height: 140)
                                    
                                    VStack {
                                        Spacer()
                                        HStack {
                                            Spacer()
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 24))
                                                .foregroundStyle(.blue)
                                                .background(Color.white.clipShape(Circle()))
                                                .padding(8)
                                        }
                                    }
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                
                Spacer()
            }
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .padding(.horizontal, 20)
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
    
    // MARK: - Location Input Dialog
    private func locationInputDialog(
        title: String,
        subtitle: String,
        value: Binding<String>,
        isPresented: Binding<Bool>,
        onSave: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) -> some View {
        LocationInputDialogView(
            title: title,
            subtitle: subtitle,
            value: value,
            isPresented: isPresented,
            onSave: onSave,
            onDelete: onDelete,
            selectedCoordinate: $selectedCoordinate,
            currentRegion: $currentRegion,
            searchResults: $searchResults,
            searchText: $searchText,
            isSearching: $isSearching,
            locationManager: $locationManager,
            isGeocoding: $isGeocoding
        )
    }
}

// MARK: - Location Input Dialog View
struct LocationInputDialogView: View {
    let title: String
    let subtitle: String
    @Binding var value: String
    @Binding var isPresented: Bool
    let onSave: () -> Void
    let onDelete: () -> Void
    
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    @Binding var currentRegion: MKCoordinateRegion
    @Binding var searchResults: [MKMapItem]
    @Binding var searchText: String
    @Binding var isSearching: Bool
    @Binding var locationManager: CLLocationManager
    @Binding var isGeocoding: Bool
    
    @State private var locationDelegate: LocationManagerDelegate?
    @State private var geocoder: CLGeocoder = CLGeocoder()
    
    var body: some View {
        ZStack {
            // Blurred background
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .onTapGesture {
                    isPresented = false
                }
            
            // Dialog container
            VStack(spacing: 0) {
                // Header
                HStack {
                    // Title
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.appHeadline)
                            .foregroundStyle(.white)
                        
                        Text(subtitle)
                            .font(.appBody)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    Spacer()
                    
                    // Close button
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.gray.opacity(0.3))
                            .clipShape(Circle())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 16)
                
                // Search bar
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.white.opacity(0.7))
                    
                    TextField("ابحث عن موقع", text: $searchText)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                        .onSubmit {
                            performSearch()
                        }
                        .onChange(of: searchText) { oldValue, newValue in
                            if !newValue.isEmpty {
                                performSearch()
                            } else {
                                searchResults = []
                            }
                        }
                    
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.5))
                )
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
                
                // Search results list
                if !searchResults.isEmpty {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(searchResults, id: \.self) { item in
                                Button {
                                    selectSearchResult(item)
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(item.name ?? "")
                                                .font(.appBodyMedium)
                                                .foregroundStyle(.white)
                                            
                                            if let address = item.placemark.title {
                                                Text(address)
                                                    .font(.appBody)
                                                    .foregroundStyle(.white.opacity(0.7))
                                                    .lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.5))
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 12)
                                    .background(
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(Color.white.opacity(0.1))
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .frame(maxHeight: 120)
                    .padding(.bottom, 12)
                }
                
                // Map view
                ZStack(alignment: .bottomTrailing) {
                    MapLocationPickerView(
                        region: $currentRegion,
                        selectedCoordinate: $selectedCoordinate,
                        onCoordinateChange: { coordinate in
                            reverseGeocode(coordinate: coordinate)
                        }
                    )
                    .frame(height: 300)
                    .cornerRadius(16)
                    .padding(.horizontal, 20)
                    
                    // Current location button
                    Button {
                        requestCurrentLocation()
                    } label: {
                        Image(systemName: "location.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .padding(.trailing, 32)
                    .padding(.bottom, 16)
                }
                .padding(.bottom, 16)
                
                // Location input field (editable)
                TextField("", text: $value, prompt: Text("أدخل الموقع").foregroundColor(.white.opacity(0.5)))
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)
                    .frame(height: 50)
                    .padding(.horizontal, 16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.black.opacity(0.5))
                    )
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                    .onChange(of: value) { oldValue, newValue in
                        // Optional: Forward geocoding when user types
                        if !newValue.isEmpty && newValue != oldValue {
                            forwardGeocode(address: newValue)
                        }
                    }
                
                if isGeocoding {
                    HStack {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(0.8)
                        Text("جاري البحث...")
                            .font(.appBody)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding(.bottom, 8)
                }
                
                // Action buttons
                HStack(spacing: 12) {
                    // Delete button (left)
                    Button {
                        value = ""
                        selectedCoordinate = nil
                        onDelete()
                    } label: {
                        Text("حذف")
                            .font(.appBodySemibold)
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.gray.opacity(0.5))
                            .clipShape(Capsule())
                    }
                    
                    // Save button (right)
                    Button {
                        onSave()
                        isPresented = false
                    } label: {
                        Text("حفظ")
                            .font(.appBodySemibold)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.white.opacity(0.9))
                            .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            
            .padding(.horizontal, 20)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            setupLocationManager()
            // Initialize with existing value if available
            if !value.isEmpty {
                forwardGeocode(address: value)
            }
        }
    }
    
    // MARK: - Location Manager Setup
    private func setupLocationManager() {
        locationDelegate = LocationManagerDelegate()
        locationDelegate?.onLocationUpdate = { location in
            let coordinate = location.coordinate
            let newRegion = MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            )
            selectedCoordinate = coordinate
            currentRegion = newRegion
            reverseGeocode(coordinate: coordinate)
        }
        
        locationDelegate?.onAuthorizationChange = { status in
            #if os(iOS)
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                locationManager.startUpdatingLocation()
            }
            #else
            if status == .authorizedAlways {
                locationManager.startUpdatingLocation()
            }
            #endif
        }
        
        locationManager.delegate = locationDelegate
        locationManager.desiredAccuracy = kCLLocationAccuracyBest
    }
    
    // MARK: - Request Current Location
    private func requestCurrentLocation() {
        let status = locationManager.authorizationStatus
        
        switch status {
        case .notDetermined:
            #if os(iOS)
            locationManager.requestWhenInUseAuthorization()
            #else
            locationManager.requestAlwaysAuthorization()
            #endif
        #if os(iOS)
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        #else
        case .authorizedAlways:
            locationManager.requestLocation()
        #endif
        case .denied, .restricted:
            // Show alert or handle denied case
            break
        @unknown default:
            break
        }
    }
    
    // MARK: - Search Functionality
    private func performSearch() {
        guard !searchText.isEmpty else {
            searchResults = []
            return
        }
        
        isSearching = true
        
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = searchText
        request.region = currentRegion
        
        let search = MKLocalSearch(request: request)
        search.start { response, error in
            DispatchQueue.main.async {
                isSearching = false
                if let error = error {
                    print("Search error: \(error.localizedDescription)")
                    searchResults = []
                    return
                }
                
                if let response = response {
                    searchResults = Array(response.mapItems.prefix(5))
                } else {
                    searchResults = []
                }
            }
        }
    }
    
    // MARK: - Select Search Result
    private func selectSearchResult(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        let newRegion = MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        )
        selectedCoordinate = coordinate
        currentRegion = newRegion
        // Use name or formatted address
        if let name = item.name, !name.isEmpty {
            value = name
        } else if let address = item.placemark.title, !address.isEmpty {
            value = address
        } else {
            // Fallback to reverse geocoding
            reverseGeocode(coordinate: coordinate)
        }
        searchText = ""
        searchResults = []
        if value.isEmpty {
            reverseGeocode(coordinate: coordinate)
        }
    }
    
    // MARK: - Reverse Geocoding
    private func reverseGeocode(coordinate: CLLocationCoordinate2D) {
        isGeocoding = true
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { placemarks, error in
            DispatchQueue.main.async {
                isGeocoding = false
                if let error = error {
                    print("Reverse geocoding error: \(error.localizedDescription)")
                    return
                }
                
                if let placemark = placemarks?.first {
                    let addressComponents = [
                        placemark.thoroughfare,
                        placemark.subThoroughfare,
                        placemark.locality,
                        placemark.administrativeArea,
                        placemark.country
                    ].compactMap { $0 }
                    
                    value = addressComponents.joined(separator: " ")
                }
            }
        }
    }
    
    // MARK: - Forward Geocoding
    private func forwardGeocode(address: String) {
        guard !address.isEmpty else { return }
        
        isGeocoding = true
        geocoder.cancelGeocode()
        geocoder.geocodeAddressString(address) { placemarks, error in
            DispatchQueue.main.async {
                isGeocoding = false
                if let error = error {
                    print("Forward geocoding error: \(error.localizedDescription)")
                    return
                }
                
                if let placemark = placemarks?.first,
                   let location = placemark.location {
                    let coordinate = location.coordinate
                    let newRegion = MKCoordinateRegion(
                        center: coordinate,
                        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                    )
                    selectedCoordinate = coordinate
                    currentRegion = newRegion
                }
            }
        }
    }
    
   
    
    // MARK: - Helper Views
    private func inputField(icon: String?, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 24)
            } else {
                Spacer()
                    .frame(width: 24)
            }
            
            TextField(placeholder, text: text)
                .font(.appBody)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
    
    private func stepperField(icon: String, placeholder: String, value: Binding<Int>) -> some View {
        HStack(spacing: 12) {
            // Stepper controls (left side in RTL)
            VStack(spacing: 4) {
                Button(action: {
                    value.wrappedValue += 1
                }, label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                })
                
                Button(action: {
                    if value.wrappedValue > 0 {
                        value.wrappedValue -= 1
                    }
                }, label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                })
            }
            .frame(width: 24)
            
            // Icon
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 24)
            
            // Text field
            TextField(placeholder, value: value, format: .number)
                .font(.appBody)
                .foregroundStyle(.white)
            
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

// MARK: - Location Manager Delegate
class LocationManagerDelegate: NSObject, CLLocationManagerDelegate {
    var onLocationUpdate: ((CLLocation) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.first else { return }
        onLocationUpdate?(location)
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("Location error: \(error.localizedDescription)")
    }
    
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }
}

// MARK: - Map Location Picker View
struct MapLocationPickerView: View {
    @Binding var region: MKCoordinateRegion
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    var onCoordinateChange: ((CLLocationCoordinate2D) -> Void)?
    
    @State private var mapPosition: MapCameraPosition
    
    init(region: Binding<MKCoordinateRegion>, selectedCoordinate: Binding<CLLocationCoordinate2D?>, onCoordinateChange: ((CLLocationCoordinate2D) -> Void)?) {
        self._region = region
        self._selectedCoordinate = selectedCoordinate
        self.onCoordinateChange = onCoordinateChange
        self._mapPosition = State(initialValue: .region(region.wrappedValue))
    }
    
    var body: some View {
        Map(position: $mapPosition, interactionModes: .all) {
            if let coordinate = selectedCoordinate {
                Annotation("Selected Location", coordinate: coordinate) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.red)
                        .shadow(radius: 4)
                        .background(Color.white.clipShape(Circle()))
                }
            }
        }
        .onMapCameraChange { context in
            let newCoordinate = context.region.center
            selectedCoordinate = newCoordinate
            region = context.region
            onCoordinateChange?(newCoordinate)
        }
        .onAppear {
            // Initialize map position
            updateMapPosition()
        }
        .onChange(of: region.center.latitude) { _, _ in
            updateMapPosition()
        }
        .onChange(of: region.center.longitude) { _, _ in
            updateMapPosition()
        }
    }
    
    private func updateMapPosition() {
        if let coordinate = selectedCoordinate {
            mapPosition = .region(MKCoordinateRegion(
                center: coordinate,
                span: region.span
            ))
        } else {
            mapPosition = .region(region)
        }
    }
}

#Preview {
    NavigationStack {
        NewEventView()
    }
}
