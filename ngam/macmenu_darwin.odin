#+build darwin
package ngam

// The macOS app menu's Settings item. SDL makes the app menu (About, Hide,
// Quit...) but leaves out Settings, so ngam adds "Settings…" with Cmd-,
// after About, or takes over the item if SDL ever adds one. Its action
// pushes an SDL event, and the main loop opens the settings, as Cmd-, does
// inside the window. With the menu item, Cmd-, reaches it before the
// window, so both ways end up in the same place.

import NS "core:sys/darwin/Foundation"
import AK "vendor:darwin/AppKit"
import sdl "vendor:sdl3"

@(private = "file")
settings_event: u32

// mac_menu_init adds the Settings item; ev is the SDL event type it pushes.
// Call it after SDL has made the menu (after SDL_Init).
mac_menu_init :: proc(ev: u32) {
	settings_event = ev
	nsapp := AK.Application_sharedApplication()
	main_menu := nsapp->mainMenu()
	if main_menu == nil || main_menu->numberOfItems() == 0 {
		return
	}
	app_menu := main_menu->itemAtIndex(0)->submenu()
	if app_menu == nil {
		return
	}
	sel := AK.MenuItem_registerActionCallback("ngamShowSettings", on_settings)
	comma := NS.AT(",")
	for i in 0 ..< app_menu->numberOfItems() {
		item := app_menu->itemAtIndex(i)
		if key := item->keyEquivalent(); key != nil && key->isEqualToString(comma) {
			item->setAction(sel)
			return
		}
	}
	item := NS.alloc(AK.MenuItem)->initWithTitle(NS.AT("Settings…"), sel, comma)
	// After "About ngam" and its separator, where macOS apps keep it.
	at := min(app_menu->numberOfItems(), 2)
	app_menu->insertItem(item, NS.Integer(at))
	app_menu->insertItem(AK.MenuItem_separatorItem(), NS.Integer(at + 1))
}

@(private = "file")
on_settings :: proc "c" (unused: rawptr, name: NS.SEL, sender: ^NS.Object) {
	ev: sdl.Event
	ev.type = sdl.EventType(settings_event)
	_ = sdl.PushEvent(&ev)
}
