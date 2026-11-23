//! Read the installer's three-column release listing on the client when the
//! destination cannot download it. Only an absent version listing means a
//! development build. Transfer, integrity and missing-asset errors stay errors.
use super::Error;
use reqwest::{StatusCode, Url, blocking::Client};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    time::Duration,
};

const DEFAULT: &str = "https://graffitty.com/releases";

pub(super) enum Releases {
    Https(Url),
    Directory(PathBuf),
}

impl Releases {
    pub fn configured() -> Result<Self, Error> {
        let value = std::env::var_os("GRAFFITTY_RELEASES").filter(|v| !v.is_empty());
        let path = PathBuf::from(value.unwrap_or_else(|| DEFAULT.into()));
        if path.is_absolute() {
            return Ok(Self::Directory(path));
        }
        let value = path.to_str().ok_or("Invalid GRAFFITTY_RELEASES")?;
        let url = Url::parse(&format!("{}/", value.trim_end_matches('/')))
            .ok()
            .filter(|u| u.scheme() == "https" && u.query().is_none() && u.fragment().is_none())
            .ok_or("GRAFFITTY_RELEASES must be an HTTPS base URL or an absolute local directory")?;
        Ok(Self::Https(url))
    }

    pub fn listing(&self, client: &Client, tag: &str) -> Result<Option<String>, Error> {
        let name = format!("{tag}.txt");
        match self {
            Self::Directory(dir) => match fs::read_to_string(dir.join(name)) {
                Ok(listing) => Ok(Some(listing)),
                Err(e) if e.kind() == io::ErrorKind::NotFound && dir.is_dir() => Ok(None),
                Err(e) => Err(e.into()),
            },
            Self::Https(url) => {
                let response = client
                    .get(url.join(&name)?)
                    .timeout(Duration::from_secs(60))
                    .send()?;
                if response.status() == StatusCode::NOT_FOUND {
                    return Ok(None);
                }
                Ok(Some(response.error_for_status()?.text()?))
            }
        }
    }

    fn archive(&self, client: &Client, address: &str) -> Result<Box<dyn Read>, Error> {
        let url = if address.starts_with("https://") {
            Url::parse(address)?
        } else if address.contains("://") {
            return Err("Release archive URL must use HTTPS".into());
        } else {
            match self {
                Self::Directory(dir) => return Ok(Box::new(File::open(dir.join(address))?)),
                Self::Https(base) => base.join(address)?,
            }
        };
        Ok(Box::new(client.get(url).send()?.error_for_status()?))
    }
}

struct Entry<'a> {
    sha256: &'a str,
    address: &'a str,
}

fn entry<'a>(listing: &'a str, asset: &str) -> Result<Entry<'a>, Error> {
    let mut selected = None;
    for line in listing.lines() {
        let mut fields = line.split_ascii_whitespace();
        let (Some(sha256), Some(name), Some(address)) =
            (fields.next(), fields.next(), fields.next())
        else {
            continue;
        };
        if name != asset {
            continue;
        }
        if fields.next().is_some()
            || sha256.len() != 64
            || !sha256.bytes().all(|b| b.is_ascii_hexdigit())
        {
            return Err(format!("Invalid release listing for {asset}").into());
        }
        if selected.replace(Entry { sha256, address }).is_some() {
            return Err(format!("Release lists {asset} more than once").into());
        }
    }
    selected.ok_or_else(|| {
        format!("Release has no {asset}; use --server-binary for a custom build").into()
    })
}

/// Stage a verified archive and rewrite its listing address to the file the
/// remote installer will have beside it. The installer checks the hash again.
pub(super) fn stage(
    releases: &Releases,
    client: &Client,
    listing: &str,
    tag: &str,
    asset: &str,
    dir: &Path,
) -> Result<(), Error> {
    let entry = entry(listing, asset)?;
    let mut input = releases.archive(client, entry.address)?;
    let mut output = File::create(dir.join(asset))?;
    let mut hash = Sha256::new();
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = input.read(&mut buf)?;
        if n == 0 {
            break;
        }
        output.write_all(&buf[..n])?;
        hash.update(&buf[..n]);
    }
    let actual: String = hash.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if !actual.eq_ignore_ascii_case(entry.sha256) {
        return Err(format!(
            "SHA-256 mismatch for {asset}: expected {}, got {actual}",
            entry.sha256
        )
        .into());
    }
    fs::write(
        dir.join(format!("{tag}.txt")),
        format!("{actual}  {asset}  {asset}\n"),
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::installer;

    const HASH: &str = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    const ASSET: &str = "graffitty-linux-x86_64.tar.gz";

    #[test]
    fn local_mirror_selects_remote_archive_and_rewrites_only_its_verified_entry() {
        let mirror = tempfile::tempdir().unwrap();
        let outgoing = tempfile::tempdir().unwrap();
        fs::write(mirror.path().join("payload"), b"abc").unwrap();
        let listing =
            format!("{HASH}  graffitty-linux-arm64.tar.gz  other\r\n{HASH}  {ASSET}  payload\r\n");
        let releases = Releases::Directory(mirror.path().into());
        let client = installer::client().unwrap();
        stage(
            &releases,
            &client,
            &listing,
            "v1.2.3",
            ASSET,
            outgoing.path(),
        )
        .unwrap();
        assert_eq!(fs::read(outgoing.path().join(ASSET)).unwrap(), b"abc");
        let manifest = outgoing.path().join("v1.2.3.txt");
        assert_eq!(
            fs::read_to_string(&manifest).unwrap(),
            format!("{HASH}  {ASSET}  {ASSET}\n")
        );
        fs::remove_file(&manifest).unwrap();
        fs::write(mirror.path().join("payload"), b"corrupt").unwrap();
        let error = stage(
            &releases,
            &client,
            &listing,
            "v1.2.3",
            ASSET,
            outgoing.path(),
        )
        .unwrap_err();
        assert!(error.to_string().contains("SHA-256 mismatch"));
        assert!(!manifest.exists());
    }

    #[test]
    fn missing_tag_is_distinct_from_unreadable_listing_or_invalid_asset() {
        let mirror = tempfile::tempdir().unwrap();
        let client = installer::client().unwrap();
        let releases = Releases::Directory(mirror.path().into());
        assert!(releases.listing(&client, "v1.2.3-dev").unwrap().is_none());
        fs::create_dir(mirror.path().join("v1.2.3-dev.txt")).unwrap();
        assert!(releases.listing(&client, "v1.2.3-dev").is_err());
        assert!(
            Releases::Directory(mirror.path().join("typo"))
                .listing(&client, "v1.2.3")
                .is_err()
        );
        let row = format!("{HASH} {ASSET} archive\n");
        for listing in [String::new(), row.repeat(2), row.replace(HASH, "bad")] {
            assert!(entry(&listing, ASSET).is_err());
        }
        assert!(
            releases
                .archive(&client, "http://example.invalid/archive")
                .is_err()
        );
    }
}
