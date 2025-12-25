#import <Foundation/Foundation.h>

#if __has_attribute(swift_private)
#define AC_SWIFT_PRIVATE __attribute__((swift_private))
#else
#define AC_SWIFT_PRIVATE
#endif

/// The resource bundle ID.
static NSString * const ACBundleID AC_SWIFT_PRIVATE = @"place.Sirr";

/// The "Background" asset catalog color resource.
static NSString * const ACColorNameBackground AC_SWIFT_PRIVATE = @"Background";

/// The "Color" asset catalog color resource.
static NSString * const ACColorNameColor AC_SWIFT_PRIVATE = @"Color";

/// The "act" asset catalog image resource.
static NSString * const ACImageNameAct AC_SWIFT_PRIVATE = @"act";

/// The "actnew" asset catalog image resource.
static NSString * const ACImageNameActnew AC_SWIFT_PRIVATE = @"actnew";

/// The "pic" asset catalog image resource.
static NSString * const ACImageNamePic AC_SWIFT_PRIVATE = @"pic";

/// The "pizza" asset catalog image resource.
static NSString * const ACImageNamePizza AC_SWIFT_PRIVATE = @"pizza";

/// The "tool" asset catalog image resource.
static NSString * const ACImageNameTool AC_SWIFT_PRIVATE = @"tool";

#undef AC_SWIFT_PRIVATE
