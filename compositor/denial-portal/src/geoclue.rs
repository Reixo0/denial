//! GeoClue2 agent: Denial's "allow or deny" dialog for sandboxed apps that ask
//! geoclue for their location directly instead of through the Location portal.
//!
//! geoclue only asks the agent (`AuthorizeApp`) about sandboxed (Flatpak)
//! apps it has no rule for. An unsandboxed app could claim any desktop id, so
//! geoclue lets it through without asking. While geoclue knows of agents but
//! none is registered, it holds every client back, so the agent is also what
//! lets unsandboxed apps get a location at all.
//!
//! Answers are kept in the portal permission store, table and resource
//! `location`, as xdg-desktop-portal's Location portal keeps its own:
//! `[accuracy, last asked]` per app, so both paths share one record. The
//! agent's id, `denial-portal`, has to be in geoclue's `[agent] whitelist`.
//!
//! geoclue quits when idle and forgets its agents, so the agent registers
//! again each time the service comes back on the system bus.
//!
//! Location as a whole follows the privacy switch, `"location": false` in
//! `$XDG_CONFIG_HOME/denial/privacy.json`: the agent then allows no accuracy
//! (`MaxAccuracyLevel` 0), and geoclue stops and refuses every client.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::json;
use tracing::{info, warn};
use zbus::blocking::Connection;
use zbus::zvariant::OwnedValue;

use crate::access::{self, DialogBundle, Outcome};

const AGENT_ID: &str = "denial-portal";
const AGENT_PATH: &str = "/org/freedesktop/GeoClue2/Agent";
const GEOCLUE_SERVICE: &str = "org.freedesktop.GeoClue2";
const GEOCLUE_MANAGER_PATH: &str = "/org/freedesktop/GeoClue2/Manager";
const GEOCLUE_MANAGER: &str = "org.freedesktop.GeoClue2.Manager";

const STORE_SERVICE: &str = "org.freedesktop.impl.portal.PermissionStore";
const STORE_PATH: &str = "/org/freedesktop/impl/portal/PermissionStore";
const STORE_TABLE: &str = "location";
const STORE_ID: &str = "location";

/// `GClueAccuracyLevel`
const ACCURACY_NONE: u32 = 0;
const ACCURACY_EXACT: u32 = 8;

/// How often the privacy switch is looked at.
const SWITCH_POLL: Duration = Duration::from_secs(1);

const ACCURACY_NAMES: [(u32, &str); 6] = [
    (0, "NONE"),
    (1, "COUNTRY"),
    (4, "CITY"),
    (5, "NEIGHBORHOOD"),
    (6, "STREET"),
    (8, "EXACT"),
];

struct Agent {
    bundle: DialogBundle,
    session: Connection,
}

#[zbus::interface(name = "org.freedesktop.GeoClue2.Agent", introspection_docs = false)]
impl Agent {
    #[zbus(
        name = "AuthorizeApp",
        out_args("authorized", "allowed_accuracy_level")
    )]
    async fn authorize_app(&self, desktop_id: String, req_accuracy_level: u32) -> (bool, u32) {
        if !location_switched_on() {
            return (false, ACCURACY_NONE);
        }
        let requested = req_accuracy_level.min(ACCURACY_EXACT);
        if let Some(stored) = stored_accuracy(&self.session, &desktop_id) {
            let allowed = stored.min(requested);
            return (allowed > ACCURACY_NONE, allowed);
        }

        let name = app_name(&desktop_id);
        let request = json!({
            "type": "request",
            "schema": access::SCHEMA,
            "appId": desktop_id,
            "title": format!("Allow {name} to use your location?"),
            "subtitle": format!("{name} wants to know where this phone is."),
            "body": "You can change this later in Settings.",
            "grantLabel": "Allow",
            "denyLabel": "Don't allow",
            "choices": [],
        });
        let (answered, answer) = async_channel::bounded(1);
        let bundle = self.bundle.clone();
        // geoclue never withdraws a question: nothing sends on `close`.
        let (_close, close_requested) = async_channel::bounded(1);
        let worker = std::thread::Builder::new()
            .name("location-dialog".to_owned())
            .spawn(move || {
                let outcome =
                    access::ask(&bundle, &request, &close_requested).unwrap_or_else(|error| {
                        warn!(%error, "location dialog failed");
                        Outcome::Ended
                    });
                let _ = answered.send_blocking(outcome);
            });
        let outcome = match worker {
            Ok(_) => answer.recv().await.unwrap_or(Outcome::Ended),
            Err(error) => {
                warn!(%error, "could not start the location dialog");
                Outcome::Ended
            }
        };

        // A dialog closed without an answer asks again next time.
        let Outcome::Answered { granted, .. } = outcome else {
            return (false, ACCURACY_NONE);
        };
        info!(app = %desktop_id, granted, "location access answered");
        let allowed = if granted { requested } else { ACCURACY_NONE };
        store_accuracy(
            &self.session,
            &desktop_id,
            if granted {
                ACCURACY_EXACT
            } else {
                ACCURACY_NONE
            },
        );
        (granted, allowed)
    }

    #[zbus(property, name = "MaxAccuracyLevel")]
    fn max_accuracy_level(&self) -> u32 {
        if location_switched_on() {
            ACCURACY_EXACT
        } else {
            ACCURACY_NONE
        }
    }
}

/// Serves the agent on the system bus and keeps it registered with geoclue.
/// Runs for the life of the process; returns only if it cannot start.
pub(crate) fn run(bundle: DialogBundle) -> zbus::Result<()> {
    let session = Connection::session()?;
    let system = zbus::blocking::connection::Builder::system()?
        .serve_at(AGENT_PATH, Agent { bundle, session })?
        .build()?;

    watch_switch(&system)?;

    // geoclue may not be running: AddAgent starts it. It loses its agents
    // when it quits, so register again whenever it comes back.
    register(&system);
    let dbus = zbus::blocking::fdo::DBusProxy::new(&system)?;
    let changes = dbus.receive_name_owner_changed_with_args(&[(0, GEOCLUE_SERVICE)])?;
    for change in changes {
        let Ok(args) = change.args() else { continue };
        if args.new_owner().is_some() {
            register(&system);
        }
    }
    Ok(())
}

/// Tells geoclue when the location switch flips.
fn watch_switch(system: &Connection) -> zbus::Result<()> {
    let agent = system.object_server().interface::<_, Agent>(AGENT_PATH)?;
    std::thread::Builder::new()
        .name("location-switch".to_owned())
        .spawn(move || {
            let mut on = location_switched_on();
            loop {
                std::thread::sleep(SWITCH_POLL);
                let now = location_switched_on();
                if now == on {
                    continue;
                }
                on = now;
                info!(on, "location switch changed");
                let emitter = agent.signal_emitter();
                if let Err(error) = zbus::block_on(agent.get().max_accuracy_level_changed(emitter))
                {
                    warn!(%error, "could not tell geoclue about the location switch");
                }
            }
        })
        .map_err(|error| zbus::Error::Failure(error.to_string()))?;
    Ok(())
}

/// The privacy switch. Anything but an explicit `false` is on.
fn location_switched_on() -> bool {
    let path = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .map(|dir| dir.join("denial/privacy.json"));
    let Some(text) = path.and_then(|path| std::fs::read_to_string(path).ok()) else {
        return true;
    };
    switch_is_on(&text)
}

fn switch_is_on(text: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(text)
        .ok()
        .and_then(|value| value.get("location").and_then(serde_json::Value::as_bool))
        != Some(false)
}

fn register(system: &Connection) {
    match system.call_method(
        Some(GEOCLUE_SERVICE),
        GEOCLUE_MANAGER_PATH,
        Some(GEOCLUE_MANAGER),
        "AddAgent",
        &(AGENT_ID,),
    ) {
        Ok(_) => info!("registered as geoclue's agent"),
        Err(error) => warn!(%error, "geoclue did not take the agent"),
    }
}

fn stored_accuracy(session: &Connection, app: &str) -> Option<u32> {
    let reply = session
        .call_method(
            Some(STORE_SERVICE),
            STORE_PATH,
            Some(STORE_SERVICE),
            "Lookup",
            &(STORE_TABLE, STORE_ID),
        )
        .ok()?;
    let (permissions, _data): (HashMap<String, Vec<String>>, OwnedValue) =
        reply.body().deserialize().ok()?;
    let name = permissions.get(app)?.first()?;
    ACCURACY_NAMES
        .iter()
        .find(|(_, n)| n == name)
        .map(|(level, _)| *level)
}

fn store_accuracy(session: &Connection, app: &str, level: u32) {
    let name = ACCURACY_NAMES
        .iter()
        .find(|(l, _)| *l == level)
        .map_or("NONE", |(_, n)| n);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |d| d.as_secs());
    let permissions = vec![name.to_owned(), now.to_string()];
    if let Err(error) = session.call_method(
        Some(STORE_SERVICE),
        STORE_PATH,
        Some(STORE_SERVICE),
        "SetPermission",
        &(STORE_TABLE, true, STORE_ID, app, permissions),
    ) {
        warn!(%error, app, "could not remember the location answer");
    }
}

/// The app's name from its desktop entry, or the id itself.
fn app_name(desktop_id: &str) -> String {
    let file = format!("{}.desktop", desktop_id.trim_end_matches(".desktop"));
    let mut dirs: Vec<PathBuf> = Vec::new();
    if let Some(home) = std::env::var_os("XDG_DATA_HOME") {
        dirs.push(home.into());
    } else if let Some(home) = std::env::var_os("HOME") {
        dirs.push(PathBuf::from(home).join(".local/share"));
    }
    let system =
        std::env::var("XDG_DATA_DIRS").unwrap_or_else(|_| "/usr/local/share:/usr/share".to_owned());
    dirs.extend(
        system
            .split(':')
            .filter(|d| !d.is_empty())
            .map(PathBuf::from),
    );

    for dir in dirs {
        let Ok(text) = std::fs::read_to_string(dir.join("applications").join(&file)) else {
            continue;
        };
        if let Some(name) = desktop_entry_name(&text) {
            return name;
        }
    }
    desktop_id.to_owned()
}

fn desktop_entry_name(text: &str) -> Option<String> {
    let mut in_entry = false;
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
        } else if in_entry {
            if let Some(name) = line.strip_prefix("Name=") {
                return Some(name.to_owned());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::{desktop_entry_name, switch_is_on};

    #[test]
    fn only_an_explicit_false_switches_location_off() {
        assert!(!switch_is_on(r#"{"location": false, "camera": true}"#));
        assert!(switch_is_on(r#"{"location": true}"#));
        assert!(switch_is_on(r#"{"camera": false}"#));
        assert!(switch_is_on("not json"));
    }

    #[test]
    fn name_comes_from_the_desktop_entry_group() {
        let text = "[Desktop Entry]\nType=Application\nName=Firefox\n\n[Desktop Action new]\nName=New Window\n";
        assert_eq!(desktop_entry_name(text).as_deref(), Some("Firefox"));
    }

    #[test]
    fn localized_names_and_other_groups_are_skipped() {
        let text = "[Desktop Action x]\nName=Other\n[Desktop Entry]\nName[de]=Karte\nName=Maps\n";
        assert_eq!(desktop_entry_name(text).as_deref(), Some("Maps"));
    }
}
