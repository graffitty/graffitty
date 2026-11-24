use graffitty_mods::{Draw, Mods, MonospaceMeasure, Options};
use serde_json::{Value, json};

fn host() -> Mods {
    let mut mods = Mods::new(Options {
        state_dir: None,
        log: Box::new(|level, message| panic!("{level}: {message}")),
        translate: Box::new(str::to_owned),
    })
    .unwrap();
    mods.set_theme(
        json!({"foreground":"#e4e4e7", "dim":"#8b93a1", "idle":"#8b93a1", "working":"#8ab4f8",
        "hover":"#ffffff0f", "input":"#28282f", "selected":"#12a64f", "blocked":"#ffd078", "done":"#89ddbd"}),
    );
    mods
}

fn folder(name: &str) -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../frontends/godot/project/mods")
        .join(name)
}

fn agent(provider: &str, status: &str) -> Value {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs();
    json!({"provider":provider, "status":status, "name":provider, "label":status,
        "logo":if provider == "codex" { "codex.png" } else { "pi.svg" }, "symbol":"",
        "since":now - 125, "icon":"circle-x.svg", "tint":"#a0a0a0", "spinning":false,
        "tooltip":"Agent status", "session":"", "queued":0, "queued_label":"Queued", "detail":""})
}

fn assert_logo(frame: &graffitty_mods::Frame, provider: &str, offline: bool) {
    let filename = if provider == "codex" {
        "codex.png"
    } else {
        "pi.svg"
    };
    let (gray, alpha) = frame
        .draws
        .iter()
        .find_map(|draw| match draw {
            Draw::Image {
                path,
                grayscale,
                opacity,
                ..
            } if path == filename => Some((*grayscale, *opacity)),
            _ => None,
        })
        .expect("Codex and Pi use original-colour artwork, independent of text tint");
    assert_eq!(gray, offline);
    assert!((alpha - if offline { 0.55 } else { 1.0 }).abs() < 0.001);
}

#[test]
fn retained_badges_desaturate_offline_icons_without_losing_the_elapsed_time() {
    let mut mods = host();
    for provider in ["codex", "pi"] {
        for props in [
            json!({}),
            json!({"compact":true, "row":true}),
            json!({"compact":true, "row":false}),
        ] {
            let copy = mods.load(&folder("pane-status"), props).unwrap();
            for status in ["busy", "offline", "idle"] {
                mods.publish("resources", json!({"pane":"t1", "kind":"terminal", "label":"Pane", "status":"running",
                    "status_label":"Running", "cpu":"0%", "memory":"1M", "metrics":[], "tooltip":"Pane",
                    "agent":agent(provider, status)}));
                let frame = mods
                    .frame(copy, (600.0, 300.0), &mut MonospaceMeasure)
                    .unwrap();
                assert_logo(&frame, provider, status == "offline");
                assert!(
                    mods.texts(copy).iter().any(|text| text == "2m"),
                    "Duration remains visible while offline"
                );
            }
            mods.unload(copy);
        }
        let strip = mods
            .load(&folder("pane-strip"), json!({"pane":"t1"}))
            .unwrap();
        for status in ["busy", "offline", "idle"] {
            mods.publish(
                "pane/t1",
                json!({"label":"Pane", "cpu":"0%", "memory":"1M", "agent":agent(provider, status)}),
            );
            assert_logo(
                &mods
                    .frame(strip, (300.0, 200.0), &mut MonospaceMeasure)
                    .unwrap(),
                provider,
                status == "offline",
            );
        }
        let menu = mods
            .load(
                &folder("tab-menu"),
                json!({"item":{"title":"Tab", "ordinal":1}, "font_size":16,
            "foreground":"#ffffff", "background":"#202126", "badges":[agent(provider, "offline")]}),
            )
            .unwrap();
        assert_logo(
            &mods
                .frame(menu, (600.0, 100.0), &mut MonospaceMeasure)
                .unwrap(),
            provider,
            true,
        );
    }
}

#[test]
fn agents_keep_pi_coloured_and_desaturate_offline_children() {
    let mut mods = host();
    mods.publish("agents", json!([{"id":"parent", "key":"t1", "provider":"pi", "status":"working", "section":"Working",
        "title":"Live Pi", "at":0, "focused":false, "pinned":false, "subs":[
            {"key":"t2", "host_id":1, "kind":"agent", "icon":"codex", "status":"offline", "title":"Offline Codex", "lines":["└"]}
        ]}]));
    let copy = mods.load(&folder("agents"), json!({})).unwrap();
    let frame = mods
        .frame(copy, (300.0, 300.0), &mut MonospaceMeasure)
        .unwrap();
    assert_logo(&frame, "pi", false);
    assert_logo(&frame, "codex", true);
}

#[test]
fn agents_paint_the_selected_row_for_each_source_window() {
    let mut mods = host();
    let selected = "#12a64f";
    let color = graffitty_mods::Color::parse(selected, &Default::default()).unwrap();
    mods.publish(
        "agents",
        json!([{"id":"parent", "key":"t1", "provider":"pi", "status":"idle",
        "section":"Pinned", "title":"Parent", "at":0, "pinned":true, "focused":true, "subs":[
            {"key":"t2", "row_id":"child", "host_id":1, "kind":"agent", "icon":"codex",
             "status":"idle", "focused":false, "title":"Child", "lines":["└"]}
        ]}]),
    );
    for compact in [false, true] {
        mods.publish("agent_selection@1", json!("parent"));
        mods.publish("agent_selection@2", json!("child"));
        let views = [1, 2].map(|window| {
            mods.load(
                &folder("agents"),
                json!({"window":window, "compact":compact}),
            )
            .unwrap()
        });
        let child = if compact {
            "ag-sub-parent|t2"
        } else {
            "sub-parent|t2"
        };
        let check = |mods: &mut Mods, view, key| {
            let frame = mods
                .frame(view, (300.0, 300.0), &mut MonospaceMeasure)
                .unwrap();
            let fills: Vec<_> = frame
                .draws
                .iter()
                .filter_map(|draw| match draw {
                    Draw::Rect {
                        rect, color: fill, ..
                    } if *fill == color => Some(*rect),
                    _ => None,
                })
                .collect();
            let row = frame.hits.iter().find(|hit| hit.key == key).unwrap();
            assert_eq!(fills, [row.rect]);
        };
        check(&mut mods, views[0], "ag-parent");
        check(&mut mods, views[1], child);
        mods.publish("agent_selection@1", json!("child"));
        assert!(mods.needs_frame(views[0]));
        assert!(!mods.needs_frame(views[1]));
        check(&mut mods, views[0], child);
        for view in views {
            mods.unload(view);
        }
    }
}
