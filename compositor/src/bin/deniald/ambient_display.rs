//! Always-on display on the mobile shell.
//!
//! A root-owned `/etc/denial/ambient-display.json` names the output whose
//! panel can keep showing its last frame while the output is off, and the
//! panel driver's switch for that:
//!
//! ```json
//! {
//!   "output": "DSI-1",
//!   "switch": "/sys/module/panel_raydium_rm692h5/parameters/ambient",
//!   "brightness": 400,
//!   "settle_ms": 1000
//! }
//! ```
//!
//! Turning that output off while the session locks goes through the lock
//! screen first: the shell fades everything but the always-on picture to
//! black and says when it is on screen, the backlight fades to the
//! `brightness` code beside it, and the output turns off with the switch set.
//! The panel driver then keeps the picture lit its own way. A panel that
//! refreshes as slowly as 1 Hz stays in normal mode at that rate, showing the
//! picture at that code unchanged; one that cannot uses its always-on mode,
//! and the code is the one whose picture looks like that mode's. `settle_ms`
//! keeps the finished picture still that long before the output turns off,
//! for a panel that draws a wave when it changes mode at full rate.
//!
//! Each minute the output lights for one frame, the clock's next minute, and
//! goes off again with the switch still set, so the panel keeps its
//! always-on state. A wake clears the switch, and the shell fades the rest
//! back in beside the backlight.
//!
//! A profile with `"always_on": false` blanks as usual instead, and with
//! `"pulse_ms"` the shell may ask for a pulse while the output is dark and
//! the session locked, for a notification that came in: the output lights
//! with the always-on picture (and the lock screen's notifications) at the
//! picture's backlight code for that long, then goes dark again, as a
//! Pixel's ambient display does. A pulse is dark to everything else, like
//! a refresh: touches stay out, and a wake ends it lit.
//!
//! The session must be able to write the switch. An edited profile applies
//! from the next blank.

use std::collections::BTreeSet;
use std::ffi::CStr;
use std::fs;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use denial_core::topology::OutputId;
use serde::Deserialize;
use tracing::{info, warn};

use super::RuntimeState;
use super::flutter_runtime::FlutterRuntime;
use super::kms_state::Scanout;
use super::output_scheduler::OutputScheduler;
use super::system_controls::BrightnessFade;

pub(super) const CHANNEL: &CStr = c"denial/ambient_display";
const PROFILE_PATH: &str = "/etc/denial/ambient-display.json";
const ENTER: u8 = 1;
const LEAVE: u8 = 2;
/// ENTER, for a pulse: the shell keeps the lock screen's notifications.
const ENTER_PULSE: u8 = 3;
const READY: u8 = 1;
const PULSE: u8 = 2;

/// The shell's fade, which the backlight's follows.
const SHELL_FADE: Duration = Duration::from_millis(420);

/// Past this the output turns off anyway.
const FADE_LIMIT: Duration = Duration::from_millis(1200);

/// The shell's clock turns over on the minute; its frame follows.
const REFRESH_LAG: Duration = Duration::from_millis(250);

/// Past this a refresh's output turns off without its frame.
const REFRESH_LIMIT: Duration = Duration::from_secs(2);

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct Profile {
    output: String,
    switch: PathBuf,
    brightness: u32,
    #[serde(default)]
    settle_ms: u64,
    /// False: the output blanks as usual, and only pulses show the picture.
    #[serde(default = "always_on_default")]
    always_on: bool,
    /// How long a pulse shows; None takes no pulses.
    #[serde(default)]
    pulse_ms: Option<u64>,
}

fn always_on_default() -> bool {
    true
}

impl Profile {
    fn load(path: &Path) -> Result<Self, String> {
        let metadata = fs::symlink_metadata(path).map_err(|error| error.to_string())?;
        if !metadata.is_file()
            || metadata.uid() != 0
            || metadata.mode() & 0o022 != 0
            || metadata.len() > 4096
        {
            return Err("profile must be a root-owned, protected regular file".into());
        }
        let bytes = fs::read(path).map_err(|error| error.to_string())?;
        serde_json::from_slice(&bytes).map_err(|error| error.to_string())
    }
}

pub(super) fn decode_ready(packet: &[u8]) -> bool {
    packet == [READY]
}

pub(super) fn decode_pulse(packet: &[u8]) -> bool {
    packet == [PULSE]
}

/// Where a pulse is.
#[derive(Clone, Copy, Debug)]
enum PulseStage {
    /// The shell fades to the picture while the backlight dims, until this.
    Preparing { deadline: Instant },
    /// The output is coming on.
    Lighting { started: Instant },
    /// Lit with the picture until this.
    Showing { until: Instant },
    /// Turning off again.
    Ending,
}

#[derive(Clone, Copy, Debug)]
struct Pulse {
    output: OutputId,
    stage: PulseStage,
}

/// An output lit only to draw the next minute.
#[derive(Clone, Copy, Debug)]
struct Refresh {
    output: OutputId,
    started: Instant,
    /// The frame is out and the output's power-off queued.
    shown: bool,
}

#[derive(Debug, Default)]
pub(super) struct AmbientDisplay {
    /// Outputs a Wayland client is turning off, such as the proximity sensor's
    /// during a call: that is a plain blank, with no lock and no picture.
    pub(super) client_off: BTreeSet<OutputId>,
    /// Loaded on use and again whenever the file changes, keyed by its
    /// modification time; None inside when there is no usable profile.
    profile: Option<(Option<SystemTime>, Option<Profile>)>,
    /// What the switch was last set to.
    switched: Option<bool>,
    /// A power-off held while the shell fades, with its deadline.
    held: Option<(OutputId, Instant)>,
    /// The held power-off waits on a still picture, not on the shell.
    settling: bool,
    /// A held power-off the shell let through, until the output is off.
    released: Option<OutputId>,
    /// Outputs whose shell shows the always-on picture.
    entered: BTreeSet<OutputId>,
    /// Entered outputs seen off: lit again by anything but a refresh, they
    /// ask for the rest back.
    dark: BTreeSet<OutputId>,
    /// When the next minute's frame is due.
    refresh_due: Option<Instant>,
    refresh: Option<Refresh>,
    pulse: Option<Pulse>,
}

impl AmbientDisplay {
    fn profile(&mut self) -> Option<&Profile> {
        let path = Path::new(PROFILE_PATH);
        let modified = fs::symlink_metadata(path)
            .and_then(|metadata| metadata.modified())
            .ok();
        if self
            .profile
            .as_ref()
            .is_none_or(|(key, _)| *key != modified)
        {
            let profile = modified.and_then(|_| match Profile::load(path) {
                Ok(profile) => {
                    info!(output = %profile.output, "always-on display profile loaded");
                    Some(profile)
                }
                Err(error) => {
                    warn!(%error, "always-on display profile rejected");
                    None
                }
            });
            self.profile = Some((modified, profile));
            if self.entered.is_empty() {
                // A switch left set would keep an unlocked blank lit.
                self.switched = None;
                self.set_switch(false);
            }
        }
        self.profile.as_ref()?.1.as_ref()
    }

    fn set_switch(&mut self, on: bool) {
        if self.switched == Some(on) {
            return;
        }
        let Some(path) = self
            .profile
            .as_ref()
            .and_then(|(_, profile)| profile.as_ref())
            .map(|profile| profile.switch.clone())
        else {
            return;
        };
        match fs::write(&path, if on { "Y" } else { "N" }) {
            Ok(()) => self.switched = Some(on),
            Err(error) => {
                warn!(%error, path = %path.display(), "could not set the always-on display switch");
            }
        }
    }

    /// Lit only to draw the next minute: still dark to everything else.
    pub(super) fn refreshing(&self, output: OutputId) -> bool {
        self.refresh.is_some_and(|refresh| refresh.output == output)
            || self.pulse.is_some_and(|pulse| pulse.output == output)
    }

    pub(super) fn refresh_under_way(&self) -> bool {
        self.refresh.is_some() || self.pulse.is_some()
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        [
            self.held.map(|(_, deadline)| deadline),
            self.refresh_due,
            self.refresh.map(|refresh| refresh.started + REFRESH_LIMIT),
            self.pulse.and_then(|pulse| match pulse.stage {
                PulseStage::Preparing { deadline } => Some(deadline),
                PulseStage::Lighting { started } => Some(started + REFRESH_LIMIT),
                PulseStage::Showing { until } => Some(until),
                PulseStage::Ending => None,
            }),
        ]
        .into_iter()
        .flatten()
        .fold(timeout, |timeout, deadline| {
            timeout.min(deadline.saturating_duration_since(now))
        })
    }
}

/// Holds the always-on output's power-off until the shell shows the picture,
/// lets a wake during the fade cancel it, and runs each minute's refresh.
/// Runs before power requests are applied.
pub(super) fn hold_power_off(
    runtime: &mut FlutterRuntime,
    scheduler: &OutputScheduler,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
) {
    let ready = runtime.take_ambient_display_ready();
    let pulse_requested = runtime.take_ambient_pulse();
    events.ambient_display.client_off.retain(|output| {
        scanouts
            .iter()
            .any(|scanout| scanout.output.id == *output && scanout.powered)
    });
    if pulse(runtime, scheduler, scanouts, events, now, ready, pulse_requested) {
        return;
    }
    if refresh(runtime, scheduler, scanouts, events, now) {
        return;
    }
    if let Some((output, deadline)) = events.ambient_display.held {
        match events.output_power_requests.get(&output) {
            Some(true) => {
                // Woken while fading: the output stays lit.
                events.ambient_display.held = None;
                events.ambient_display.settling = false;
                events.ambient_display.entered.remove(&output);
                leave(runtime, events);
                info!("always-on display cancelled by a wake");
            }
            _ if !events.ambient_display.settling && (ready || now >= deadline) => {
                if !ready {
                    warn!("shell did not show the always-on picture in time");
                }
                let settle = events
                    .ambient_display
                    .profile()
                    .map_or(Duration::ZERO, |profile| {
                        Duration::from_millis(profile.settle_ms)
                    });
                events.ambient_display.held = Some((output, now + settle));
                events.ambient_display.settling = true;
                events.output_power_requests.remove(&output);
            }
            _ if events.ambient_display.settling && now >= deadline => {
                events.ambient_display.held = None;
                events.ambient_display.settling = false;
                events.ambient_display.released = Some(output);
                events.ambient_display.set_switch(true);
                events.output_power_requests.insert(output, false);
            }
            _ => {
                events.output_power_requests.remove(&output);
            }
        }
        return;
    }

    if let Some(output) = events
        .ambient_display
        .released
        .filter(|output| events.output_power_requests.get(output) == Some(&true))
    {
        // Woken before the output went off: it stays lit.
        events.ambient_display.released = None;
        events.ambient_display.entered.remove(&output);
        leave(runtime, events);
        return;
    }
    let Some((output, beside_desk)) = power_off_to_hold(scanouts, events) else {
        return;
    };
    if events.ambient_display.released == Some(output) {
        return;
    }
    // Beside a desk the session stays unlocked while the phone is dark, and
    // the shell shows the lock screen's clock without the lock.
    if !beside_desk {
        let locked = events
            .authentication
            .as_ref()
            .is_some_and(|authentication| authentication.lock_automatically());
        if !locked {
            // The always-on picture is the lock screen's; without one the
            // output turns off as usual.
            return;
        }
        super::synchronize_authentication_boundary(events);
    }
    events.output_power_requests.remove(&output);
    events.ambient_display.held = Some((output, now + FADE_LIMIT));
    events.ambient_display.entered.insert(output);
    send(runtime, ENTER);
    fade_backlight(events, true);
    info!("always-on display: waiting for the shell's picture");
}

/// Lights a dark always-on output for each minute's frame, and turns it off
/// again once the frame is out. True while one is under way.
fn refresh(
    runtime: &mut FlutterRuntime,
    scheduler: &OutputScheduler,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
) -> bool {
    let state = &mut events.ambient_display;
    if let Some(mut refresh) = state.refresh {
        let output = refresh.output;
        let Some(scanout) = scanouts.iter().find(|scanout| scanout.output.id == output) else {
            state.refresh = None;
            return false;
        };
        if events.output_power_requests.get(&output) == Some(&true) {
            // Woken meanwhile: the panel leaves its always-on state lit.
            state.refresh = None;
            state.dark.remove(&output);
            state.entered.remove(&output);
            leave(runtime, events);
            info!("always-on display woken during a refresh");
            return false;
        }
        if refresh.shown {
            if !scanout.powered {
                state.refresh = None;
                state.refresh_due = Some(next_minute(now));
            }
        } else if scanout.powered && !scheduler.power_on_pending(output)
            || now >= refresh.started + REFRESH_LIMIT
        {
            if now >= refresh.started + REFRESH_LIMIT {
                warn!("always-on refresh frame did not come in time");
            }
            refresh.shown = true;
            state.refresh = Some(refresh);
            events.output_power_requests.insert(output, false);
        }
        return true;
    }

    if state.held.is_some() || state.refresh_due.is_none_or(|due| now < due) {
        return false;
    }
    state.refresh_due = None;
    let Some(output) = state.dark.first().copied() else {
        return false;
    };
    let dark = scanouts
        .iter()
        .any(|scanout| scanout.output.id == output && !scanout.powered);
    if !dark || events.output_power_requests.contains_key(&output) {
        return false;
    }
    state.refresh = Some(Refresh {
        output,
        started: now,
        shown: false,
    });
    events.output_power_requests.insert(output, true);
    true
}

/// Runs a pulse the shell asked for: the picture lit at its backlight code
/// for the profile's `pulse_ms`, then dark again. True while one is under
/// way.
fn pulse(
    runtime: &mut FlutterRuntime,
    scheduler: &OutputScheduler,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
    ready: bool,
    requested: bool,
) -> bool {
    if let Some(mut pulse) = events.ambient_display.pulse {
        let output = pulse.output;
        let Some(scanout) = scanouts.iter().find(|scanout| scanout.output.id == output) else {
            events.ambient_display.pulse = None;
            return false;
        };
        let woken = events.output_power_requests.get(&output) == Some(&true);
        match pulse.stage {
            PulseStage::Preparing { .. } | PulseStage::Showing { .. } if woken => {
                // Woken during the pulse: it stays lit, as a wake leaves it.
                events.ambient_display.pulse = None;
                leave(runtime, events);
                info!("ambient pulse ended by a wake");
                return false;
            }
            PulseStage::Preparing { deadline } => {
                if ready || now >= deadline {
                    pulse.stage = PulseStage::Lighting { started: now };
                    events.output_power_requests.insert(output, true);
                }
            }
            PulseStage::Lighting { started } => {
                if scanout.powered && !scheduler.power_on_pending(output) {
                    let shown = events
                        .ambient_display
                        .profile()
                        .and_then(|profile| profile.pulse_ms)
                        .unwrap_or(3000);
                    pulse.stage = PulseStage::Showing {
                        until: now + Duration::from_millis(shown),
                    };
                } else if now >= started + REFRESH_LIMIT {
                    warn!("ambient pulse: the output did not light in time");
                    pulse.stage = PulseStage::Ending;
                    events.output_power_requests.insert(output, false);
                }
            }
            PulseStage::Showing { until } => {
                if now >= until {
                    pulse.stage = PulseStage::Ending;
                    events.output_power_requests.insert(output, false);
                }
            }
            PulseStage::Ending => {
                if !scanout.powered {
                    events.ambient_display.pulse = None;
                    leave(runtime, events);
                    return false;
                }
            }
        }
        events.ambient_display.pulse = Some(pulse);
        return true;
    }

    if !requested {
        return false;
    }
    if !start_pulse(runtime, scanouts, events, now) {
        // No pulse here: the notification wakes the screen as it used to.
        let requests = events.idle_policy.note_activity(now);
        events.queue_idle_power_requests(requests);
        info!("notification woke the screen");
        return false;
    }
    true
}

/// Starts a pulse when the phone is locked with its always-on output dark.
fn start_pulse(
    runtime: &mut FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
    now: Instant,
) -> bool {
    let state = &mut events.ambient_display;
    if state.held.is_some() || state.refresh.is_some() || !state.entered.is_empty() {
        // The always-on picture already shows, or is on its way.
        return false;
    }
    let Some(name) = state
        .profile()
        .filter(|profile| profile.pulse_ms.is_some())
        .map(|profile| profile.output.clone())
    else {
        return false;
    };
    let Some(output) = scanouts
        .iter()
        .find(|scanout| scanout.output.name == name && !scanout.powered)
        .map(|scanout| scanout.output.id)
    else {
        // Lit already: the notification shows as usual.
        return false;
    };
    let locked = events
        .authentication
        .as_ref()
        .is_some_and(|authentication| authentication.lock_automatically());
    if !locked || events.output_power_requests.contains_key(&output) {
        return false;
    }
    events.ambient_display.pulse = Some(Pulse {
        output,
        stage: PulseStage::Preparing {
            deadline: now + FADE_LIMIT,
        },
    });
    send(runtime, ENTER_PULSE);
    fade_backlight(events, true);
    info!("ambient pulse for a notification");
    true
}

/// The instant the shell's clock shows the next minute.
fn next_minute(now: Instant) -> Instant {
    let into = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(Duration::ZERO, |since| {
            Duration::from_millis((since.as_millis() % 60_000) as u64)
        });
    now + (Duration::from_secs(60) - into) + REFRESH_LAG
}

/// The lit output whose power-off the always-on display takes over, and
/// whether a desk shares the session with it.
fn power_off_to_hold(scanouts: &[Scanout], events: &mut RuntimeState) -> Option<(OutputId, bool)> {
    let frontend = events.wayland.as_ref()?;
    if !frontend.mobile_shell() {
        return None;
    }
    let beside_desk = frontend.phone_with_desk();
    let name = events
        .ambient_display
        .profile()
        .filter(|profile| profile.always_on)?
        .output
        .clone();
    let scanout = scanouts
        .iter()
        .find(|scanout| scanout.output.name == name && scanout.powered)?;
    let output = scanout.output.id;
    if events.ambient_display.client_off.contains(&output) {
        return None;
    }
    (events.output_power_requests.get(&output) == Some(&false)).then_some((output, beside_desk))
}

/// Asks the shell for the rest of the lock screen once the output is lit
/// again, and keeps touches out of a refresh. Runs after power requests are
/// applied.
pub(super) fn synchronize_wake(
    runtime: &mut FlutterRuntime,
    scanouts: &[Scanout],
    events: &mut RuntimeState,
) {
    let state = &mut events.ambient_display;
    let mut woke = false;
    for scanout in scanouts {
        let output = scanout.output.id;
        if !state.entered.contains(&output) || state.refreshing(output) {
            continue;
        }
        if !scanout.powered {
            if state.dark.insert(output) {
                state.refresh_due = Some(next_minute(Instant::now()));
            }
            if state.released == Some(output) {
                state.released = None;
            }
        } else if state.dark.remove(&output) {
            state.entered.remove(&output);
            woke = true;
        }
    }
    if woke {
        leave(runtime, events);
    }
    let refreshing = events.ambient_display.refresh_under_way();
    events.screen_off_touch.set_dark(refreshing);
}

/// Asks the shell for the rest of the lock screen, the panel for its usual
/// state and the backlight for its level.
fn leave(runtime: &mut FlutterRuntime, events: &mut RuntimeState) {
    let state = &mut events.ambient_display;
    state.refresh_due = None;
    state.refresh = None;
    state.set_switch(false);
    send(runtime, LEAVE);
    fade_backlight(events, false);
}

/// Fades the always-on output's backlight to the picture's code, or back.
fn fade_backlight(events: &mut RuntimeState, dim: bool) {
    let Some(profile) = events.ambient_display.profile() else {
        return;
    };
    let toward = if dim {
        BrightnessFade::Dim {
            raw: profile.brightness,
            duration: SHELL_FADE,
        }
    } else {
        BrightnessFade::Restore {
            duration: SHELL_FADE,
        }
    };
    let output = profile.output.clone();
    if let Some(controls) = &events.system_controls {
        controls.fade_brightness(output, toward);
    }
}

fn send(runtime: &mut FlutterRuntime, command: u8) {
    if let Err(error) = runtime.send_ambient_display(command) {
        warn!(%error, "could not tell the shell about the always-on display");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_minute_lands_just_after_the_minute() {
        let now = Instant::now();
        let wait = next_minute(now) - now;
        assert!(wait > REFRESH_LAG && wait <= Duration::from_secs(60) + REFRESH_LAG);
    }
}
