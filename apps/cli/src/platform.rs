//! Small process/file differences used by the CLI. Windows files inherit their parent ACL.
#[cfg(unix)]
pub use std::os::unix::fs::OpenOptionsExt;
#[cfg(windows)]
pub trait OpenOptionsExt { fn mode(&mut self, mode: u32) -> &mut Self; }
#[cfg(windows)]
impl OpenOptionsExt for std::fs::OpenOptions { fn mode(&mut self, _: u32) -> &mut Self { self } }
#[cfg(windows)]
pub trait CommandExt { fn exec(&mut self) -> std::io::Error; }
#[cfg(windows)]
impl CommandExt for std::process::Command {
    fn exec(&mut self) -> std::io::Error {
        match self.status() { Ok(status) => std::process::exit(status.code().unwrap_or(1)), Err(error) => error }
    }
}
#[cfg(unix)]
pub fn symlink_file(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> { std::os::unix::fs::symlink(target, link) }
#[cfg(windows)]
pub fn symlink_file(target: &std::path::Path, link: &std::path::Path) -> std::io::Result<()> { std::os::windows::fs::symlink_file(target, link) }

#[cfg(windows)]
pub(crate) fn process(pid: i64) -> std::io::Result<crate::sessions::Process> {
    use std::io;
    use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
    use windows_sys::Win32::{Foundation::FILETIME, System::Threading::*};
    let id = u32::try_from(pid).map_err(io::Error::other)?;
    unsafe {
        let raw = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, id);
        if raw.is_null() {
            let e = io::Error::last_os_error();
            // OpenProcess reports ERROR_INVALID_PARAMETER for an exited PID.
            return Err(
                if e.raw_os_error()
                    == Some(windows_sys::Win32::Foundation::ERROR_INVALID_PARAMETER as i32)
                {
                    io::ErrorKind::NotFound.into()
                } else {
                    e
                },
            );
        }
        let handle = OwnedHandle::from_raw_handle(raw);
        let h = handle.as_raw_handle();
        let mut start: FILETIME = std::mem::zeroed();
        let mut exit = start;
        let mut kernel = start;
        let mut user = start;
        if GetProcessTimes(h, &mut start, &mut exit, &mut kernel, &mut user) == 0 {
            return Err(io::Error::last_os_error());
        }
        let mut code = 0;
        if GetExitCodeProcess(h, &mut code) == 0 {
            return Err(io::Error::last_os_error());
        }
        if code != windows_sys::Win32::Foundation::STILL_ACTIVE as u32 {
            return Err(io::ErrorKind::NotFound.into());
        }
        let mut path = vec![0u16; 32768];
        let mut length = path.len() as u32;
        let executable = if QueryFullProcessImageNameW(h, 0, path.as_mut_ptr(), &mut length) != 0 {
            String::from_utf16_lossy(&path[..length as usize])
        } else {
            String::new()
        };
        Ok(crate::sessions::Process {
            pid,
            parent: 0,
            group: 0,
            foreground: 0,
            state: String::new(),
            tty: String::new(),
            executable,
            started: (((start.dwHighDateTime as u64) << 32) | start.dwLowDateTime as u64)
                .to_string(),
        })
    }
}

#[cfg(windows)]
pub(crate) fn processes(
    roots: Option<&[i64]>,
) -> std::collections::HashMap<i64, crate::sessions::Process> {
    use std::collections::HashMap;
    use windows_sys::Win32::{
        Foundation::{CloseHandle, INVALID_HANDLE_VALUE},
        System::Diagnostics::ToolHelp::*,
    };
    let mut children = HashMap::<i64, Vec<i64>>::new();
    let mut entries = HashMap::new();
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return HashMap::new();
        }
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = std::mem::size_of_val(&entry) as u32;
        let mut valid = Process32FirstW(snapshot, &mut entry) != 0;
        while valid {
            let pid = i64::from(entry.th32ProcessID);
            let parent = i64::from(entry.th32ParentProcessID);
            let end = entry
                .szExeFile
                .iter()
                .position(|x| *x == 0)
                .unwrap_or(entry.szExeFile.len());
            entries.insert(
                pid,
                (parent, String::from_utf16_lossy(&entry.szExeFile[..end])),
            );
            children.entry(parent).or_default().push(pid);
            valid = Process32NextW(snapshot, &mut entry) != 0;
        }
        let complete = windows_sys::Win32::Foundation::GetLastError()
            == windows_sys::Win32::Foundation::ERROR_NO_MORE_FILES;
        CloseHandle(snapshot);
        if !complete {
            return HashMap::new();
        }
    }
    let mut pending: Vec<_> =
        roots.map_or_else(|| entries.keys().copied().collect(), |roots| roots.to_vec());
    let mut result = HashMap::new();
    while let Some(pid) = pending.pop() {
        let Some((parent, name)) = entries.remove(&pid) else {
            continue;
        };
        if roots.is_some() {
            pending.extend(children.remove(&pid).unwrap_or_default());
        }
        match process(pid) {
            Ok(mut p) => {
                p.parent = parent;
                if p.executable.is_empty() {
                    p.executable = name;
                }
                result.insert(pid, p);
            }
            // A hidden branch could contain another foreground candidate.
            Err(e) if roots.is_some() && e.kind() != std::io::ErrorKind::NotFound => {
                return HashMap::new();
            }
            Err(_) => (),
        }
    }
    result
}

#[cfg(windows)]
pub fn listener_ports(pid: i64) -> std::collections::HashSet<u16> {
    use windows_sys::Win32::{NetworkManagement::IpHelper::*, Networking::WinSock::AF_INET};
    let mut bytes = 0u32;
    unsafe { GetExtendedTcpTable(std::ptr::null_mut(), &mut bytes, 0, AF_INET as u32, TCP_TABLE_OWNER_PID_LISTENER, 0); }
    if bytes == 0 { return Default::default(); }
    let mut buffer = vec![0u32; (bytes as usize).div_ceil(4)];
    let ok = unsafe { GetExtendedTcpTable(buffer.as_mut_ptr().cast(), &mut bytes, 0, AF_INET as u32, TCP_TABLE_OWNER_PID_LISTENER, 0) };
    if ok != 0 { return Default::default(); }
    let table = buffer.as_ptr().cast::<MIB_TCPTABLE_OWNER_PID>();
    let count = unsafe { (*table).dwNumEntries as usize };
    if 4 + count * std::mem::size_of::<MIB_TCPROW_OWNER_PID>() > buffer.len() * 4 { return Default::default(); }
    let rows = unsafe { std::slice::from_raw_parts(std::ptr::addr_of!((*table).table).cast::<MIB_TCPROW_OWNER_PID>(), count) };
    rows.iter().filter(|row| row.dwOwningPid as i64 == pid).map(|row| u16::from_be(row.dwLocalPort as u16)).collect()
}

#[cfg(all(test, windows))]
mod tests {
    #[test]
    fn windows_inventory_finds_current_process_and_tcp_listener() {
        let pid = std::process::id() as i64;
        let rows = super::processes(Some(&[pid]));
        let current = rows.get(&pid).expect("current process missing");
        assert!(!current.started.is_empty());
        assert!(current.executable.to_lowercase().ends_with(".exe"));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        assert!(super::listener_ports(pid).contains(&listener.local_addr().unwrap().port()));
    }
}
