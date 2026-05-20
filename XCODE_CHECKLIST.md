# ✅ Xcode Setup Checklist for خط عام الحرف

## ✅ Already Done (in code):
- ✅ Font files exist in `Sirr/App/` folder (5 .otf files)
- ✅ `Info.plist` created with UIAppFonts configuration
- ✅ `FontExtension.swift` configured with TheYearofHandicrafts
- ✅ All views updated to use custom fonts
- ✅ `SirrApp.swift` configured to load fonts
- ✅ Font debugger created for testing

## 🔧 TODO in Xcode:

### 1. Add Font Files to Build (CRITICAL)
```
Xcode → Select "Sirr" target → Build Phases → Copy Bundle Resources → Click "+" 
Add these 5 files:
  □ TheYearofHandicrafts-Regular.otf
  □ TheYearofHandicrafts-Medium.otf
  □ TheYearofHandicrafts-SemiBold.otf
  □ TheYearofHandicrafts-Bold.otf
  □ TheYearofHandicrafts-Black.otf
```

### 2. Configure Info.plist (CRITICAL)
```
Xcode → Select "Sirr" target → Build Settings → Search "Info.plist"
Set: INFOPLIST_FILE = Sirr/Info.plist

OR disable auto-generation:
Set: GENERATE_INFOPLIST_FILE = NO
```

### 3. Verify Setup
```
Run the app → Check Xcode Console
You should see:
  ✅ TheYearofHandicrafts-Regular - LOADED
  ✅ TheYearofHandicrafts-Medium - LOADED
  ✅ TheYearofHandicrafts-SemiBold - LOADED
  ✅ TheYearofHandicrafts-Bold - LOADED
  ✅ TheYearofHandicrafts-Black - LOADED
```

## 🎨 Font Weights Applied Throughout App:

| Screen/Component | Font Weight |
|------------------|-------------|
| Navigation titles | Bold (32pt) |
| Event detail titles | Bold (30pt) |
| Card headings | SemiBold (28pt) |
| Dates/subtitles | SemiBold (20pt) |
| Body text | Regular (18pt) |
| Buttons | SemiBold (18pt) |
| Participant names | Medium (18pt) |
| Progress labels | SemiBold (16pt) |
| Small labels | Medium (12pt) |

## 🐛 Troubleshooting:

### If fonts don't load:
1. Check Console output when app starts
2. Run `FontDebugger.printAllFonts()` to see all available fonts
3. Verify font files are in "Copy Bundle Resources"
4. Verify Info.plist path is correct in Build Settings
5. Clean build folder (Cmd+Shift+K) and rebuild

### If some text still uses system font:
- The code is designed to fallback gracefully to system font if custom fonts aren't found
- Once you complete the Xcode steps above, all text should use TheYearofHandicrafts

---

## Quick Test:
After completing steps 1 & 2, just build and run. The fonts should work immediately! 🎉


