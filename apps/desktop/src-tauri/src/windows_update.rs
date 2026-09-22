//! Windows staging/launching is deliberately separate from MSI service work.
//! Only bytes already verified by tauri-plugin-updater reach this module.
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::PathBuf;

pub(super) struct StagedInstaller {
    dir: tempfile::TempDir,
    executable: PathBuf,
}

fn is_windows_executable(bytes: &[u8]) -> bool {
    if bytes.len() < 64 || bytes.get(..2) != Some(b"MZ") {
        return false;
    }
    let offset = u32::from_le_bytes(bytes[60..64].try_into().unwrap()) as usize;
    offset >= 64
        && offset
            .checked_add(4)
            .is_some_and(|end| bytes.get(offset..end) == Some(b"PE\0\0"))
}

fn installer_arguments(pid: u32) -> [String; 4] {
    [
        "/P".into(),
        "/R".into(),
        "/UPDATE".into(),
        format!("/CODEXXPID={pid}"),
    ]
}

impl StagedInstaller {
    pub(super) fn create(verified_bytes: &[u8]) -> io::Result<Self> {
        if !is_windows_executable(verified_bytes) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "expected a verified Windows EXE installer",
            ));
        }
        let dir = tempfile::Builder::new()
            .prefix("Codex-X-update-")
            .tempdir()?;
        let executable = dir.path().join("Codex-X-setup.exe");
        let mut file = OpenOptions::new()
            .create_new(true)
            .write(true)
            .open(&executable)?;
        file.write_all(verified_bytes)?;
        file.sync_all()?;
        drop(file);
        Ok(Self { dir, executable })
    }

    pub(super) fn launch(self, parent_pid: u32) -> io::Result<()> {
        if parent_pid == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "invalid parent PID",
            ));
        }
        // No shell or interpolated command line: Unicode/space-containing user
        // paths are passed through Rust's native Windows argument quoting.
        let child = std::process::Command::new(&self.executable)
            .args(installer_arguments(parent_pid))
            .current_dir(self.dir.path())
            .spawn()?;
        // It owns its visible progress/errors from here, and waits for parent_pid
        // to exit before migrating or copying files. Never kill system installers.
        drop(child);
        let _ = self.dir.keep();
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn staging_rejects_msi_html_truncated_and_invalid_pe_payloads() {
        for bytes in [
            b"\xd0\xcf\x11\xe0".as_slice(),
            b"<html>login</html>",
            b"MZ",
            &[0; 128],
        ] {
            assert!(StagedInstaller::create(bytes).is_err());
        }
        let mut bytes = vec![0; 128];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[60..64].copy_from_slice(&u32::MAX.to_le_bytes());
        assert!(StagedInstaller::create(&bytes).is_err());
    }

    #[test]
    fn installer_staging_is_unique_and_cancel_cleans_only_its_directory() {
        let mut bytes = vec![0; 128];
        bytes[..2].copy_from_slice(b"MZ");
        bytes[60..64].copy_from_slice(&64u32.to_le_bytes());
        bytes[64..68].copy_from_slice(b"PE\0\0");
        let a = StagedInstaller::create(&bytes).unwrap();
        let b = StagedInstaller::create(&bytes).unwrap();
        assert_ne!(a.dir.path(), b.dir.path());
        assert_eq!(std::fs::read(&a.executable).unwrap(), bytes);
        let path = a.dir.path().to_owned();
        drop(a);
        assert!(!path.exists());
        assert!(b.executable.is_file());
    }

    #[test]
    fn launcher_arguments_do_not_forward_user_cli_arguments_or_installer_paths() {
        assert_eq!(
            installer_arguments(123),
            ["/P", "/R", "/UPDATE", "/CODEXXPID=123"]
        );
    }
}
