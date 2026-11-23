// usage: mouse <left|right|move> <x> <y>   — posts a click (or a move) at a global point
import ApplicationServices
import Foundation
let a = CommandLine.arguments
guard a.count == 4, let x = Double(a[2]), let y = Double(a[3]) else { print("usage: mouse <left|right|move> <x> <y>"); exit(2) }
let p = CGPoint(x: x, y: y)
let src = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType, _ button: CGMouseButton) {
    CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: button)?.post(tap: .cghidEventTap)
    usleep(40_000)
}
post(.mouseMoved, .left)
switch a[1] {
case "left": post(.leftMouseDown, .left); post(.leftMouseUp, .left)
case "right": post(.rightMouseDown, .right); post(.rightMouseUp, .right)
default: break
}
