//! Terminal composition on iOS/iPadOS (ios_terminal_ime.m).
//!
//! The shim streams finished text through Godot's own keyboard path. This side
//! paints the open composition, sends it ahead of key-bar keys that end it,
//! and turns hardware navigation and modifier chords into key events.

use godot::classes::display_server::HandleType;
use godot::classes::{DisplayServer, Input, InputEventKey};
use godot::global::Key;
use godot::obj::EngineEnum;
use godot::prelude::*;
use std::cell::Cell;
use std::ffi::{CStr, c_char, c_void};

unsafe extern "C" {
    fn gft_ios_terminal_ime_set(window_handle: *mut c_void, active: bool);
    fn gft_ios_terminal_ime_finish() -> *mut c_char;
    fn gft_ios_terminal_ime_poll();
    fn gft_ios_terminal_ime_preedit(generation: *mut u64, buffer: *mut c_char, capacity: usize, caret: *mut i32) -> usize;
    fn free(pointer: *mut c_void);
}

thread_local! {
    static OWNER: Cell<Option<InstanceId>> = const { Cell::new(None) };
    static GENERATION: Cell<u64> = const { Cell::new(0) };
    static FLUSHING: Cell<bool> = const { Cell::new(false) };
}

/// True while a terminal sends a finished composition through its own keys.
pub fn flushing() -> bool {
    FLUSHING.get()
}

pub fn set_flushing(value: bool) {
    FLUSHING.set(value);
}

pub fn owner() -> Option<InstanceId> {
    OWNER.get()
}

/// Hands the shared keyboard view to `terminal`, or releases it.
pub fn set_owner(terminal: Option<InstanceId>) {
    if OWNER.get() == terminal {
        return;
    }
    OWNER.set(terminal);
    let controller = DisplayServer::singleton().window_get_native_handle(HandleType::WINDOW_HANDLE);
    // SAFETY: on iOS this handle is Godot's live UIViewController, used on its
    // main thread. The shim keeps only a weak reference to its keyboard view.
    unsafe { gft_ios_terminal_ime_set(controller as *mut c_void, terminal.is_some()) };
}

/// The open composition, removed from the input method. Not yet sent.
pub fn finish() -> String {
    if OWNER.get().is_none() {
        return String::new();
    }
    // SAFETY: the shim returns a strdup'd UTF-8 string or null.
    unsafe {
        let pointer = gft_ios_terminal_ime_finish();
        if pointer.is_null() {
            return String::new();
        }
        let text = CStr::from_ptr(pointer).to_string_lossy().into_owned();
        free(pointer.cast());
        text
    }
}

/// Keeps the keyboard view with the owning terminal for a hardware keyboard.
pub fn poll() {
    // SAFETY: main-thread UIKit calls with no arguments.
    unsafe { gft_ios_terminal_ime_poll() };
}

/// The preedit and its composing range, when it changed since the last call.
pub fn preedit() -> Option<(GString, Vector2i)> {
    let mut generation = GENERATION.get();
    let mut caret = -1;
    let mut buffer = vec![0u8; 256];
    loop {
        // SAFETY: the buffer is writable for its length.
        let size = unsafe {
            gft_ios_terminal_ime_preedit(&mut generation, buffer.as_mut_ptr().cast(), buffer.len(), &mut caret)
        };
        if size == 0 {
            return None;
        }
        if size <= buffer.len() {
            GENERATION.set(generation);
            let text = String::from_utf8_lossy(&buffer[..size - 1]).into_owned();
            // Marked text is composed as a whole; an empty range marks the
            // held Hangul syllable, which is the last character.
            let mark = if caret < 0 {
                Vector2i::ZERO
            } else {
                Vector2i::new(0, text.chars().count() as i32)
            };
            return Some((GString::from(text.as_str()), mark));
        }
        buffer.resize(size, 0);
    }
}

/// Hardware keys the shim takes from the hidden text view, queued with the
/// text Godot's keyboard view sends so neither overtakes the other. Called by
/// ios_terminal_ime.m on the main thread from a UIKit press, outside any
/// terminal method.
#[unsafe(no_mangle)]
pub extern "C" fn gft_ios_terminal_ime_dispatch_key(code: i32, mods: i32) {
    let key = Key::try_from_ord(code).unwrap_or(Key::NONE);
    for pressed in [true, false] {
        let mut event = InputEventKey::new_gd();
        event.set_keycode(key);
        event.set_ctrl_pressed(mods & 1 != 0);
        event.set_alt_pressed(mods & 2 != 0);
        event.set_shift_pressed(mods & 4 != 0);
        event.set_meta_pressed(mods & 8 != 0);
        event.set_pressed(pressed);
        Input::singleton().parse_input_event(&event);
    }
}

/// Key events for text that has to reach the terminal ahead of a key.
pub fn text_keys(text: &str) -> Vec<Gd<InputEventKey>> {
    let mut keys = Vec::new();
    for ch in text.chars() {
        for pressed in [true, false] {
            let mut event = InputEventKey::new_gd();
            match ch {
                // The shim encodes an erased character as U+0008.
                '\u{8}' => {
                    event.set_keycode(Key::BACKSPACE);
                    event.set_pressed(pressed);
                    keys.push(event);
                    continue;
                }
                '\n' => event.set_keycode(Key::ENTER),
                '\t' => event.set_keycode(Key::TAB),
                _ => {}
            }
            event.set_unicode(ch as u32);
            event.set_pressed(pressed);
            keys.push(event);
        }
    }
    keys
}
