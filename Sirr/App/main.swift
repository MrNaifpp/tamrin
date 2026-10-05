import SwiftUI

// Arabic is pinned before SwiftUI or UIKit reads a single localized string;
// see `AppLanguage.bootstrap()`.
AppLanguage.bootstrap()
SirrApp.main()
