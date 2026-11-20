//! Low-frequency device-orientation input from steinerd.
//!
//! D-Bus is deliberately isolated on a helper thread. The compositor receives
//! only already-classified cardinal changes through calloop, so sensor service
//! activation, reconnects and property reads can never delay a render tick.
//!
//! The claim is held only while a panel that follows the sensor is lit: with
//! the screen off, steinerd stops the accelerometer and the DSP stops sending.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use denial_core::topology::OutputTransform;
use futures_lite::{StreamExt, future};
use smithay::reexports::calloop::channel::{Channel, Sender, channel};
use tracing::{debug, info, warn};
use zbus::blocking::Proxy;

const SENSOR_SERVICE: &str = "org.steinerd";
const SENSOR_PATH: &str = "/org/steinerd";
const SENSOR_INTERFACE: &str = "org.steinerd.Sensors1";
const SENSOR: &str = "orientation";
use super::wayland_frontend::orientation::RequestedOrientation;

const RECONNECT_DELAY: Duration = Duration::from_secs(2);

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Orientation {
    Undefined,
    Normal,
    BottomUp,
    LeftUp,
    RightUp,
}

impl Orientation {
    pub(super) const fn output_rotation(self) -> OutputTransform {
        match self {
            Self::Undefined | Self::Normal => OutputTransform::Normal,
            Self::BottomUp => OutputTransform::Rotate180,
            // steinerd names the physical edge which points upward.
            // The desktop must turn in the opposite direction to remain
            // upright in panel coordinates.
            Self::LeftUp => OutputTransform::Rotate90,
            Self::RightUp => OutputTransform::Rotate270,
        }
    }

    /// Service loss and unknown readings are not an instruction to return to
    /// natural orientation. Keep the last valid reading for later unlocking.
    pub(super) fn update_rotation(self, latest: &mut OutputTransform) {
        if self != Self::Undefined {
            *latest = self.output_rotation();
        }
    }

    /// Coalescing must not let a service-loss marker erase a valid reading
    /// already queued during the same calloop dispatch.
    pub(super) fn update_pending(self, pending: &mut Option<Self>) {
        if self != Self::Undefined {
            *pending = Some(self);
        }
    }

    fn parse(value: &str) -> Self {
        match value {
            "normal" => Self::Normal,
            "bottom-up" => Self::BottomUp,
            "left-up" => Self::LeftUp,
            "right-up" => Self::RightUp,
            _ => Self::Undefined,
        }
    }
}

/// The rotation the front application window asks for, as Android turns its
/// display for an activity's requested orientation: `None` leaves it to the
/// rotation lock and the sensor. `latest` is the latest valid sensor reading,
/// `current` the rotation the panel has now.
pub(super) fn requested_rotation(
    requested: RequestedOrientation,
    latest: OutputTransform,
    current: OutputTransform,
) -> Option<OutputTransform> {
    // Android's fixed landscape (ROTATION_90): the phone turned
    // counter-clockwise, its right edge up.
    const LANDSCAPE: OutputTransform = Orientation::RightUp.output_rotation();
    let landscape = |rotation: OutputTransform| {
        matches!(
            rotation,
            OutputTransform::Rotate90 | OutputTransform::Rotate270
        )
    };
    match requested {
        RequestedOrientation::Unspecified => None,
        RequestedOrientation::Portrait => Some(OutputTransform::Normal),
        RequestedOrientation::Landscape => Some(LANDSCAPE),
        // The side the phone is held on, else the side it is on, else the
        // fixed one.
        RequestedOrientation::SensorLandscape => Some(if landscape(latest) {
            latest
        } else if landscape(current) {
            current
        } else {
            LANDSCAPE
        }),
        RequestedOrientation::Sensor => Some(latest),
        RequestedOrientation::Locked => Some(current),
    }
}

/// Select policy independently of renderer readiness: deferred applications
/// still retain the latest observation, while a lock retains the applied one.
pub(super) fn select_rotation(
    latest: OutputTransform,
    locked: Option<OutputTransform>,
) -> OutputTransform {
    locked.unwrap_or(latest)
}

pub(super) struct OrientationSensor {
    demand: Arc<Demand>,
    _worker: JoinHandle<()>,
}

impl OrientationSensor {
    pub(super) fn start() -> Result<(Self, Channel<Orientation>), std::io::Error> {
        let (events, source) = channel();
        let demand = Arc::new(Demand {
            wanted: AtomicBool::new(true),
            changed: crate::wakeup::Wakeup::new()?,
        });
        let worker_demand = Arc::clone(&demand);
        let worker = thread::Builder::new()
            .name("denial-orientation".to_owned())
            .spawn(move || {
                crate::cpu_scheduling::normalize_current_worker("orientation");
                monitor(events, &worker_demand);
            })?;
        Ok((
            Self {
                demand,
                _worker: worker,
            },
            source,
        ))
    }

    /// Whether a lit panel follows the sensor. The last reading stays applied
    /// while the claim is released.
    pub(super) fn set_wanted(&self, wanted: bool) {
        if self.demand.wanted.swap(wanted, Ordering::AcqRel) != wanted {
            self.demand.changed.wake();
        }
    }
}

struct Demand {
    wanted: AtomicBool,
    changed: crate::wakeup::Wakeup,
}

impl Demand {
    fn wanted(&self) -> bool {
        self.wanted.load(Ordering::Acquire)
    }

    fn wait_until_wanted(&self) {
        while !self.wanted() {
            future::block_on(self.changed.wait());
        }
    }
}

fn monitor(events: Sender<Orientation>, demand: &Demand) {
    let mut published = None;
    loop {
        match monitor_bus(&events, &mut published, demand) {
            MonitorResult::Closed => return,
            MonitorResult::Disconnected(error) => {
                if publish(&events, &mut published, Orientation::Undefined).is_err() {
                    return;
                }
                debug!(%error, "system bus is unavailable to the orientation sensor");
                thread::sleep(RECONNECT_DELAY);
            }
        }
    }
}

enum MonitorResult {
    Closed,
    Disconnected(String),
}

enum SensorResult {
    Closed,
    Failed(String),
    OwnerChanged { present: bool },
    Unwanted,
}

enum Wake<C, O> {
    Change(Option<C>),
    Owner(Option<O>),
    Demand,
}

/// Follows the sensor for as long as one system bus connection lives. A
/// missing or failed sensor service is never polled: the worker sleeps until
/// steinerd gains a new owner, which also covers a later start.
fn monitor_bus(
    events: &Sender<Orientation>,
    published: &mut Option<Orientation>,
    demand: &Demand,
) -> MonitorResult {
    let connection = match crate::bus::blocking_system() {
        Ok(connection) => connection,
        Err(error) => return MonitorResult::Disconnected(error.to_string()),
    };
    let proxy = match Proxy::new(&connection, SENSOR_SERVICE, SENSOR_PATH, SENSOR_INTERFACE) {
        Ok(proxy) => proxy,
        Err(error) => return MonitorResult::Disconnected(error.to_string()),
    };
    // Subscribe before the first claim, so an owner which appears while a
    // claim fails still wakes the worker.
    let mut owners = match future::block_on(proxy.inner().receive_owner_changed()) {
        Ok(owners) => owners,
        Err(error) => return MonitorResult::Disconnected(error.to_string()),
    };
    loop {
        demand.wait_until_wanted();
        let present = match follow_sensor(&proxy, &mut owners, events, published, demand) {
            SensorResult::Closed => return MonitorResult::Closed,
            SensorResult::Unwanted => continue,
            SensorResult::Failed(error) => {
                debug!(%error, "orientation sensor service is unavailable");
                false
            }
            SensorResult::OwnerChanged { present } => present,
        };
        if publish(events, published, Orientation::Undefined).is_err() {
            return MonitorResult::Closed;
        }
        if present {
            continue;
        }
        loop {
            match future::block_on(owners.next()) {
                None => return MonitorResult::Disconnected("system bus closed".to_owned()),
                Some(Some(_)) => break,
                Some(None) => {}
            }
        }
    }
}

fn follow_sensor<O>(
    proxy: &Proxy<'_>,
    owners: &mut O,
    events: &Sender<Orientation>,
    published: &mut Option<Orientation>,
    demand: &Demand,
) -> SensorResult
where
    O: futures_lite::Stream<Item = Option<zbus::names::UniqueName<'static>>> + Unpin,
{
    let mut changes = future::block_on(
        proxy
            .inner()
            .receive_property_changed::<String>("Orientation"),
    );
    if let Err(error) = proxy.call::<_, _, ()>("Claim", &(SENSOR,)) {
        return SensorResult::Failed(error.to_string());
    }

    let has_orientation = proxy
        .get_property::<bool>("HasOrientation")
        .unwrap_or(false);
    let initial = if has_orientation {
        proxy
            .get_property::<String>("Orientation")
            .map(|value| Orientation::parse(&value))
            .unwrap_or(Orientation::Undefined)
    } else {
        Orientation::Undefined
    };
    if publish(events, published, initial).is_err() {
        drop(changes);
        let _ = proxy.call::<_, _, ()>("Release", &(SENSOR,));
        return SensorResult::Closed;
    }
    if initial != Orientation::Undefined {
        info!(orientation = ?initial, "claimed the system orientation sensor");
    }

    let result = loop {
        let sensor = future::race(async { Wake::Change(changes.next().await) }, async {
            Wake::Owner(owners.next().await)
        });
        let demand_changed = async {
            demand.changed.wait().await;
            Wake::Demand
        };
        let wake = future::block_on(future::or(demand_changed, sensor));
        let change = match wake {
            Wake::Demand if demand.wanted() => continue,
            Wake::Demand => break SensorResult::Unwanted,
            Wake::Change(Some(change)) => change,
            Wake::Change(None) => {
                break SensorResult::Failed("orientation sensor signal stream ended".to_owned());
            }
            // A new owner has no claim to release; the bus closing is seen
            // again by the caller's owner stream.
            Wake::Owner(Some(owner)) => {
                return SensorResult::OwnerChanged {
                    present: owner.is_some(),
                };
            }
            Wake::Owner(None) => return SensorResult::Failed("system bus closed".to_owned()),
        };
        let orientation = match future::block_on(change.get()) {
            Ok(value) => Orientation::parse(&value),
            Err(error) => {
                warn!(%error, "could not read orientation sensor update");
                break SensorResult::Failed(error.to_string());
            }
        };
        if publish(events, published, orientation).is_err() {
            break SensorResult::Closed;
        }
    };
    drop(changes);
    let _ = proxy.call::<_, _, ()>("Release", &(SENSOR,));
    result
}

fn publish(
    events: &Sender<Orientation>,
    published: &mut Option<Orientation>,
    orientation: Orientation,
) -> Result<(), ()> {
    if *published == Some(orientation) {
        return Ok(());
    }
    events.send(orientation).map_err(|_| ())?;
    *published = Some(orientation);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_orientation_follows_android_rules() {
        use OutputTransform::{Normal, Rotate90, Rotate180, Rotate270};
        let landscape = Orientation::RightUp.output_rotation();
        let rule = |requested, latest, current| requested_rotation(requested, latest, current);
        assert_eq!(
            rule(RequestedOrientation::Unspecified, Rotate90, Normal),
            None
        );
        assert_eq!(
            rule(RequestedOrientation::Portrait, Rotate90, Rotate90),
            Some(Normal)
        );
        // Fixed landscape ignores the sensor's side.
        assert_eq!(
            rule(RequestedOrientation::Landscape, Normal, Normal),
            Some(landscape)
        );
        assert_eq!(
            rule(RequestedOrientation::Landscape, Rotate90, Rotate90),
            Some(landscape)
        );
        // Sensor landscape: the held side, else the current one, else fixed.
        assert_eq!(
            rule(RequestedOrientation::SensorLandscape, Rotate90, Normal),
            Some(Rotate90)
        );
        assert_eq!(
            rule(RequestedOrientation::SensorLandscape, Rotate270, Rotate90),
            Some(Rotate270)
        );
        assert_eq!(
            rule(RequestedOrientation::SensorLandscape, Normal, Rotate90),
            Some(Rotate90)
        );
        assert_eq!(
            rule(RequestedOrientation::SensorLandscape, Rotate180, Normal),
            Some(landscape)
        );
        assert_eq!(
            rule(RequestedOrientation::Sensor, Rotate180, Normal),
            Some(Rotate180)
        );
        assert_eq!(
            rule(RequestedOrientation::Locked, Rotate90, Rotate270),
            Some(Rotate270)
        );
    }

    #[test]
    fn rotation_lock_coalescing_keeps_valid_reading_before_service_loss() {
        let mut pending = None;
        Orientation::Undefined.update_pending(&mut pending);
        assert_eq!(pending, None);
        Orientation::LeftUp.update_pending(&mut pending);
        Orientation::RightUp.update_pending(&mut pending);
        Orientation::Undefined.update_pending(&mut pending);
        assert_eq!(pending, Some(Orientation::RightUp));
    }

    #[test]
    fn rotation_lock_keeps_latest_valid_reading_for_unlock() {
        let frozen = OutputTransform::Rotate90;
        let mut latest = frozen;
        Orientation::BottomUp.update_rotation(&mut latest);
        assert_eq!(select_rotation(latest, Some(frozen)), frozen);
        Orientation::RightUp.update_rotation(&mut latest);
        Orientation::Undefined.update_rotation(&mut latest);
        assert_eq!(select_rotation(latest, Some(frozen)), frozen);
        assert_eq!(select_rotation(latest, None), OutputTransform::Rotate270);
        Orientation::Normal.update_rotation(&mut latest);
        assert_eq!(select_rotation(latest, None), OutputTransform::Normal);
    }

    #[test]
    fn physical_edge_orientation_uses_wayland_rotation_direction() {
        assert_eq!(
            Orientation::LeftUp.output_rotation(),
            OutputTransform::Rotate90
        );
        assert_eq!(
            Orientation::RightUp.output_rotation(),
            OutputTransform::Rotate270
        );
    }
}
