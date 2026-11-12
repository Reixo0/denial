//! Media playback control for hardware headphone and keyboard media keys.
//!
//! Dispatches to the active MPRIS2 player on the session D-Bus (preferring
//! playing over paused), falling back to `/usr/bin/nx809j-media-key` when
//! present so Android playback in Droidloom also responds.

use std::path::Path;
use std::process::{Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::time::{Duration, Instant};

use tracing::{debug, warn};
use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::OwnedValue;

const MPRIS_PREFIX: &str = "org.mpris.MediaPlayer2.";
const MPRIS_PATH: &str = "/org/mpris/MediaPlayer2";
const MPRIS_PLAYER_IFACE: &str = "org.mpris.MediaPlayer2.Player";
const FALLBACK_HELPER: &str = "/usr/bin/nx809j-media-key";
const HEADSET_MULTI_TAP_WINDOW: Duration = Duration::from_millis(320);
const DBUS_TIMEOUT: Duration = Duration::from_millis(500);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum MediaCommand {
    PlayPause,
    Next,
    Previous,
    Stop,
    HeadsetHook,
    StopWorker,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum MediaAction {
    PlayPause,
    Next,
    Previous,
    Stop,
}

impl MediaAction {
    fn mpris_method(self) -> &'static str {
        match self {
            Self::PlayPause => "PlayPause",
            Self::Next => "Next",
            Self::Previous => "Previous",
            Self::Stop => "Stop",
        }
    }

    fn helper_arg(self) -> &'static str {
        match self {
            Self::PlayPause => "play-pause",
            Self::Next => "next",
            Self::Previous => "previous",
            Self::Stop => "stop",
        }
    }
}

pub(super) fn run_media_worker(receiver: Receiver<MediaCommand>) {
    let mut conn: Option<Connection> = None;

    while let Ok(cmd) = receiver.recv() {
        let mut pending_next: Option<MediaCommand> = Some(cmd);
        while let Some(current) = pending_next.take() {
            let action = match current {
                MediaCommand::StopWorker => return,
                MediaCommand::PlayPause => MediaAction::PlayPause,
                MediaCommand::Next => MediaAction::Next,
                MediaCommand::Previous => MediaAction::Previous,
                MediaCommand::Stop => MediaAction::Stop,
                MediaCommand::HeadsetHook => {
                    let (taps, next) = collect_headset_taps(&receiver);
                    pending_next = next;
                    match taps {
                        1 => MediaAction::PlayPause,
                        2 => MediaAction::Next,
                        _ => MediaAction::Previous,
                    }
                }
            };

            if !dispatch_mpris(&mut conn, action) {
                dispatch_fallback(action);
            }
        }
    }
}

fn collect_headset_taps(receiver: &Receiver<MediaCommand>) -> (u8, Option<MediaCommand>) {
    let mut taps: u8 = 1;
    let mut deadline = Instant::now() + HEADSET_MULTI_TAP_WINDOW;
    while taps < 3 {
        let Some(remaining) = deadline.checked_duration_since(Instant::now()) else {
            break;
        };
        match receiver.recv_timeout(remaining) {
            Ok(MediaCommand::HeadsetHook) => {
                taps += 1;
                deadline = Instant::now() + HEADSET_MULTI_TAP_WINDOW;
            }
            Ok(other) => return (taps, Some(other)),
            Err(RecvTimeoutError::Timeout) => break,
            Err(RecvTimeoutError::Disconnected) => return (taps, Some(MediaCommand::StopWorker)),
        }
    }
    (taps, None)
}

fn dispatch_mpris(conn_slot: &mut Option<Connection>, action: MediaAction) -> bool {
    let conn = match conn_slot.as_ref() {
        Some(existing) => existing,
        None => match Connection::session() {
            Ok(new_conn) => conn_slot.insert(new_conn),
            Err(err) => {
                debug!(error = %err, "failed to connect to session D-Bus for MPRIS");
                return false;
            }
        },
    };

    let Ok(dbus) = Proxy::new(
        conn,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    ) else {
        *conn_slot = None;
        return false;
    };

    let names: Vec<String> = match dbus.call("ListNames", &()) {
        Ok(list) => list,
        Err(err) => {
            debug!(error = %err, "failed to list D-Bus names for MPRIS");
            *conn_slot = None;
            return false;
        }
    };

    let mut best: Option<(u8, String)> = None;
    for name in names.into_iter().filter(|n| n.starts_with(MPRIS_PREFIX)) {
        let rank = player_rank(conn, &name);
        if best.as_ref().is_none_or(|(best_rank, _)| rank > *best_rank) {
            best = Some((rank, name));
        }
    }

    let Some((_, target)) = best else {
        return false;
    };

    let Ok(player) = zbus::blocking::proxy::Builder::<Proxy<'_>>::new(conn)
        .destination(target.as_str())
        .and_then(|b| b.path(MPRIS_PATH))
        .and_then(|b| b.interface(MPRIS_PLAYER_IFACE))
        .map(|b| b.cache_properties(zbus::proxy::CacheProperties::No))
        .and_then(|b| b.build())
    else {
        return false;
    };

    let _ = DBUS_TIMEOUT;
    match player.call::<_, _, ()>(action.mpris_method(), &()) {
        Ok(()) => {
            debug!(player = %target, method = action.mpris_method(), "dispatched MPRIS media action");
            true
        }
        Err(err) => {
            warn!(player = %target, method = action.mpris_method(), error = %err, "MPRIS call failed");
            false
        }
    }
}

fn player_rank(conn: &Connection, name: &str) -> u8 {
    let Ok(props) = Proxy::new(conn, name, MPRIS_PATH, "org.freedesktop.DBus.Properties") else {
        return 1;
    };
    let status: Result<OwnedValue, _> = props.call("Get", &(MPRIS_PLAYER_IFACE, "PlaybackStatus"));
    match status.ok().and_then(|v| String::try_from(v).ok()).as_deref() {
        Some("Playing") => 3,
        Some("Paused") => 2,
        _ => 1,
    }
}

fn dispatch_fallback(action: MediaAction) {
    if !Path::new(FALLBACK_HELPER).is_file() {
        return;
    }
    match Command::new(FALLBACK_HELPER)
        .arg(action.helper_arg())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(mut child) => {
            let _ = child.wait();
        }
        Err(err) => {
            debug!(error = %err, "failed to run media key fallback helper");
        }
    }
}
