import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif
#if canImport(SwiftUI)
import SwiftUI
#endif
#if canImport(DeveloperToolsSupport)
import DeveloperToolsSupport
#endif

#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif

// MARK: - Color Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ColorResource {

    /// The "Background" asset catalog color resource.
    static let background = DeveloperToolsSupport.ColorResource(name: "Background", bundle: resourceBundle)

    /// The "Color" asset catalog color resource.
    static let color = DeveloperToolsSupport.ColorResource(name: "Color", bundle: resourceBundle)

}

// MARK: - Image Symbols -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension DeveloperToolsSupport.ImageResource {

    /// The "act" asset catalog image resource.
    static let act = DeveloperToolsSupport.ImageResource(name: "act", bundle: resourceBundle)

    /// The "actnew" asset catalog image resource.
    static let actnew = DeveloperToolsSupport.ImageResource(name: "actnew", bundle: resourceBundle)

    /// The "pic" asset catalog image resource.
    static let pic = DeveloperToolsSupport.ImageResource(name: "pic", bundle: resourceBundle)

    /// The "pizza" asset catalog image resource.
    static let pizza = DeveloperToolsSupport.ImageResource(name: "pizza", bundle: resourceBundle)

    /// The "tool" asset catalog image resource.
    static let tool = DeveloperToolsSupport.ImageResource(name: "tool", bundle: resourceBundle)

}

// MARK: - Color Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    /// The "Background" asset catalog color.
    static var background: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .background)
#else
        .init()
#endif
    }

    /// The "Color" asset catalog color.
    static var color: AppKit.NSColor {
#if !targetEnvironment(macCatalyst)
        .init(resource: .color)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    /// The "Background" asset catalog color.
    static var background: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .background)
#else
        .init()
#endif
    }

    /// The "Color" asset catalog color.
    static var color: UIKit.UIColor {
#if !os(watchOS)
        .init(resource: .color)
#else
        .init()
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    /// The "Background" asset catalog color.
    static var background: SwiftUI.Color { .init(.background) }

    /// The "Color" asset catalog color.
    static var color: SwiftUI.Color { .init(.color) }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    /// The "Background" asset catalog color.
    static var background: SwiftUI.Color { .init(.background) }

    /// The "Color" asset catalog color.
    static var color: SwiftUI.Color { .init(.color) }

}
#endif

// MARK: - Image Symbol Extensions -

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    /// The "act" asset catalog image.
    static var act: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .act)
#else
        .init()
#endif
    }

    /// The "actnew" asset catalog image.
    static var actnew: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .actnew)
#else
        .init()
#endif
    }

    /// The "pic" asset catalog image.
    static var pic: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .pic)
#else
        .init()
#endif
    }

    /// The "pizza" asset catalog image.
    static var pizza: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .pizza)
#else
        .init()
#endif
    }

    /// The "tool" asset catalog image.
    static var tool: AppKit.NSImage {
#if !targetEnvironment(macCatalyst)
        .init(resource: .tool)
#else
        .init()
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    /// The "act" asset catalog image.
    static var act: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .act)
#else
        .init()
#endif
    }

    /// The "actnew" asset catalog image.
    static var actnew: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .actnew)
#else
        .init()
#endif
    }

    /// The "pic" asset catalog image.
    static var pic: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .pic)
#else
        .init()
#endif
    }

    /// The "pizza" asset catalog image.
    static var pizza: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .pizza)
#else
        .init()
#endif
    }

    /// The "tool" asset catalog image.
    static var tool: UIKit.UIImage {
#if !os(watchOS)
        .init(resource: .tool)
#else
        .init()
#endif
    }

}
#endif

// MARK: - Thinnable Asset Support -

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ColorResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if AppKit.NSColor(named: NSColor.Name(thinnableName), bundle: bundle) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIColor(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIColor {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(SwiftUI)
@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
extension SwiftUI.ShapeStyle where Self == SwiftUI.Color {

    private init?(thinnableResource: DeveloperToolsSupport.ColorResource?) {
        if let resource = thinnableResource {
            self.init(resource)
        } else {
            return nil
        }
    }

}
#endif

@available(iOS 17.0, macOS 14.0, tvOS 17.0, watchOS 10.0, *)
@available(watchOS, unavailable)
extension DeveloperToolsSupport.ImageResource {

    private init?(thinnableName: Swift.String, bundle: Foundation.Bundle) {
#if canImport(AppKit) && os(macOS)
        if bundle.image(forResource: NSImage.Name(thinnableName)) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#elseif canImport(UIKit) && !os(watchOS)
        if UIKit.UIImage(named: thinnableName, in: bundle, compatibleWith: nil) != nil {
            self.init(name: thinnableName, bundle: bundle)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}

#if canImport(AppKit)
@available(macOS 14.0, *)
@available(macCatalyst, unavailable)
extension AppKit.NSImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !targetEnvironment(macCatalyst)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

#if canImport(UIKit)
@available(iOS 17.0, tvOS 17.0, *)
@available(watchOS, unavailable)
extension UIKit.UIImage {

    private convenience init?(thinnableResource: DeveloperToolsSupport.ImageResource?) {
#if !os(watchOS)
        if let resource = thinnableResource {
            self.init(resource: resource)
        } else {
            return nil
        }
#else
        return nil
#endif
    }

}
#endif

