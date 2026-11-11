//! The sound a notification makes. Denial plays it, as the Notification role,
//! so it follows the notifications volume: the sender's `sound-file`, else its
//! `sound-name` from the freedesktop theme, else the theme's message sound.
//! Nothing plays for an update that doesn't alert, a low-urgency or a call
//! notification (the calls app rings itself), one that asks for silence
//! (Android's, which keeps its own sound policy), or, unless it is
//! critical, under Do not disturb.

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

/// Plays the sound of the first notification in `events` that makes one.
pub(super) fn play<'a>(events: impl IntoIterator<Item = &'a NotificationEvent>, quiet: bool) {
    let Some(path) = events
        .into_iter()
        .filter(|event| event.kind != NotificationEventKind::Closed)
        .filter_map(|event| event.notification.as_ref())
        .filter(|notification| sounds(notification, quiet))
        .find_map(sound_path)
    else {
        return;
    };
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
