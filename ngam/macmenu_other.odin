#+build !darwin
package ngam

// Only macOS has an app menu with a Settings item; elsewhere Ctrl-, opens
// the settings.
mac_menu_init :: proc(ev: u32) {}
