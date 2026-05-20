# إعداد خط عام الحرف (TheYearofHandicrafts) للتطبيق ✅

تم تطبيق خط عام الحرف (TheYearofHandicrafts) على جميع نصوص التطبيق!

## ✅ الملفات الموجودة

لديك بالفعل ملفات الخط في المشروع:
- ✅ `TheYearofHandicrafts-Regular.otf`
- ✅ `TheYearofHandicrafts-Medium.otf`
- ✅ `TheYearofHandicrafts-SemiBold.otf`
- ✅ `TheYearofHandicrafts-Bold.otf`
- ✅ `TheYearofHandicrafts-Black.otf`

## الخطوات المتبقية في Xcode

### الخطوة 1: إضافة ملفات الخط إلى Build Phases

1. افتح مشروع Xcode
2. اختر Target "Sirr"
3. اذهب إلى تبويب "Build Phases"
4. افتح قسم "Copy Bundle Resources"
5. اضغط زر "+" وأضف جميع ملفات `.otf`:
   - TheYearofHandicrafts-Regular.otf
   - TheYearofHandicrafts-Medium.otf
   - TheYearofHandicrafts-SemiBold.otf
   - TheYearofHandicrafts-Bold.otf
   - TheYearofHandicrafts-Black.otf

### الخطوة 2: تحديث Info.plist في Xcode

Info.plist تم إنشاؤه في `Sirr/Info.plist` ويحتوي على:

```xml
<key>UIAppFonts</key>
<array>
    <string>TheYearofHandicrafts-Regular.otf</string>
    <string>TheYearofHandicrafts-Medium.otf</string>
    <string>TheYearofHandicrafts-SemiBold.otf</string>
    <string>TheYearofHandicrafts-Bold.otf</string>
    <string>TheYearofHandicrafts-Black.otf</string>
</array>
```

### الخطوة 3: ربط Info.plist بالمشروع

في Build Settings:
1. ابحث عن "Info.plist File"
2. اضبطه على: `Sirr/Info.plist`
3. أو غير `GENERATE_INFOPLIST_FILE` إلى `NO`

## الخطوة 4: التحقق من التثبيت

بعد الخطوات السابقة:

### اختبار سريع:
1. قم بتشغيل التطبيق
2. افتح console في Xcode
3. يجب أن ترى رسائل تؤكد تحميل الخطوط:
   - ✅ TheYearofHandicrafts-Regular - LOADED
   - ✅ TheYearofHandicrafts-Medium - LOADED
   - ✅ TheYearofHandicrafts-SemiBold - LOADED
   - ✅ TheYearofHandicrafts-Bold - LOADED
   - ✅ TheYearofHandicrafts-Black - LOADED

### عرض اختبار الخطوط:
استخدم `FontDebugView` في ملف `FontDebugger.swift` لرؤية جميع أوزان الخط.

### التحقق من أسماء الخطوط (اختياري)

إذا لم يعمل الخط، يمكنك التحقق من أسماء الخطوط الصحيحة بإضافة هذا الكود مؤقتاً:

```swift
for family in UIFont.familyNames.sorted() {
    print("Family: \(family)")
    let names = UIFont.fontNames(forFamilyName: family)
    for fontName in names {
        print("- \(fontName)")
    }
}
```

## ملاحظات

- تم تطبيق الخط على جميع المكونات:
  - NavigationBarView
  - EventHeroDetailView
  - EventPageView
  - NewActivtyCardView
  - جميع المكونات الأخرى

- إذا كنت تفضل خط عربي آخر، يمكنك تعديل الخط في ملف:
  `Sirr/Extensions/FontExtension.swift`

## خطوط عربية بديلة

إذا كنت تريد استخدام خط عربي آخر:

- **Cairo**: خط عصري وواضح
- **Tajawal**: خط حديث ومتعدد الأوزان
- **Almarai**: خط بسيط وأنيق
- **Changa**: خط عصري وجذاب

للتغيير، عدّل اسم الخط في ملف `FontExtension.swift`:

```swift
static func amiri(size: CGFloat, weight: Font.Weight = .regular) -> Font {
    let fontName: String
    
    switch weight {
    case .bold:
        fontName = "اسم-الخط-Bold"  // غيّر هنا
    default:
        fontName = "اسم-الخط-Regular"  // غيّر هنا
    }
    
    return Font.custom(fontName, size: size)
}
```

---

## What Was Changed

### Files Created:
1. **Sirr/Extensions/FontExtension.swift** - Font configuration with Amiri font support
   - Custom font definitions
   - Pre-configured font sizes for consistency
   - Fallback to system font if custom font unavailable

### Files Modified:
1. **Sirr/App/SirrApp.swift** - Added global font setup
2. **Sirr/Components/NavigationBarView.swift** - Applied custom fonts
3. **Sirr/Components/EventHeroDetailView.swift** - Applied custom fonts to all text elements
4. **Sirr/NewActivtyCardView.swift** - Applied custom fonts

### Font Sizes Used:
- `.appTitle` (32pt, bold) - Main navigation titles
- `.appLargeTitle` (30pt, bold) - Event names in detail view
- `.appHeadline` (28pt, semibold) - Card titles
- `.appSubheadline` (20pt, semibold) - Dates and subtitles
- `.appBody` (18pt, regular) - General body text
- `.appBodyMedium` (18pt, medium) - Medium weight body text
- `.appBodySemibold` (18pt, semibold) - Emphasized body text
- `.appCallout` (16pt, semibold) - Progress indicators
- `.appCaption` (12pt, medium) - Small labels

