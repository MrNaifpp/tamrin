#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"com.businessech.tmrin";

/// The "Background" asset catalog color resource.
static NSString * const ACColorNameBackground AC_SWIFT_PRIVATE = @"Background";

/// The "Color" asset catalog color resource.
static NSString * const ACColorNameColor AC_SWIFT_PRIVATE = @"Color";

/// The "act" asset catalog image resource.
static NSString * const ACImageNameAct AC_SWIFT_PRIVATE = @"act";

/// The "actnew" asset catalog image resource.
static NSString * const ACImageNameActnew AC_SWIFT_PRIVATE = @"actnew";

/// The "card1" asset catalog image resource.
static NSString * const ACImageNameCard1 AC_SWIFT_PRIVATE = @"card1";

/// The "card2" asset catalog image resource.
static NSString * const ACImageNameCard2 AC_SWIFT_PRIVATE = @"card2";

/// The "card3" asset catalog image resource.
static NSString * const ACImageNameCard3 AC_SWIFT_PRIVATE = @"card3";

/// The "card4" asset catalog image resource.
static NSString * const ACImageNameCard4 AC_SWIFT_PRIVATE = @"card4";

/// The "pizza" asset catalog image resource.
static NSString * const ACImageNamePizza AC_SWIFT_PRIVATE = @"pizza";

/// The "riyal" asset catalog image resource.
static NSString * const ACImageNameRiyal AC_SWIFT_PRIVATE = @"riyal";

/// The "tool" asset catalog image resource.
static NSString * const ACImageNameTool AC_SWIFT_PRIVATE = @"tool";

#undef AC_SWIFT_PRIVATE
