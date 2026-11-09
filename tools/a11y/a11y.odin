// Accessibility debugging tools (ROADMAP M4): dump a running myod app's accessibility tree, or press
// a widget through the same AX action a screen reader uses.
//
//	just a11y-dump [app]
//	just a11y-press <name> [app]
//
// macOS gates the AX API behind the Accessibility privacy permission; if the tree is empty, grant it
// to the terminal that runs this tool.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

foreign import ax "system:ApplicationServices.framework"

foreign ax {
	AXUIElementCreateApplication :: proc(pid: i32) -> rawptr ---
	AXUIElementCopyAttributeValue :: proc(el: rawptr, attr: rawptr, value: ^rawptr) -> i32 ---
	AXUIElementPerformAction :: proc(el: rawptr, action: rawptr) -> i32 ---
	AXIsProcessTrusted :: proc() -> bool ---
	CFStringCreateWithCString :: proc(alloc: rawptr, s: cstring, encoding: u32) -> rawptr ---
	CFStringGetCString :: proc(s: rawptr, buf: [^]u8, size: i64, encoding: u32) -> bool ---
	CFStringGetLength :: proc(s: rawptr) -> i64 ---
	CFArrayGetCount :: proc(a: rawptr) -> i64 ---
	CFArrayGetValueAtIndex :: proc(a: rawptr, i: i64) -> rawptr ---
	CFGetTypeID :: proc(x: rawptr) -> u64 ---
	CFStringGetTypeID :: proc() -> u64 ---
	CFArrayGetTypeID :: proc() -> u64 ---
	CFBooleanGetTypeID :: proc() -> u64 ---
	CFBooleanGetValue :: proc(b: rawptr) -> bool ---
	CFRelease :: proc(x: rawptr) ---
	AXValueGetValue :: proc(v: rawptr, kind: u32, out: rawptr) -> bool ---
}

CF_UTF8 :: u32(0x08000100)

Point :: struct {
	x, y: f64,
}
Size :: struct {
	w, h: f64,
}

// The AX attribute names are plain strings on the wire.
attr :: proc(name: string) -> rawptr {
	return CFStringCreateWithCString(nil, strings.clone_to_cstring(name, context.temp_allocator), CF_UTF8)
}

@(private = "file")
to_string :: proc(cf: rawptr) -> string {
	if cf == nil {
		return ""
	}
	n := int(CFStringGetLength(cf)) * 4 + 1
	buf := make([]u8, n, context.temp_allocator)
	if !CFStringGetCString(cf, raw_data(buf), i64(n), CF_UTF8) {
		return ""
	}
	return string(buf[:len(buf) - 1])
}

// A copy of one attribute, or nil. The caller releases it.
@(private = "file")
get :: proc(el: rawptr, name: string) -> rawptr {
	v: rawptr
	a := attr(name)
	defer CFRelease(a)
	if AXUIElementCopyAttributeValue(el, a, &v) != 0 {
		return nil
	}
	return v
}

@(private = "file")
get_string :: proc(el: rawptr, name: string) -> string {
	v := get(el, name)
	if v == nil {
		return ""
	}
	defer CFRelease(v)
	if CFGetTypeID(v) != CFStringGetTypeID() {
		return ""
	}
	return to_string(v)
}

// The value as text: strings directly, numbers via AXValue's description.
@(private = "file")
get_text :: proc(el: rawptr, name: string) -> string {
	return get_string(el, name)
}

@(private = "file")
get_children :: proc(el: rawptr) -> rawptr {
	return get(el, "AXChildren")
}

@(private = "file")
describe :: proc(el: rawptr, depth: int) {
	indent := strings.repeat("  ", depth, context.temp_allocator)
	role := get_string(el, "AXRole")
	title := get_string(el, "AXTitle")
	if title == "" {
		title = get_string(el, "AXDescription")
	}
	value := get_text(el, "AXValue")
	enabled: bool = true
	if v := get(el, "AXEnabled"); v != nil {
		if CFGetTypeID(v) == CFBooleanGetTypeID() {
			enabled = CFBooleanGetValue(v)
		}
		CFRelease(v)
	}
	fmt.printf("%s%s", indent, role)
	if title != "" {
		fmt.printf(" %q", title)
	}
	if value != "" {
		fmt.printf(" = %q", value)
	}
	if !enabled {
		fmt.print(" (disabled)")
	}
	if p := get(el, "AXPosition"); p != nil {
		pt: Point
		s: Size
		ps := get(el, "AXSize")
		okp := AXValueGetValue(p, 1, &pt)
		oks := ps != nil && AXValueGetValue(ps, 2, &s)
		if okp && oks {
			fmt.printf(" @ %.0f,%.0f %.0fx%.0f", pt.x, pt.y, s.w, s.h)
		}
		CFRelease(p)
		if ps != nil {
			CFRelease(ps)
		}
	}
	fmt.println()

	kids := get_children(el)
	if kids != nil {
		if CFGetTypeID(kids) == CFArrayGetTypeID() {
			for i in 0 ..< CFArrayGetCount(kids) {
				describe(CFArrayGetValueAtIndex(kids, i), depth + 1)
			}
		}
		CFRelease(kids)
	}
}

// Depth-first search for the first element titled `name`; returns nil if none.
@(private = "file")
find :: proc(el: rawptr, name: string) -> rawptr {
	title := get_string(el, "AXTitle")
	if title == "" {
		title = get_string(el, "AXDescription")
	}
	if title == name {
		return el
	}
	kids := get_children(el)
	if kids == nil {
		return nil
	}
	defer CFRelease(kids)
	if CFGetTypeID(kids) != CFArrayGetTypeID() {
		return nil
	}
	for i in 0 ..< CFArrayGetCount(kids) {
		if found := find(CFArrayGetValueAtIndex(kids, i), name); found != nil {
			return found
		}
	}
	return nil
}

usage :: proc() {
	fmt.eprintln("usage: a11y dump <pid> | a11y press <name> <pid> | a11y focus <name> <pid>")
	os.exit(2)
}

main :: proc() {
	args := os.args
	if len(args) < 3 {
		usage()
	}
	if !AXIsProcessTrusted() {
		fmt.eprintln("a11y: this process is not trusted for Accessibility; grant it in System Settings → Privacy & Security → Accessibility")
		os.exit(1)
	}
	cmd := args[1]
	pid := 0
	name := ""
	switch cmd {
	case "dump":
		pid, _ = strconv.parse_int(args[2])
	case "press", "focus":
		if len(args) < 4 {
			usage()
		}
		name = args[2]
		pid, _ = strconv.parse_int(args[3])
	case:
		usage()
	}
	if pid <= 0 {
		usage()
	}
	app := AXUIElementCreateApplication(i32(pid))
	if app == nil {
		fmt.eprintln("a11y: cannot get the application element")
		os.exit(1)
	}
	defer CFRelease(app)

	switch cmd {
	case "dump":
		windows := get(app, "AXWindows")
		if windows == nil {
			fmt.eprintln("a11y: the app exposes no windows (is it running, and is this process trusted?)")
			os.exit(1)
		}
		defer CFRelease(windows)
		for i in 0 ..< CFArrayGetCount(windows) {
			describe(CFArrayGetValueAtIndex(windows, i), 0)
		}
	case "press", "focus":
		windows := get(app, "AXWindows")
		if windows == nil {
			fmt.eprintln("a11y: the app exposes no windows")
			os.exit(1)
		}
		defer CFRelease(windows)
		found: rawptr
		for i in 0 ..< CFArrayGetCount(windows) {
			if found = find(CFArrayGetValueAtIndex(windows, i), name); found != nil {
				break
			}
		}
		if found == nil {
			fmt.eprintf("a11y: no element titled %q\n", name)
			os.exit(1)
		}
		// The element belongs to the tree owned by `app`, so `find` must keep it alive; the arrays above
		// only vouch for their children, and AX elements are retained by their parent application.
		action := "AXPress"
		if cmd == "focus" {
			action = "AXRaise"
		}
		a := attr(action)
		defer CFRelease(a)
		err := AXUIElementPerformAction(found, a)
		if err != 0 {
			fmt.eprintf("a11y: %s failed (%d)\n", action, err)
			os.exit(1)
		}
		fmt.printf("%s %q\n", action, name)
	}
}
