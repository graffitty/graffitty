use godot::classes::{DisplayServer, display_server::HandleType};
use godot::prelude::*;
use std::ffi::c_void;

unsafe extern "C" {
    fn gft_ios_password_focus(window_handle: *mut c_void, focused: bool);
}

#[derive(GodotClass)]
#[class(base=RefCounted, init)]
struct IosPasswordKeyboard;

#[godot_api]
impl IosPasswordKeyboard {
    #[func]
    fn set_focused(focused: bool) {
        let controller = DisplayServer::singleton().window_get_native_handle(HandleType::WINDOW_HANDLE);
        // SAFETY: on iOS this handle is Godot's live UIViewController. The
        // focus signals run on its main thread and the shim does not retain it.
        unsafe { gft_ios_password_focus(controller as *mut c_void, focused) };
    }
}
