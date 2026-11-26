//! The sound a notification makes. Denial plays it, as the Notification role,
//! so it follows the notifications volume: the sender's `sound-file`, else its
//! `sound-name` from the freedesktop theme, else the theme's message sound.
//! Nothing plays for an update that doesn't alert, a low-urgency or a call
//! notification (the calls app rings itself), one that asks for silence
//! (Android's, which keeps its own sound policy), or, unless it is
//! critical, under Do not disturb. The ringer mode (Android's) silences the
//! rest too: in vibrate mode the motor pulses Android's default notification
//! pattern instead, in silent mode nothing happens.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tracing::warn;

use crate::notification_server::{
    Notification, NotificationEvent, NotificationEventKind, NotificationUrgency,
};

const THEME: &str = "/usr/share/sounds/freedesktop/stereo";
const DEFAULT_SOUND: &str = "message-new-instant";

/// A burst of notifications makes one sound.
const GAP: Duration = Duration::from_millis(500);
static LAST: Mutex<Option<Instant>> = Mutex::new(None);

/// Android's ringer mode, from `sound.ringerMode` in the settings.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RingerMode {
    Normal,
    Vibrate,
    Silent,
}

/// Plays the sound of the first notification in `events` that makes one,
/// or vibrates for it in vibrate mode.
pub(super) fn play<'a>(
    events: impl IntoIterator<Item = &'a NotificationEvent>,
    quiet: bool,
    ringer: RingerMode,
) {
    let alerting: Vec<&Notification> = events
        .into_iter()
        .filter(|event| event.kind != NotificationEventKind::Closed)
        .filter_map(|event| event.notification.as_ref())
        .collect();
    let muted = quiet || ringer != RingerMode::Normal;
    let sound = alerting
        .iter()
        .filter(|notification| sounds(notification, muted))
        .find_map(|notification| sound_path(notification));
    // What would have sounded with the ringer on vibrates instead.
    let vibrate = sound.is_none()
        && ringer == RingerMode::Vibrate
        && alerting
            .iter()
            .any(|notification| sounds(notification, quiet));
    if sound.is_none() && !vibrate {
        return;
    }
    let now = Instant::now();
    {
        let mut last = LAST
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if last.is_some_and(|last| now.duration_since(last) < GAP) {
            return;
        }
        *last = Some(now);
    }
    let Some(path) = sound else {
        // Android's DEFAULT_VIBRATE_PATTERN: 250 ms on, 250 off, 250 on.
        match Command::new("hapticctl")
            .args(["pattern", "250:1,250:0,250:1"])
            .spawn()
        {
            Ok(mut child) => drop(std::thread::spawn(move || child.wait())),
            Err(error) => warn!(%error, "could not vibrate for a notification"),
        }
        return;
    };
    match Command::new("pw-play")
        .arg("--media-role=Notification")
        .arg(&path)
        .spawn()
    {
        // Reaped beside the loop; a sound lasts a second or two.
        Ok(mut child) => drop(std::thread::spawn(move || child.wait())),
        Err(error) => warn!(%error, "could not play a notification sound"),
    }
}

fn sounds(notification: &Notification, quiet: bool) -> bool {
    notification.alert
        && !notification.suppress_sound
        && !notification.category.starts_with("call")
        && match notification.urgency {
            NotificationUrgency::Low => false,
            NotificationUrgency::Normal => !quiet,
            NotificationUrgency::Critical => true,
        }
}

fn sound_path(notification: &Notification) -> Option<PathBuf> {
    let file = notification.sound_file.trim_start_matches("file://");
    if !file.is_empty() && Path::new(file).is_file() {
        return Some(file.into());
    }
    [notification.sound_name.as_str(), DEFAULT_SOUND]
        .into_iter()
        .filter(|name| !name.is_empty() && !name.contains('/'))
        .flat_map(|name| {
            ["oga", "ogg", "wav"]
                .map(|extension| Path::new(THEME).join(format!("{name}.{extension}")))
        })
        .find(|path| path.is_file())
}
