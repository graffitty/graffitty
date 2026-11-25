//! Thin Godot adapter for the shared acknowledged upload state machine.
use godot::{classes::{RefCounted, IRefCounted}, prelude::*};

#[derive(GodotClass)]
#[class(base=RefCounted)]
struct TerminalFileUpload {
    base: Base<RefCounted>,
    upload: Option<graffitty_client_core::file_transfer::Upload>,
    loading: Option<std::sync::mpsc::Receiver<anyhow::Result<graffitty_client_core::clipboard_paste::Attachment>>>,
}
#[godot_api]
impl IRefCounted for TerminalFileUpload {
    fn init(base: Base<RefCounted>) -> Self { Self { base, upload: None, loading: None } }
}
#[godot_api]
impl TerminalFileUpload {
    #[func]
    fn read_file(&mut self, path: GString) {
        let path = std::path::PathBuf::from(path.to_string());
        let (sender, receiver) = std::sync::mpsc::channel();
        self.loading = Some(receiver);
        std::thread::spawn(move || { let _ = sender.send(graffitty_client_core::clipboard_paste::Attachment::file(&path)); });
    }
    #[func]
    fn read_result(&mut self) -> VarDictionary {
        let mut result = VarDictionary::new();
        let Some(receiver) = &self.loading else { return result; };
        let value = match receiver.try_recv() {
            Ok(value) => value,
            Err(std::sync::mpsc::TryRecvError::Empty) => return result,
            Err(error) => Err(error.into()),
        };
        self.loading = None;
        match value {
            Ok(file) => { result.set("name", file.name.as_str()); result.set("data", &PackedByteArray::from(file.bytes.as_slice())); }
            Err(error) => { result.set("error", error.to_string()); }
        }
        result
    }
    #[func]
    fn quote_paths(&self, paths: PackedStringArray, powershell: bool) -> VarDictionary {
        let paths = paths.as_slice().iter().map(ToString::to_string).collect::<Vec<_>>();
        crate::graph_client::to_variant(&match graffitty_client_core::clipboard_paste::quote_paths(&paths, powershell) {
            Ok(text) => serde_json::json!({"text":text}),
            Err(error) => serde_json::json!({"error":error.to_string()}),
        }).to()
    }
    #[func]
    fn write_local(&self, path: GString, bytes: PackedByteArray) -> GString {
        use std::{fs, io::Write, path::PathBuf};
        let path = PathBuf::from(path.to_string());
        let result = (|| -> anyhow::Result<()> {
            anyhow::ensure!(bytes.len() <= graffitty_protocol::file_transfer::MAX_BYTES, "File exceeds 32 MiB");
            let mut options = fs::OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            { use std::os::unix::fs::OpenOptionsExt; options.mode(0o600); }
            let mut file = options.open(&path)?;
            if let Err(error) = file.write_all(bytes.as_slice()) {
                drop(file);
                let _ = fs::remove_file(&path);
                return Err(error.into());
            }
            Ok(())
        })();
        result.err().map_or_else(GString::new, |e| GString::from(&e.to_string()))
    }

    #[func]
    fn start(&mut self, name: GString, bytes: PackedByteArray) -> GString {
        match graffitty_client_core::file_transfer::Upload::new(name.to_string(), bytes.to_vec(), false) {
            Ok(upload) => { self.upload = Some(upload); GString::new() },
            Err(error) => GString::from(&error.to_string()),
        }
    }
    #[func]
    fn next_chunk(&mut self) -> VarDictionary {
        self.upload.as_mut().and_then(|u| u.next()).map(|v| crate::graph_client::to_variant(&v).to()).unwrap_or_default()
    }
    #[func]
    fn accept(&mut self, response: VarDictionary) -> VarDictionary {
        let result = (|| -> anyhow::Result<Option<String>> {
            let response = crate::graph_client::from_variant(&response.to_variant()).map_err(anyhow::Error::msg)?;
            self.upload.as_mut().ok_or_else(|| anyhow::anyhow!("Upload was not started"))?.accept(&response)
        })();
        crate::graph_client::to_variant(&match result {
            Ok(path) => serde_json::json!({"done":path.is_some(),"path":path}),
            Err(error) => serde_json::json!({"error":error.to_string()}),
        }).to()
    }
}
