//! Application windows' preferred display orientation
//! (`protocol/denial-orientation-v1.xml`), as Android activities request one.

use super::*;
use smithay::reexports::wayland_server::{Client, DataInit, Dispatch, GlobalDispatch, New, WEnum};
use std::sync::Mutex;

pub mod protocol {
    pub mod server {
        #![allow(
            dead_code,
            non_camel_case_types,
            non_upper_case_globals,
            non_snake_case,
            unused_imports,
            unused_unsafe,
            unused_variables,
            clippy::all,
            missing_docs
        )]
        use wayland_server;
        use wayland_server::protocol::*;
        pub mod __interfaces {
            use wayland_server::backend as wayland_backend;
            use wayland_server::protocol::__interfaces::*;
            wayland_scanner::generate_interfaces!("protocol/denial-orientation-v1.xml");
        }
        use self::__interfaces::*;
        wayland_scanner::generate_server_code!("protocol/denial-orientation-v1.xml");
    }
}

use protocol::server::denial_orientation_manager_v1::{
    self, DenialOrientationManagerV1, Orientation,
};

/// What a window asks of the display while it is in front.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq)]
pub(crate) enum RequestedOrientation {
    #[default]
    Unspecified,
    Portrait,
    Landscape,
    SensorLandscape,
    Sensor,
    Locked,
}

impl From<Orientation> for RequestedOrientation {
    fn from(orientation: Orientation) -> Self {
        match orientation {
            Orientation::Portrait => Self::Portrait,
            Orientation::Landscape => Self::Landscape,
            Orientation::SensorLandscape => Self::SensorLandscape,
            Orientation::Sensor => Self::Sensor,
            Orientation::Locked => Self::Locked,
            _ => Self::Unspecified,
        }
    }
}

struct SurfaceOrientation(Mutex<RequestedOrientation>);

pub(super) fn requested(surface: &WlSurface) -> RequestedOrientation {
    with_states(surface, |states| {
        states
            .data_map
            .get::<SurfaceOrientation>()
            .and_then(|orientation| orientation.0.lock().ok().map(|value| *value))
            .unwrap_or_default()
    })
}

fn set(surface: &WlSurface, orientation: RequestedOrientation) {
    with_states(surface, |states| {
        states.data_map.insert_if_missing_threadsafe(|| {
            SurfaceOrientation(Mutex::new(RequestedOrientation::Unspecified))
        });
        if let Some(stored) = states.data_map.get::<SurfaceOrientation>()
            && let Ok(mut value) = stored.0.lock()
        {
            *value = orientation;
        }
    });
}

pub(super) fn init(display: &DisplayHandle) {
    display.create_global::<RuntimeState, DenialOrientationManagerV1, _>(1, ());
}

impl GlobalDispatch<DenialOrientationManagerV1, ()> for RuntimeState {
    fn bind(
        _state: &mut Self,
        _handle: &DisplayHandle,
        _client: &Client,
        resource: New<DenialOrientationManagerV1>,
        _data: &(),
        data_init: &mut DataInit<'_, Self>,
    ) {
        data_init.init(resource, ());
    }
}

impl Dispatch<DenialOrientationManagerV1, ()> for RuntimeState {
    fn request(
        _state: &mut Self,
        _client: &Client,
        resource: &DenialOrientationManagerV1,
        request: denial_orientation_manager_v1::Request,
        _data: &(),
        _handle: &DisplayHandle,
        _data_init: &mut DataInit<'_, Self>,
    ) {
        match request {
            denial_orientation_manager_v1::Request::SetOrientation {
                surface,
                orientation,
            } => {
                let WEnum::Value(orientation) = orientation else {
                    resource.post_error(
                        denial_orientation_manager_v1::Error::InvalidOrientation,
                        "unknown orientation",
                    );
                    return;
                };
                let orientation = RequestedOrientation::from(orientation);
                if requested(&surface) != orientation {
                    tracing::debug!(surface = ?surface.id(), ?orientation, "window orientation request");
                    set(&surface, orientation);
                }
            }
            denial_orientation_manager_v1::Request::Destroy => {}
            _ => {}
        }
    }
}
