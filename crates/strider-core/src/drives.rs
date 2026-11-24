//! Drives: what the Drives folder (`//drives`) lists, from UDisks2's objects or, without it,
//! the mount table (`/proc/self/mountinfo`), and the words its rows, status line, and preview
//! say about each. Parsing and choosing only; the app reads the files and talks to the bus.

use std::ffi::OsString;
use std::os::unix::ffi::{OsStrExt, OsStringExt};
use std::path::{Path, PathBuf};

use crate::model::{self, Builder, Entry, Kind, Listing};

/// The icon names a drive's row asks the icon theme for, as MIME types so the app's icon
/// lookup by type finds `drive-removable-media` and `drive-harddisk`.
pub const REMOVABLE_TYPE: &str = "drive/removable-media";
pub const HARDDISK_TYPE: &str = "drive/harddisk";

/// A drive, as UDisks2 or the mount table describes it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Drive {
    /// UDisks2's block object path, or the device node.
    pub id: String,
    pub label: String,
    /// Empty when not mounted.
    pub mount_point: PathBuf,
    pub removable: bool,
    pub can_mount: bool,
    pub can_unmount: bool,
    pub can_eject: bool,
    /// Size in bytes, 0 if unknown.
    pub size: u64,
}

impl Drive {
    pub fn mounted(&self) -> bool {
        !self.mount_point.as_os_str().is_empty()
    }

    /// The type its row's icon is found by.
    pub fn icon_type(&self) -> &'static str {
        if self.removable {
            REMOVABLE_TYPE
        } else {
            HARDDISK_TYPE
        }
    }
}

/// A mounted file system's size and the space left to its users, in bytes.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Space {
    pub total: u64,
    pub free: u64,
}

// The mount table -----------------------------------------------------------------------------

/// A line of `/proc/self/mountinfo`, as far as drives need it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Mount {
    pub mount_point: PathBuf,
    pub device: String,
    pub fstype: String,
}

/// The mounts in `mountinfo`'s text; lines that do not parse are left out.
pub fn parse_mountinfo(text: &[u8]) -> Vec<Mount> {
    text.split(|&b| b == b'\n').filter_map(parse_line).collect()
}

/// "36 35 98:0 /mnt1 /mnt/parent rw,noatime master:1 - ext3 /dev/root rw"
fn parse_line(line: &[u8]) -> Option<Mount> {
    let mut fields = line.split(|&b| b == b' ').filter(|f| !f.is_empty());
    // The ID, the parent's, major:minor, and the root.
    for _ in 0..4 {
        fields.next()?;
    }
    let mp = fields.next()?;
    for f in fields.by_ref() {
        if f == b"-" {
            break;
        }
    }
    let fstype = fields.next()?;
    let dev = fields.next().unwrap_or_default();
    Some(Mount {
        mount_point: PathBuf::from(OsString::from_vec(unescape_octal(mp))),
        device: String::from_utf8_lossy(&unescape_octal(dev)).into_owned(),
        fstype: String::from_utf8_lossy(fstype).into_owned(),
    })
}

/// mountinfo escapes spaces and the like as `\040`.
fn unescape_octal(s: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        let octal = s
            .get(i + 1..i + 4)
            .filter(|d| s[i] == b'\\' && d.iter().all(|b| (b'0'..=b'7').contains(b)))
            .and_then(|d| u8::from_str_radix(std::str::from_utf8(d).ok()?, 8).ok());
        match octal {
            Some(v) => {
                out.push(v);
                i += 4;
            }
            None => {
                out.push(s[i]);
                i += 1;
            }
        }
    }
    out
}

const PSEUDO: &[&str] = &[
    "proc",
    "sysfs",
    "devtmpfs",
    "devpts",
    "tmpfs",
    "cgroup",
    "cgroup2",
    "securityfs",
    "pstore",
    "bpf",
    "debugfs",
    "tracefs",
    "configfs",
    "fusectl",
    "mqueue",
    "hugetlbfs",
    "autofs",
    "efivarfs",
    "binfmt_misc",
    "nsfs",
    "overlay",
    "squashfs",
    "rpc_pipefs",
    "ramfs",
    "selinuxfs",
    "fuse.portal",
    "fuse.gvfsd-fuse",
    "fuse.xdg-document-portal",
];

/// A real file system (a block device's or the network's), not the system's own.
pub fn is_real(m: &Mount) -> bool {
    !PSEUDO.contains(&m.fstype.as_str())
        && ![
            "/proc",
            "/sys",
            "/dev",
            "/run/user",
            "/run/credentials",
            "/snap",
            "/var/lib/docker",
        ]
        .iter()
        .any(|p| model::is_within(&m.mount_point, Path::new(p)))
}

/// Whether a mount point is where users mount things.
pub fn user_mount_point(mp: &Path) -> bool {
    let b = mp.as_os_str().as_bytes();
    ["/media/", "/run/media/", "/mnt/"]
        .iter()
        .any(|p| b.starts_with(p.as_bytes()))
        || b == b"/mnt"
}

/// Whether a mount is a drive to list: a real file system mounted where users mount things.
pub fn is_user_drive(m: &Mount) -> bool {
    is_real(m) && m.mount_point != Path::new("/") && user_mount_point(&m.mount_point)
}

/// The drives the mount table shows, in its order: each named by its mount point's last
/// component, and none of them mountable or ejectable from here.
pub fn from_mounts(mounts: &[Mount]) -> Vec<Drive> {
    mounts
        .iter()
        .filter(|m| is_user_drive(m))
        .map(|m| Drive {
            id: m.device.clone(),
            label: String::from_utf8_lossy(model::basename(&m.mount_point)).into_owned(),
            mount_point: m.mount_point.clone(),
            removable: true,
            ..Drive::default()
        })
        .collect()
}

// UDisks2 -----------------------------------------------------------------------------------

/// What `GetManagedObjects` says about one object, as far as drives need it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Object {
    pub path: String,
    /// Which of Block, Filesystem, Drive, and Encrypted it has.
    pub block: bool,
    pub filesystem: bool,
    pub drive: bool,
    pub encrypted: bool,
    // Block
    pub drive_path: String,
    pub label: String,
    pub hint_name: String,
    pub hint_icon: String,
    pub hint_ignore: bool,
    pub hint_system: bool,
    pub size: u64,
    /// For an unlocked volume's cleartext device: the encrypted one.
    pub crypto_backing: String,
    // Encrypted: the cleartext device, "/" while locked.
    pub cleartext: String,
    // Filesystem: the first mount point.
    pub mount_point: PathBuf,
    // Drive
    pub ejectable: bool,
    pub removable: bool,
    pub can_power_off: bool,
}

impl Default for Object {
    fn default() -> Object {
        Object {
            path: String::new(),
            block: false,
            filesystem: false,
            drive: false,
            encrypted: false,
            drive_path: "/".into(),
            label: String::new(),
            hint_name: String::new(),
            hint_icon: String::new(),
            hint_ignore: false,
            hint_system: true,
            size: 0,
            crypto_backing: "/".into(),
            cleartext: "/".into(),
            mount_point: PathBuf::new(),
            ejectable: false,
            removable: false,
            can_power_off: false,
        }
    }
}

/// What a listed drive's operations act on, by its block path.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Volume {
    pub block: String,
    /// The drive object, to eject or power off.
    pub drive: String,
    pub ejectable: bool,
    pub can_power_off: bool,
    /// A locked encrypted volume: unlock `block` first.
    pub locked: bool,
    /// The encrypted volume an unlocked file system is on, to lock after unmounting; empty
    /// for plain ones.
    pub backing: String,
}

/// The file systems worth listing: those UDisks2 does not hide, on removable drives or not
/// part of the system, or mounted where users mount things; and locked encrypted volumes,
/// until their cleartext device's file system stands for them. Sorted by label.
pub fn from_udisks(objects: &[Object]) -> (Vec<Drive>, Vec<Volume>) {
    let find = |path: &str| objects.iter().find(|o| o.path == path);
    let mut volumes = Vec::new();
    let mut drives = Vec::new();
    for o in objects {
        if !o.block || o.hint_ignore {
            continue;
        }
        let locked = o.encrypted && o.cleartext == "/";
        if !o.filesystem && !locked {
            continue;
        }
        let backing = (o.crypto_backing != "/")
            .then(|| find(&o.crypto_backing))
            .flatten();
        // The cleartext device has no drive or useful hints of its own.
        let outer = backing.unwrap_or(o);
        if outer.hint_ignore {
            continue;
        }
        let d = find(&outer.drive_path);
        let removable = d.is_some_and(|d| d.removable || d.ejectable);
        let mounted = !o.mount_point.as_os_str().is_empty();
        if outer.hint_system && !removable && !(mounted && user_mount_point(&o.mount_point)) {
            continue;
        }
        let label = [&o.label, &outer.label, &outer.hint_name]
            .into_iter()
            .find(|l| !l.is_empty())
            .cloned()
            .unwrap_or_else(|| {
                let kind = if locked || backing.is_some() {
                    "Encrypted Volume"
                } else {
                    "Volume"
                };
                format!("{} {kind}", model::format_size(outer.size))
            });
        let ejectable = d.is_some_and(|d| d.ejectable);
        let power_off = d.is_some_and(|d| d.can_power_off) && removable;
        volumes.push(Volume {
            block: o.path.clone(),
            drive: outer.drive_path.clone(),
            ejectable,
            can_power_off: power_off,
            locked,
            backing: backing.map(|b| b.path.clone()).unwrap_or_default(),
        });
        drives.push(Drive {
            id: o.path.clone(),
            label,
            mount_point: o.mount_point.clone(),
            removable,
            can_mount: !mounted,
            can_unmount: mounted,
            can_eject: ejectable || power_off,
            size: outer.size,
        });
    }
    drives.sort_by(|a, b| a.label.as_bytes().cmp(b.label.as_bytes()));
    (drives, volumes)
}

/// UDisks2's (cryptsetup's) words for a wrong passphrase, said plainly.
pub fn unlock_error(detail: &str) -> &str {
    let lower = detail.to_ascii_lowercase();
    if lower.contains("passphrase") || lower.contains("no key available") {
        "Wrong passphrase. Try again."
    } else {
        detail
    }
}

// The Drives folder ---------------------------------------------------------------------------

/// The name a drive's entry has: its label, a slash in it (which would read as a path) made a
/// division slash.
pub fn entry_name(label: &str) -> Vec<u8> {
    label.replace('/', "∕").into_bytes()
}

/// The drives as a folder's listing at `//drives`: an entry per drive, named by its label, a
/// folder when it is mounted, its size the file system's (`spaces`, by drive) or else the
/// drive's.
pub fn listing(drives: &[Drive], spaces: &[Option<Space>]) -> Listing {
    let mut b = Builder::new();
    for (i, d) in drives.iter().enumerate() {
        let total = spaces.get(i).copied().flatten().map_or(0, |s| s.total);
        b.add(
            &entry_name(&d.label),
            Entry {
                name_off: 0,
                name_len: 0,
                size: if total != 0 { total } else { d.size },
                mtime: 0,
                mode: 0,
                base_off: 0,
                kind: if d.mounted() { Kind::Dir } else { Kind::Other },
                link: false,
                hidden: false,
            },
        );
    }
    b.finish(model::DRIVES_PATH)
}

/// The drive whose entry in the Drives folder is named `name`.
pub fn by_entry<'a>(drives: &'a [Drive], name: &[u8]) -> Option<&'a Drive> {
    drives.iter().find(|d| entry_name(&d.label) == name)
}

/// What a drive's row says beside its name: that it is not mounted, or the space left.
pub fn row_info(d: &Drive, space: Option<Space>) -> String {
    match space {
        _ if !d.mounted() => "not mounted".into(),
        Some(s) if s.total != 0 => format!("{} free", model::compact_size(s.free)),
        _ => String::new(),
    }
}

/// What the status line says of the drive under the cursor: its size when not mounted, else
/// its space and where it is mounted.
pub fn status(d: &Drive, space: Option<Space>) -> String {
    match space {
        _ if !d.mounted() && d.size != 0 => {
            format!("Not mounted   {}", model::format_size(d.size))
        }
        _ if !d.mounted() => "Not mounted".into(),
        Some(s) if s.total != 0 => format!(
            "{} free of {}   {}",
            model::format_size(s.free),
            model::format_size(s.total),
            d.mount_point.display()
        ),
        _ => d.mount_point.display().to_string(),
    }
}

/// The share of a mounted drive's space in use, 0 to 1.
pub fn used(space: Space) -> Option<f32> {
    (space.total != 0)
        .then(|| (space.total - space.free.min(space.total)) as f32 / space.total as f32)
}

/// The drive a path is on, if it is mounted below the home (or outside it): the deepest mount
/// point holding it.
pub fn drive_of<'a>(drives: &'a [Drive], path: &Path, home: &Path) -> Option<&'a Drive> {
    let in_home = home != Path::new("/") && model::is_within(path, home);
    let floor = if in_home { home.as_os_str().len() } else { 1 };
    drives
        .iter()
        .filter(|d| {
            d.mount_point.as_os_str().len() > floor && model::is_within(path, &d.mount_point)
        })
        .max_by_key(|d| d.mount_point.as_os_str().len())
}

/// Where h goes from `path`, and the name of `path` there: the parent folder, or Drives from
/// a drive's mount point; none at the top ("/" and Drives).
pub fn parent_of(drives: &[Drive], path: &Path) -> Option<(PathBuf, Vec<u8>)> {
    if path == Path::new("/") || path == Path::new(model::DRIVES_PATH) {
        return None;
    }
    if let Some(d) = drives.iter().find(|d| d.mount_point == path) {
        return Some((PathBuf::from(model::DRIVES_PATH), entry_name(&d.label)));
    }
    Some((
        model::parent(path).to_owned(),
        model::basename(path).to_vec(),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    // Spaces in a mount point come escaped; the system's own file systems are no drives.
    #[test]
    fn mountinfo_lines() {
        let text =
            b"36 35 98:0 / /run/media/me/My\\040Disk rw,nosuid shared:1 - vfat /dev/sdb1 rw\n\
            22 1 0:21 / /proc rw - proc proc rw\n\
            25 1 8:2 / / rw - ext4 /dev/sda2 rw\n\
            26 1 8:3 / /mnt rw - ext4 /dev/sda3 rw\n\
            27 1 0:30 / /mnt/ram rw - tmpfs tmpfs rw\n\
            garbage\n";
        let m = parse_mountinfo(text);
        assert_eq!(m.len(), 5, "the line that does not parse is left out");
        assert_eq!(m[0].mount_point, Path::new("/run/media/me/My Disk"));
        assert_eq!(m[0].fstype, "vfat");
        assert_eq!(m[0].device, "/dev/sdb1");
        assert!(is_user_drive(&m[0]));
        assert!(!is_real(&m[1]));
        assert!(!is_user_drive(&m[2]), "the root is the system's");
        assert!(is_user_drive(&m[3]));
        assert!(!is_user_drive(&m[4]), "tmpfs is no drive");
        let drives = from_mounts(&m);
        let labels: Vec<_> = drives.iter().map(|d| d.label.as_str()).collect();
        assert_eq!(labels, ["My Disk", "mnt"]);
        assert!(!drives[0].can_mount && !drives[0].can_eject);
    }

    /// The stand-in UDisks2 of the Zig build's tests: a USB stick with a plain file system
    /// (sdb1) and a LUKS volume (sdc1), unlocked as dm-0 when `unlocked`.
    fn stick(mounted: Option<&str>, unlocked: bool) -> Vec<Object> {
        let p = "/org/freedesktop/UDisks2/";
        let drive = format!("{p}drives/Stick");
        let mut v = vec![
            Object {
                path: format!("{p}block_devices/sdb1"),
                block: true,
                filesystem: true,
                drive_path: drive.clone(),
                label: "STICK".into(),
                hint_system: false,
                size: 16_000_000_000,
                mount_point: mounted.map(PathBuf::from).unwrap_or_default(),
                ..Object::default()
            },
            Object {
                path: format!("{p}block_devices/sdc1"),
                block: true,
                encrypted: true,
                drive_path: drive.clone(),
                label: "SECRET".into(),
                hint_system: false,
                size: 8_000_000_000,
                cleartext: if unlocked {
                    format!("{p}block_devices/dm_2d0")
                } else {
                    "/".into()
                },
                ..Object::default()
            },
            Object {
                path: drive,
                drive: true,
                removable: true,
                can_power_off: true,
                ..Object::default()
            },
        ];
        if unlocked {
            v.push(Object {
                path: format!("{p}block_devices/dm_2d0"),
                block: true,
                filesystem: true,
                crypto_backing: format!("{p}block_devices/sdc1"),
                label: "SECRET".into(),
                ..Object::default()
            });
        }
        v
    }

    // A locked volume lists under its label, sorted with the rest; once unlocked its
    // cleartext file system stands for it, with the encrypted one to lock after, though
    // the cleartext device is a system one with no drive of its own.
    #[test]
    fn udisks_objects_to_drives() {
        let (drives, volumes) = from_udisks(&stick(None, false));
        let labels: Vec<_> = drives.iter().map(|d| d.label.as_str()).collect();
        assert_eq!(labels, ["SECRET", "STICK"]);
        assert!(drives[1].can_mount && drives[1].can_eject && !drives[1].can_unmount);
        assert_eq!(drives[0].size, 8_000_000_000);
        let secret = volumes.iter().find(|v| v.block == drives[0].id).unwrap();
        assert!(secret.locked && secret.can_power_off && !secret.ejectable);

        let (drives, volumes) = from_udisks(&stick(Some("/run/media/me/STICK"), true));
        assert_eq!(drives.len(), 2);
        let secret = &drives[0];
        assert!(secret.id.ends_with("dm_2d0"));
        let v = volumes.iter().find(|v| v.block == secret.id).unwrap();
        assert!(!v.locked);
        assert!(v.backing.ends_with("sdc1"));
        assert!(v.drive.ends_with("drives/Stick"));
        assert!(drives[1].can_unmount && !drives[1].can_mount);
    }

    // A system disk is left out unless mounted where users mount things; a hidden one
    // always; one without a label is named by its size.
    #[test]
    fn system_and_unnamed_volumes() {
        let disk = |mp: &str, ignore: bool| Object {
            path: "/b/sda1".into(),
            block: true,
            filesystem: true,
            hint_ignore: ignore,
            size: 500_000_000_000,
            mount_point: PathBuf::from(mp),
            ..Object::default()
        };
        assert!(from_udisks(&[disk("/", false)]).0.is_empty());
        assert!(from_udisks(&[disk("", false)]).0.is_empty());
        let (drives, _) = from_udisks(&[disk("/mnt/data", false)]);
        assert_eq!(drives[0].label, "500.0 GB Volume");
        assert_eq!(drives[0].icon_type(), HARDDISK_TYPE);
        assert!(from_udisks(&[disk("/mnt/data", true)]).0.is_empty());
    }

    #[test]
    fn wrong_passphrases_said_plainly() {
        let e = "Error unlocking /dev/sdc1: Failed to activate device: Operation not permitted \
                 (No key available with this passphrase)";
        assert_eq!(unlock_error(e), "Wrong passphrase. Try again.");
        assert_eq!(unlock_error("Device busy"), "Device busy");
    }

    // The Drives folder's rows and status line say what the Zig build's did; a mount point
    // goes up to Drives with the cursor on its drive.
    #[test]
    fn the_drives_folder() {
        let stick = Drive {
            label: "A/B".into(),
            size: 8_000_000_000,
            ..Drive::default()
        };
        let mounted = Drive {
            label: "DATA".into(),
            mount_point: "/run/media/me/DATA".into(),
            ..Drive::default()
        };
        let space = Space {
            total: 64 << 30,
            free: 12 << 30,
        };
        let l = listing(&[stick.clone(), mounted.clone()], &[None, Some(space)]);
        assert_eq!(l.path, Path::new(model::DRIVES_PATH));
        assert_eq!(l.name(&l.entries[0]), "A∕B".as_bytes());
        assert_eq!(l.entries[0].kind, Kind::Other);
        assert_eq!(l.entries[0].size, 8_000_000_000);
        assert_eq!(l.entries[1].kind, Kind::Dir);
        assert_eq!(l.entries[1].size, 64 << 30);
        let drives = [stick.clone(), mounted.clone()];
        assert_eq!(by_entry(&drives, "A∕B".as_bytes()), Some(&stick));

        assert_eq!(row_info(&stick, None), "not mounted");
        assert_eq!(row_info(&mounted, Some(space)), "12 G free");
        assert_eq!(row_info(&mounted, None), "");
        assert_eq!(status(&stick, None), "Not mounted   8.0 GB");
        assert_eq!(
            status(&mounted, Some(space)),
            "12.9 GB free of 68.7 GB   /run/media/me/DATA"
        );
        assert_eq!(used(space), Some(52.0 / 64.0));

        let home = Path::new("/home/me");
        assert_eq!(
            drive_of(&drives, Path::new("/run/media/me/DATA/x"), home),
            Some(&mounted)
        );
        assert_eq!(drive_of(&drives, Path::new("/run/media/me"), home), None);
        assert_eq!(
            parent_of(&drives, &mounted.mount_point),
            Some((PathBuf::from(model::DRIVES_PATH), b"DATA".to_vec()))
        );
        assert_eq!(parent_of(&drives, Path::new(model::DRIVES_PATH)), None);
        assert_eq!(
            parent_of(&drives, Path::new("/run/media/me")),
            Some((PathBuf::from("/run/media"), b"me".to_vec()))
        );
    }
}
