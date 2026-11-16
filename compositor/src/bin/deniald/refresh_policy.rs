//! Automatic refresh rate for panels that change rate without a modeset.
//!
//! A command mode panel whose driver switches rates live accepts a new
//! `MODE_ID` with the same size, line length and pixel clock in a plain atomic
//! commit, without `ALLOW_MODESET`. Such an output runs at its configured rate
//! while the user interacts and while content keeps drawing faster than the
//! low rate, and drops to the low rate when it settles. The switch is a
//! CRTC-only nonblocking commit: the kernel applies it between two frames, so
//! nothing blanks and the plane pipeline keeps its own commits.

use std::collections::VecDeque;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use super::*;
use super::kms_state::optional_named_property;

/// Stay at the configured rate this long after the last input event.
const BOOST_AFTER_INPUT: Duration = Duration::from_millis(1000);
/// Window for the presented frame rate.
const RATE_WINDOW: Duration = Duration::from_millis(250);
/// Content presenting faster than this keeps the configured rate.
const FAST_CONTENT_MILLIHZ: u64 = 80_000;
/// How long fast content holds the configured rate after its last window.
const BOOST_AFTER_FAST_CONTENT: Duration = Duration::from_millis(300);
/// Pause before retrying a commit the kernel refused as busy.
const BUSY_RETRY: Duration = Duration::from_millis(2);
/// The low rate an idle output drops to.
const LOW_REFRESH_MILLIHZ: i32 = 60_000;
/// How often the CRTC's mode is read back while an output runs its low rate.
/// A full commit (display power-on, session resume, sleep restoration) sets
/// the configured mode again, and not every path changes what the policy
/// observes.
const VERIFY_INTERVAL: Duration = Duration::from_secs(1);
/// A powered output whose CRTC does not run its mode yet (the power-on
/// commit is still on its way) is looked at again this often, this many
/// times.
const PENDING_RETRY: Duration = Duration::from_millis(250);
const PENDING_ATTEMPTS: u32 = 20;

static LAST_INTERACTION: Mutex<Option<Instant>> = Mutex::new(None);

/// The user produced an input event.
pub(super) fn note_interaction() {
    *LAST_INTERACTION
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(Instant::now());
}

fn last_interaction() -> Option<Instant> {
    *LAST_INTERACTION
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

fn refresh_millihz(mode: Mode) -> i32 {
    OutputMode::from(mode).refresh
}

/// Whether `low` keeps the link timing of `high`: only the vertical blanking,
/// and so the refresh rate, differs.
fn same_link(high: Mode, low: Mode) -> bool {
    high.size() == low.size()
        && high.hsync() == low.hsync()
        && high.clock() == low.clock()
        && high.flags() == low.flags()
}

fn same_timing(a: Mode, b: Mode) -> bool {
    same_link(a, b) && a.vsync() == b.vsync()
}

struct AdaptiveOutput {
    output: OutputId,
    crtc: crtc::Handle,
    mode_id: property::Handle,
    /// The configured mode; the kernel runs it after every full commit.
    high: Mode,
    low: Mode,
    low_active: bool,
    /// The CRTC runs `high` or `low`; false while it is off or runs
    /// another mode, when nothing is committed.
    live: bool,
}

pub(super) struct RefreshPolicy {
    enabled: bool,
    outputs: Vec<AdaptiveOutput>,
    /// Configured mode and power of every scanout at the last evaluation.
    observed: Vec<(OutputId, Mode, bool)>,
    frames: VecDeque<(Instant, u64)>,
    boost_until: Option<Instant>,
    retry_at: Option<Instant>,
    verify_at: Option<Instant>,
    /// When to rebuild again for an output whose CRTC was not running yet,
    /// and how many attempts are left.
    pending_at: Option<Instant>,
    pending_attempts: u32,
}

impl RefreshPolicy {
    pub(super) fn new() -> Self {
        let enabled = std::env::var("DENIAL_AUTO_REFRESH").map_or(true, |value| value != "0");
        if !enabled {
            info!("automatic refresh rate disabled by DENIAL_AUTO_REFRESH=0");
        }
        Self {
            enabled,
            outputs: Vec::new(),
            observed: Vec::new(),
            frames: VecDeque::new(),
            boost_until: None,
            retry_at: None,
            verify_at: None,
            pending_at: None,
            pending_attempts: 0,
        }
    }

    /// Rebuilds the adaptive outputs after a configuration or power change.
    /// Every full commit sets the configured mode again, so each output starts
    /// at its high rate.
    /// Says whether a powered output's CRTC did not run its mode yet.
    fn rebuild(&mut self, drm: &DrmDevice, scanouts: &mut [Scanout]) -> bool {
        let mut pending = false;
        self.outputs.clear();
        self.observed = scanouts
            .iter()
            .map(|scanout| (scanout.output.id, scanout.output.mode, scanout.powered))
            .collect();
        for scanout in scanouts.iter_mut() {
            scanout.effective_mode = None;
            if !scanout.powered {
                continue;
            }
            match adaptive_output(drm, scanout) {
                Ok(Some(output)) => {
                    info!(
                        output = scanout.output.name,
                        high_millihz = refresh_millihz(output.high),
                        low_millihz = refresh_millihz(output.low),
                        "automatic refresh rate"
                    );
                    self.outputs.push(output);
                }
                Ok(None) => {}
                Err(Eligibility::NotRunning) => pending = true,
                Err(Eligibility::Failed(error)) => {
                    debug!(output = scanout.output.name, %error, "no automatic refresh rate");
                }
            }
        }
        pending
    }

    /// Picks each output's rate and commits a change. `presented_frames`
    /// counts every page flip presented so far.
    pub(super) fn service(
        &mut self,
        now: Instant,
        drm: &DrmDevice,
        scanouts: &mut [Scanout],
        presented_frames: u64,
        frame_scheduler: &mut frame_scheduler::FrameScheduler,
    ) {
        if !self.enabled || !drm.is_active() {
            return;
        }
        let changed = self.observed.len() != scanouts.len()
            || scanouts.iter().zip(&self.observed).any(|(scanout, observed)| {
                *observed != (scanout.output.id, scanout.output.mode, scanout.powered)
            });
        let retry_pending = self.pending_at.is_some_and(|at| now >= at);
        if changed || retry_pending {
            if changed {
                self.pending_attempts = PENDING_ATTEMPTS;
            }
            let pending = self.rebuild(drm, scanouts);
            self.pending_at = None;
            if pending && self.pending_attempts > 0 {
                self.pending_attempts -= 1;
                self.pending_at = Some(now + PENDING_RETRY);
            }
            frame_scheduler.retime(scanouts);
            self.boost_until = Some(now + BOOST_AFTER_INPUT);
        }
        if self.outputs.is_empty() {
            return;
        }

        self.frames.push_back((now, presented_frames));
        while self
            .frames
            .front()
            .is_some_and(|(at, _)| now.saturating_duration_since(*at) > RATE_WINDOW)
            && self.frames.len() > 1
        {
            self.frames.pop_front();
        }
        if let Some(interaction) = last_interaction() {
            let until = interaction + BOOST_AFTER_INPUT;
            if self.boost_until.is_none_or(|boost| boost < until) {
                self.boost_until = Some(until);
            }
        }
        if let (Some((first_at, first)), Some((last_at, last))) =
            (self.frames.front(), self.frames.back())
        {
            let span = last_at.saturating_duration_since(*first_at);
            if span >= RATE_WINDOW / 2 {
                let millihz = (last - first) * 1_000_000_000_000 / span.as_nanos().max(1) as u64;
                if millihz >= FAST_CONTENT_MILLIHZ {
                    let until = now + BOOST_AFTER_FAST_CONTENT;
                    if self.boost_until.is_none_or(|boost| boost < until) {
                        self.boost_until = Some(until);
                    }
                }
            }
        }
        let mut retimed = false;
        if self.verify_at.is_none_or(|at| now >= at) {
            self.verify_at = Some(now + VERIFY_INTERVAL);
            retimed |= self.verify(drm, scanouts);
        }
        if self.retry_at.is_some_and(|retry| now < retry) {
            if retimed {
                frame_scheduler.retime(scanouts);
            }
            return;
        }
        self.retry_at = None;

        let want_low = self.boost_until.is_none_or(|boost| now >= boost);
        for output in &mut self.outputs {
            if !output.live || output.low_active == want_low {
                continue;
            }
            let mode = if want_low { output.low } else { output.high };
            match commit_mode(drm, output.crtc, output.mode_id, mode, false) {
                Ok(()) => {
                    output.low_active = want_low;
                    if let Some(scanout) = scanouts
                        .iter_mut()
                        .find(|scanout| scanout.output.id == output.output)
                    {
                        scanout.effective_mode = want_low.then_some(output.low);
                    }
                    retimed = true;
                    debug!(
                        refresh_millihz = refresh_millihz(mode),
                        "switched refresh rate"
                    );
                }
                Err(error) if error.raw_os_error() == Some(libc::EBUSY) => {
                    self.retry_at = Some(now + BUSY_RETRY);
                }
                Err(error) => {
                    warn!(%error, "refresh rate switch failed; keeping the configured rate");
                    if let Some(scanout) = scanouts
                        .iter_mut()
                        .find(|scanout| scanout.output.id == output.output)
                    {
                        scanout.effective_mode = None;
                    }
                    retimed = true;
                    output.low_active = false;
                    output.low = output.high;
                }
            }
        }
        if retimed {
            frame_scheduler.retime(scanouts);
        }
    }

    /// Reads each CRTC's mode back and follows what the kernel runs; says
    /// whether a frame clock changed.
    fn verify(&mut self, drm: &DrmDevice, scanouts: &mut [Scanout]) -> bool {
        let mut retimed = false;
        for output in &mut self.outputs {
            let current = drm.get_crtc(output.crtc).ok().and_then(|crtc| crtc.mode());
            let (live, low_active) = match current {
                Some(mode) if same_timing(mode, output.low) => (true, true),
                Some(mode) if same_timing(mode, output.high) => (true, false),
                _ => (false, false),
            };
            output.live = live;
            if output.low_active != low_active {
                debug!(low_active, "the CRTC's refresh rate changed outside the policy");
                output.low_active = low_active;
                if let Some(scanout) = scanouts
                    .iter_mut()
                    .find(|scanout| scanout.output.id == output.output)
                {
                    scanout.effective_mode = low_active.then_some(output.low);
                }
                retimed = true;
            }
        }
        retimed
    }

    pub(super) fn limit_dispatch_timeout(&self, now: Instant, timeout: Duration) -> Duration {
        let mut timeout = timeout;
        if let Some(pending) = self.pending_at {
            timeout = timeout.min(pending.saturating_duration_since(now));
        }
        if self.outputs.is_empty() {
            return timeout;
        }
        if let Some(retry) = self.retry_at {
            timeout = timeout.min(retry.saturating_duration_since(now));
        }
        if self.outputs.iter().any(|output| !output.low_active)
            && let Some(boost) = self.boost_until
        {
            timeout = timeout.min(boost.saturating_duration_since(now));
        }
        // A reset to the high rate is found by the next read-back.
        if self.outputs.iter().any(|output| output.low_active)
            && let Some(verify) = self.verify_at
        {
            timeout = timeout.min(verify.saturating_duration_since(now));
        }
        timeout
    }
}

/// Why an output has no automatic refresh rate now.
enum Eligibility {
    /// Its CRTC does not run the configured mode yet.
    NotRunning,
    Failed(Box<dyn Error>),
}

impl From<std::io::Error> for Eligibility {
    fn from(error: std::io::Error) -> Self {
        Self::Failed(error.into())
    }
}

impl From<Box<dyn Error>> for Eligibility {
    fn from(error: Box<dyn Error>) -> Self {
        Self::Failed(error)
    }
}

fn adaptive_output(
    drm: &DrmDevice,
    scanout: &Scanout,
) -> Result<Option<AdaptiveOutput>, Eligibility> {
    let high = scanout.output.mode;
    if refresh_millihz(high) <= LOW_REFRESH_MILLIHZ + 500 {
        return Ok(None);
    }
    // A mode change on a CRTC that is off needs a modeset: test only once
    // the power-on commit runs the configured mode.
    let running = drm.get_crtc(scanout.output.crtc)?.mode();
    if !running.is_some_and(|mode| same_timing(mode, high)) {
        return Err(Eligibility::NotRunning);
    }
    let Some(low) = drm
        .get_connector(scanout.output.connector, false)?
        .modes()
        .iter()
        .copied()
        .filter(|mode| same_link(high, *mode))
        .find(|mode| (refresh_millihz(*mode) - LOW_REFRESH_MILLIHZ).abs() <= 500)
    else {
        return Ok(None);
    };
    let Some(mode_id) = optional_named_property(drm, scanout.output.crtc, "MODE_ID")? else {
        return Ok(None);
    };
    // Only a kernel that switches this panel live takes the mode without a
    // modeset.
    if let Err(error) = commit_mode(drm, scanout.output.crtc, mode_id, low, true) {
        debug!(output = scanout.output.name, %error, "live refresh switch refused");
        return Ok(None);
    }
    Ok(Some(AdaptiveOutput {
        output: scanout.output.id,
        crtc: scanout.output.crtc,
        mode_id,
        high,
        low,
        low_active: false,
        live: true,
    }))
}

fn commit_mode(
    drm: &DrmDevice,
    crtc: crtc::Handle,
    mode_id: property::Handle,
    mode: Mode,
    test_only: bool,
) -> std::io::Result<()> {
    let blob = drm.create_property_blob(&mode)?;
    let mut request = AtomicModeReq::new();
    request.add_property(crtc, mode_id, blob);
    let flags = if test_only {
        AtomicCommitFlags::TEST_ONLY
    } else {
        AtomicCommitFlags::NONBLOCK
    };
    let result = drm.atomic_commit(flags, request);
    if let property::Value::Blob(id) = blob
        && let Err(error) = drm.destroy_property_blob(id)
    {
        debug!(%error, "could not release a refresh mode blob");
    }
    result
}
