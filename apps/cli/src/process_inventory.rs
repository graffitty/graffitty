//! Native process inventory. Never spawn `ps` for recurring discovery.
use crate::sessions::Process;
use std::{collections::HashMap, io};

// Keep the UTC process-identity representation used at the agent boundary.
fn started(seconds: i64) -> String {
    let time = jiff::Timestamp::from_second(seconds)
        .unwrap_or(jiff::Timestamp::UNIX_EPOCH)
        .to_zoned(jiff::tz::TimeZone::UTC);
    time.strftime("%a %b %e %H:%M:%S %Y")
        .to_string()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

type Table = HashMap<i64, Process>;

pub(crate) fn missing(e: &io::Error) -> bool {
    e.kind() == io::ErrorKind::NotFound || e.raw_os_error() == Some(libc::ESRCH)
}

#[cfg(target_os = "macos")]
pub(crate) fn process(pid: i64) -> io::Result<Process> {
    let pid = i32::try_from(pid).map_err(io::Error::other)?;
    let mut info: libc::proc_bsdinfo = unsafe { std::mem::zeroed() };
    let size = std::mem::size_of::<libc::proc_bsdinfo>() as i32;
    if unsafe { libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, (&raw mut info).cast(), size) }
        != size
    {
        return Err(io::Error::last_os_error());
    }
    let mut path = [0u8; 4096];
    let length = unsafe { libc::proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
    let executable = if length > 0 {
        String::from_utf8_lossy(&path[..path.iter().position(|b| *b == 0).unwrap_or(path.len())])
            .into_owned()
    } else {
        // Kernel strings need not occupy the entire buffer.
        let bytes: Vec<_> = info
            .pbi_comm
            .iter()
            .take_while(|b| **b != 0)
            .map(|b| *b as u8)
            .collect();
        String::from_utf8_lossy(&bytes).into_owned()
    };
    Ok(Process {
        pid: pid as i64,
        parent: info.pbi_ppid as i64,
        group: info.pbi_pgid as i64,
        foreground: info.e_tpgid as i32 as i64,
        tty: if info.e_tdev == u32::MAX {
            "?".into()
        } else {
            info.e_tdev.to_string()
        },
        state: match info.pbi_status {
            5 => "Z",
            4 => "T",
            _ => "S",
        }
        .into(),
        started: started(info.pbi_start_tvsec as i64),
        executable,
    })
}

#[cfg(target_os = "macos")]
fn pids(group: Option<i32>) -> io::Result<Vec<i32>> {
    let capacity = if group.is_some() {
        16
    } else {
        let count = unsafe { libc::proc_listallpids(std::ptr::null_mut(), 0) };
        if count <= 0 {
            return Err(io::Error::last_os_error());
        }
        count as usize + 128
    };
    let mut pids = vec![0i32; capacity];
    loop {
        let bytes =
            i32::try_from(std::mem::size_of_val(pids.as_slice())).map_err(io::Error::other)?;
        let buffer = pids.as_mut_ptr().cast();
        let count = unsafe {
            match group {
                Some(group) => libc::proc_listpgrppids(group, buffer, bytes),
                None => libc::proc_listallpids(buffer, bytes),
            }
        };
        if count < 0 {
            return Err(io::Error::last_os_error());
        }
        if (count as usize) < pids.len() {
            pids.truncate(count as usize);
            return Ok(pids);
        }
        pids.resize(pids.len() * 2, 0);
    }
}

#[cfg(target_os = "macos")]
pub(crate) fn processes() -> Table {
    pids(None)
        .unwrap_or_default()
        .into_iter()
        .filter_map(|pid| process(pid.into()).ok().map(|p| (p.pid, p)))
        .collect()
}

#[cfg(target_os = "macos")]
fn pane(pid: i64) -> io::Result<Table> {
    let shell = process(pid)?;
    let foreground = shell.foreground;
    let mut table = HashMap::from([(pid, shell)]);
    if foreground <= 0 {
        return Ok(table);
    }
    // A pipeline may have several roots, and a wrapper may have exec'd a child.
    // Read every group member and the ancestors needed to prove pane ownership.
    for member in pids(Some(foreground as i32))? {
        let mut cursor = i64::from(member);
        while cursor > 0 && !table.contains_key(&cursor) {
            match process(cursor) {
                Ok(p) => {
                    cursor = p.parent;
                    table.insert(p.pid, p);
                }
                Err(e) if missing(&e) => break,
                Err(e) => return Err(e),
            }
        }
    }
    Ok(table)
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn process(pid: i64) -> io::Result<Process> {
    use std::{fs, path::PathBuf, sync::OnceLock};
    static CLOCK: OnceLock<(i64, i64)> = OnceLock::new();
    let &(boot, ticks) = match CLOCK.get() {
        Some(clock) => clock,
        None => {
            let boot = fs::read_to_string("/proc/stat")?
                .lines()
                .find_map(|l| l.strip_prefix("btime ")?.parse::<i64>().ok())
                .ok_or_else(|| io::Error::other("missing boot time"))?;
            let ticks = unsafe { libc::sysconf(libc::_SC_CLK_TCK) } as i64;
            if ticks <= 0 {
                return Err(io::Error::other("invalid clock frequency"));
            }
            CLOCK.get_or_init(|| (boot, ticks))
        }
    };
    let path = PathBuf::from(format!("/proc/{pid}"));
    let stat = fs::read_to_string(path.join("stat"))?;
    let invalid = || io::Error::new(io::ErrorKind::InvalidData, "invalid process stat");
    let (head, tail) = stat.rsplit_once(") ").ok_or_else(invalid)?;
    let fields: Vec<_> = tail.split_whitespace().take(20).collect();
    let number = |i: usize| {
        fields
            .get(i)
            .and_then(|s| s.parse::<i64>().ok())
            .ok_or_else(invalid)
    };
    let tty = number(4)?;
    let executable = fs::read_link(path.join("exe"))
        .map(|p| p.to_string_lossy().into_owned())
        .unwrap_or_else(|_| {
            head.split_once('(')
                .map(|(_, s)| s.to_owned())
                .unwrap_or_default()
        });
    Ok(Process {
        pid,
        parent: number(1)?,
        group: number(2)?,
        foreground: number(5)?,
        tty: if tty == 0 {
            "?".into()
        } else {
            tty.to_string()
        },
        state: fields[0].into(),
        started: started(boot + number(19)? / ticks),
        executable,
    })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(crate) fn processes() -> Table {
    std::fs::read_dir("/proc")
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let p = process(entry.file_name().to_str()?.parse().ok()?).ok()?;
            Some((p.pid, p))
        })
        .collect()
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn pane(root: i64) -> io::Result<Table> {
    let mut table = Table::new();
    let mut pending = vec![(root, None)];
    while let Some((pid, parent)) = pending.pop() {
        if table.contains_key(&pid) {
            continue;
        }
        let p = match process(pid) {
            Ok(p) if parent.is_none_or(|parent| p.parent == parent) => p,
            Ok(_) => continue,
            Err(e) if missing(&e) => continue,
            Err(e) => return Err(e),
        };
        table.insert(pid, p);
        // Children of a worker thread appear under that TID, not the leader.
        let tasks = match std::fs::read_dir(format!("/proc/{pid}/task")) {
            Ok(t) => t,
            Err(e) if missing(&e) => continue,
            Err(e) => return Err(e),
        };
        for task in tasks {
            match std::fs::read_to_string(task?.path().join("children")) {
                Ok(list) => pending.extend(
                    list.split_whitespace()
                        .filter_map(|id| Some((id.parse::<i64>().ok()?, Some(pid)))),
                ),
                Err(e) if missing(&e) => continue,
                Err(e) => return Err(e),
            }
        }
    }
    Ok(table)
}

pub(crate) fn panes(roots: &[i64]) -> Table {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    if !roots.is_empty() && !std::path::Path::new("/proc/thread-self/children").exists() {
        // Some kernels omit CONFIG_PROC_CHILDREN.
        return processes();
    }
    roots
        .iter()
        .filter_map(|&root| pane(root).ok())
        .flatten()
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn utc_identity() {
        assert_eq!(started(0), "Thu Jan 1 00:00:00 1970");
    }
    #[test]
    fn identity_matches_external_utc_process_identity() {
        // Test oracle only: production inventory never launches a subprocess.
        let pid = std::process::id();
        let output = std::process::Command::new("ps")
            .args(["-p", &pid.to_string(), "-o", "lstart="])
            .env("TZ", "UTC")
            .env("LC_ALL", "C")
            .output()
            .unwrap();
        assert!(output.status.success());
        let expected = String::from_utf8(output.stdout)
            .unwrap()
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(processes()[&(pid as i64)].started, expected);
    }
    fn with_pty_job(check: impl FnOnce(i64)) {
        use std::{
            fs::File,
            os::fd::FromRawFd,
            os::unix::process::CommandExt,
            process::{Command, Stdio},
        };
        let (mut master, mut slave) = (-1, -1);
        assert_eq!(
            unsafe {
                libc::openpty(
                    &raw mut master,
                    &raw mut slave,
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                    std::ptr::null_mut(),
                )
            },
            0
        );
        let _master = unsafe { File::from_raw_fd(master) };
        let slave = unsafe { File::from_raw_fd(slave) };
        let mut command = Command::new("/bin/sleep");
        command
            .arg("60")
            .stdin(slave)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0
                    || libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0
                    || libc::tcsetpgrp(0, libc::getpid()) < 0
                {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            });
        }
        struct Child(std::process::Child);
        impl Drop for Child {
            fn drop(&mut self) {
                let _ = self.0.kill();
                let _ = self.0.wait();
            }
        }
        let child = Child(command.spawn().unwrap());
        check(i64::from(child.0.id()));
    }

    #[test]
    fn pane_reads_its_foreground_job_and_excludes_unrelated_processes() {
        with_pty_job(|pid| {
            let table = panes(&[pid]);
            // Kernels without a children file use the full-table fallback.
            if cfg!(target_os = "macos")
                || std::path::Path::new("/proc/thread-self/children").exists()
            {
                assert!(!table.contains_key(&i64::from(std::process::id())));
            }
            let job = &table[&pid];
            assert_eq!(job.group, job.pid);
            assert_eq!(job.foreground, job.pid);
            assert_ne!(job.tty, "?");
            assert!(!job.state.contains('Z'));
        });
    }

    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn pane_finds_children_forked_by_nonleader_threads() {
        std::thread::spawn(|| {
            let mut child = std::process::Command::new("/bin/sleep")
                .arg("30")
                .spawn()
                .unwrap();
            let pid = i64::from(child.id());
            let table = panes(&[i64::from(std::process::id())]);
            child.kill().unwrap();
            child.wait().unwrap();
            assert!(table.contains_key(&pid));
        })
        .join()
        .unwrap();
    }

    #[test]
    #[ignore = "timing observation, run with --ignored --nocapture"]
    fn foreground_reader_latency() {
        with_pty_job(|pid| {
            let roots = serde_json::json!([{"pid":pid,"node":"%1","agent":{}}]);
            let mut times = Vec::new();
            for i in 0..220 {
                let start = std::time::Instant::now();
                let result = crate::foreground_apps::scan(&roots);
                let elapsed = start.elapsed().as_secs_f64() * 1000.;
                assert_eq!(result["%1"]["id"], "sleep");
                if i >= 20 {
                    times.push(elapsed);
                }
            }
            times.sort_by(f64::total_cmp);
            println!(
                "foreground reader (200 samples, ms) median {:.3}, p95 {:.3}, max {:.3}",
                (times[99] + times[100]) / 2.,
                times[189],
                times[199]
            );
        });
    }
    #[test]
    fn inventories_self_and_parent() {
        let table = processes();
        let own = &table[&(std::process::id() as i64)];
        assert_eq!(own.group, unsafe { libc::getpgrp() } as i64);
        assert_eq!(own.parent, unsafe { libc::getppid() } as i64);
        assert!(!own.executable.is_empty());
        assert!(!own.started.is_empty());
        assert!(table.contains_key(&own.parent));
    }
}
