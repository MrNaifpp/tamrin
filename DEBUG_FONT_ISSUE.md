# 🔍 Debug Font Issue - خط عام الحرف

## Problem: Font changed but not as expected

This usually means the font IS loading, but with the wrong name or style.

## 🎯 Quick Debug Steps:

### Step 1: Run the App & Check Console

1. Build and run the app (Command + R)
2. When app launches, look in **Xcode Console** (bottom panel)
3. You'll see a list of ALL available fonts
4. Search for "Year" or "Handicraft" or "عام" in the output

### Step 2: Use the Font Test Button

1. In the running app, look for a **blue circle button** (🔤) in the top-right
2. Tap it to open the Font Test sheet
3. Compare the different text samples:
   - **System Font** - How it normally looks
   - **Custom Font** - How it should look with عام الحرف
   - Should look **noticeably different**

### Step 3: Find the Correct Font Name

In the console output, look for something like:

```
Family: TheYearofHandicrafts
  - TheYearofHandicrafts-Regular
  - TheYearofHandicrafts-Bold
```

**OR it might be:**

```
Family: Year of Handicrafts
  - YearofHandicrafts Regular
  - YearofHandicrafts Bold
```

**OR even:**

```
Family: عام الحرف
  - عام الحرف-Regular
```

## 🔧 Fix Based on What You Find:

### If Font Names Are Different:

Copy the **exact names** from the console, then update `FontExtension.swift`:

```swift
switch weight {
case .black, .heavy:
    fontName = "PASTE-EXACT-NAME-HERE"  // e.g., "YearofHandicrafts Black"
case .bold:
    fontName = "PASTE-EXACT-NAME-HERE"  // e.g., "YearofHandicrafts Bold"
// ... etc
```

### If Fonts Don't Appear in Console:

The .otf files aren't being included in the build. Fix:

1. **In Xcode:** Select Target "Sirr" → Build Phases
2. **Expand:** "Copy Bundle Resources"
3. **Check if these are listed:**
   - TheYearofHandicrafts-Regular.otf
   - TheYearofHandicrafts-Medium.otf
   - TheYearofHandicrafts-SemiBold.otf
   - TheYearofHandicrafts-Bold.otf
   - TheYearofHandicrafts-Black.otf

4. **If missing:** Click "+" and add them from `Sirr/App/` folder

## 📸 What to Look For:

### Arabic Text Should Look:
- ✅ More ornate/decorative (عام الحرف style)
- ✅ Different from standard iOS Arabic font
- ✅ Consistent across all screens

### If It Looks:
- ❌ Like standard iOS font → Font not loading
- ❌ Slightly different but not right → Wrong font weight/name
- ❌ Mixed (some screens yes, some no) → Incomplete font application

## 🚀 Quick Test Code:

Add this to `SirrApp.swift` in the `init()` function:

```swift
init() {
    setupAppFont()
    
    // DEBUG: Print if custom font loads
    if let font = UIFont(name: "TheYearofHandicrafts-Regular", size: 20) {
        print("✅ Custom font LOADED: \(font.fontName)")
    } else {
        print("❌ Custom font NOT FOUND")
    }
}
```

## 💡 Common Issues:

1. **Font loads but looks wrong** 
   → Font name mismatch, check console for exact names

2. **No fonts in console**
   → Files not in Bundle Resources

3. **Some text custom, some system**
   → Not all views updated, check each component

4. **Works in preview, not in app**
   → Build Phases issue, fonts not copied to bundle

---

## 📋 Send Me This Info:

From the Xcode Console after running the app, copy and paste:
1. Any lines containing "Year" or "Handicraft" or "عام"
2. The lines showing ✅ or ❌ for font loading

Then I can give you the exact fix! 🎨


