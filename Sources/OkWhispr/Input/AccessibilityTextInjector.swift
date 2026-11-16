import Foundation
import ApplicationServices
import AppKit

/// Direct text insertion via macOS Accessibility API.
///
/// Tries to set the value of the currently focused AXTextField / AXTextArea
/// without touching the pasteboard. Requires Accessibility permission.
/// Returns true on success, false if the element is not suitable or the set
/// operation fails.
enum AccessibilityTextInjector {

    static func inject(_ text: String) -> Bool {
        guard Permissions.accessibilityGranted else {
            AppLogger.log("AccessibilityTextInjector: permission not granted")
            return false
        }

        guard let app = NSWorkspace.shared.frontmostApplication else {
            AppLogger.log("AccessibilityTextInjector: no frontmost app")
            return false
        }

        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var focusedElement: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)
        guard focusedResult == .success, let raw = focusedElement else {
            AppLogger.log("AccessibilityTextInjector: could not get focused element, result=\(focusedResult.rawValue)")
            return false
        }
        let element = raw as! AXUIElement

        // Determine role
        var roleValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleValue) == .success,
              let role = roleValue as? String else {
            AppLogger.log("AccessibilityTextInjector: could not get role")
            return false
        }

        let allowedRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSecureTextField"]
        guard allowedRoles.contains(role) else {
            AppLogger.log("AccessibilityTextInjector: role \(role) not injectable")
            return false
        }

        let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFTypeRef)
        let success = setResult == .success
        AppLogger.log("AccessibilityTextInjector: role=\(role) setResult=\(setResult.rawValue) success=\(success)")
        return success
    }
}
