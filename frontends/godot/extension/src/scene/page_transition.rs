use godot::classes::{IRefCounted, RefCounted};
use godot::prelude::*;

#[derive(GodotClass)]
#[class(base = RefCounted)]
struct ScenePageTransition {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for ScenePageTransition {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl ScenePageTransition {
    /// x: workspace offset, y: list offset, z: shade, w: completed.
    #[func]
    fn sample(&self, elapsed: f64, entering: bool) -> Vector4 {
        let frame = graffitty_scene_core::page_transition::sample(elapsed, entering);
        Vector4::new(
            frame.workspace as f32,
            frame.list as f32,
            frame.shade as f32,
            if frame.done { 1.0 } else { 0.0 },
        )
    }
}
