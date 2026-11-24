//! Users and groups for chown, by name or number. Names go through the C library
//! (getpwnam_r and getgrnam_r), so users from NSS, such as LDAP or systemd-homed, count as
//! they do for chown(1).

use std::ffi::CString;

/// chown's new owner and group; None keeps one.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Owner {
    pub uid: Option<u32>,
    pub gid: Option<u32>,
}

/// "user", "user:group", or ":group", by name or number. Err says what is wrong, as the status
/// line shows it.
pub fn parse_owner(spec: &str) -> Result<Owner, String> {
    let (user, group) = spec.split_once(':').unwrap_or((spec, ""));
    let uid = match user {
        "" => None,
        u => Some(user_id(u).ok_or_else(|| format!("No such user: {u}"))?),
    };
    let gid = match group {
        "" => None,
        g => Some(group_id(g).ok_or_else(|| format!("No such group: {g}"))?),
    };
    Ok(Owner { uid, gid })
}

/// A user by name or number.
pub fn user_id(name: &str) -> Option<u32> {
    if let Ok(n) = name.parse() {
        return Some(n);
    }
    let name = CString::new(name).ok()?;
    lookup(|buf| {
        // SAFETY: every pointer is to a live local or to `buf`, whose length is passed.
        let mut pw: libc::passwd = unsafe { std::mem::zeroed() };
        let mut found = std::ptr::null_mut();
        let rc = unsafe {
            libc::getpwnam_r(
                name.as_ptr(),
                &mut pw,
                buf.as_mut_ptr(),
                buf.len(),
                &mut found,
            )
        };
        (rc, (!found.is_null()).then_some(pw.pw_uid))
    })
}

/// A group by name or number.
pub fn group_id(name: &str) -> Option<u32> {
    if let Ok(n) = name.parse() {
        return Some(n);
    }
    let name = CString::new(name).ok()?;
    lookup(|buf| {
        // SAFETY: as in user_id.
        let mut gr: libc::group = unsafe { std::mem::zeroed() };
        let mut found = std::ptr::null_mut();
        let rc = unsafe {
            libc::getgrnam_r(
                name.as_ptr(),
                &mut gr,
                buf.as_mut_ptr(),
                buf.len(),
                &mut found,
            )
        };
        (rc, (!found.is_null()).then_some(gr.gr_gid))
    })
}

/// Calls a getpwnam_r-like function with a buffer, larger while it says ERANGE, as entries
/// with many group members need.
fn lookup(mut f: impl FnMut(&mut [libc::c_char]) -> (libc::c_int, Option<u32>)) -> Option<u32> {
    let mut buf = vec![0; 1024];
    loop {
        match f(&mut buf) {
            (libc::ERANGE, _) if buf.len() < 1 << 20 => buf.resize(buf.len() * 2, 0),
            (_, id) => return id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owners_by_name_or_number() {
        assert_eq!(
            parse_owner("0"),
            Ok(Owner {
                uid: Some(0),
                gid: None
            })
        );
        assert_eq!(
            parse_owner(":0"),
            Ok(Owner {
                uid: None,
                gid: Some(0)
            })
        );
        assert_eq!(
            parse_owner("root:root"),
            Ok(Owner {
                uid: Some(0),
                gid: Some(0)
            })
        );
        assert_eq!(
            parse_owner("no-such-user-here"),
            Err("No such user: no-such-user-here".into())
        );
        assert_eq!(
            parse_owner("0:nogroup-x"),
            Err("No such group: nogroup-x".into())
        );
        assert_eq!(parse_owner(""), Ok(Owner::default()));
    }
}
