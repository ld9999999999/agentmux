#+build !darwin
package ngam

// Only macOS has an app menu with Settings and Reconnect items; elsewhere
// Ctrl-, opens the settings and the setup screen has Reconnect.
mac_menu_init :: proc(settings_ev, reconnect_ev: u32) {}
