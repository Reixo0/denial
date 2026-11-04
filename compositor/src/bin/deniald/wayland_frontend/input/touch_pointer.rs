//! Touch as a mouse for clients that never asked for touch.
//!
//! A client without a `wl_touch` object, such as a terminal, cannot see a
//! finger at all. Its contacts drive the pointer instead, the way a phone
//! handles text: a tap clicks, a drag scrolls, a hold then a drag holds the
//! left button down (selecting text), and a hold alone right-clicks. One
//! finger at a time; others on such a client are swallowed.

use smithay::utils::{Logical, Point};

/// Movement below this is a finger resting, not a drag.
const SLOP: f64 = 10.0;

/// A contact resting this long holds the button rather than scrolling.
const HOLD_MICROS: u64 = 450_000;

/// What the pointer does for a contact's event.
#[derive(Debug, Clone, Copy, PartialEq)]
pub(in super::super) enum TouchPointerAction {
    /// The pointer moves to a point.
    Move(Point<f64, Logical>),
    /// The left button goes down where the contact began, then the pointer
    /// follows to a point.
    PressFrom(Point<f64, Logical>, Point<f64, Logical>),
    Release,
    Click,
    RightClick,
    /// Wheel motion with the finger, by this many logical pixels.
    Scroll(Point<f64, Logical>),
    ScrollStop,
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Phase {
    /// Down, not yet moved past [SLOP].
    Resting,
    Scrolling,
    Dragging,
}

#[derive(Debug)]
struct Contact {
    slot: i32,
    start: Point<f64, Logical>,
    last: Point<f64, Logical>,
    down_micros: u64,
    phase: Phase,
}

#[derive(Debug, Default)]
pub(in super::super) struct TouchPointer {
    contact: Option<Contact>,
    /// Further fingers on a touchless client, swallowed until they lift.
    extra: Vec<i32>,
}

impl TouchPointer {
    /// Whether [slot] is a contact this drives or swallows.
    pub(in super::super) fn owns(&self, slot: i32) -> bool {
        self.contact
            .as_ref()
            .is_some_and(|contact| contact.slot == slot)
            || self.extra.contains(&slot)
    }

    /// A finger went down on a touchless client. The pointer moves under the
    /// first one; others are swallowed.
    pub(in super::super) fn down(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
        micros: u64,
    ) -> Vec<TouchPointerAction> {
        if self.contact.is_some() {
            self.extra.push(slot);
            return Vec::new();
        }
        self.contact = Some(Contact {
            slot,
            start: position,
            last: position,
            down_micros: micros,
            phase: Phase::Resting,
        });
        vec![TouchPointerAction::Move(position)]
    }

    pub(in super::super) fn motion(
        &mut self,
        slot: i32,
        position: Point<f64, Logical>,
        micros: u64,
    ) -> Vec<TouchPointerAction> {
        let Some(contact) = self.contact.as_mut().filter(|contact| contact.slot == slot) else {
            return Vec::new();
        };
        match contact.phase {
            Phase::Resting => {
                let moved = position - contact.start;
                if moved.x.hypot(moved.y) <= SLOP {
                    return Vec::new();
                }
                if micros.saturating_sub(contact.down_micros) >= HOLD_MICROS {
                    contact.phase = Phase::Dragging;
                    contact.last = position;
                    vec![TouchPointerAction::PressFrom(contact.start, position)]
                } else {
                    contact.phase = Phase::Scrolling;
                    // The slop travelled scrolls too, so content stays under
                    // the finger.
                    contact.last = position;
                    vec![TouchPointerAction::Scroll(moved)]
                }
            }
            Phase::Scrolling => {
                let delta = position - contact.last;
                contact.last = position;
                vec![TouchPointerAction::Scroll(delta)]
            }
            Phase::Dragging => {
                contact.last = position;
                vec![TouchPointerAction::Move(position)]
            }
        }
    }

    pub(in super::super) fn up(&mut self, slot: i32, micros: u64) -> Vec<TouchPointerAction> {
        if let Some(index) = self.extra.iter().position(|extra| *extra == slot) {
            self.extra.swap_remove(index);
            return Vec::new();
        }
        let Some(contact) = self.contact.take_if(|contact| contact.slot == slot) else {
            return Vec::new();
        };
        vec![match contact.phase {
            Phase::Resting if micros.saturating_sub(contact.down_micros) >= HOLD_MICROS => {
                TouchPointerAction::RightClick
            }
            Phase::Resting => TouchPointerAction::Click,
            Phase::Scrolling => TouchPointerAction::ScrollStop,
            Phase::Dragging => TouchPointerAction::Release,
        }]
    }

    /// The contact was taken away: a held button lets go, a scroll ends,
    /// and nothing clicks.
    pub(in super::super) fn cancel(&mut self, slot: i32) -> Vec<TouchPointerAction> {
        if let Some(index) = self.extra.iter().position(|extra| *extra == slot) {
            self.extra.swap_remove(index);
            return Vec::new();
        }
        match self.contact.take_if(|contact| contact.slot == slot) {
            Some(Contact {
                phase: Phase::Dragging,
                ..
            }) => vec![TouchPointerAction::Release],
            Some(Contact {
                phase: Phase::Scrolling,
                ..
            }) => vec![TouchPointerAction::ScrollStop],
            _ => Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::TouchPointerAction::*;
    use super::*;

    fn at(x: f64, y: f64) -> Point<f64, Logical> {
        Point::from((x, y))
    }

    #[test]
    fn tap_clicks_where_it_lands() {
        let mut touch = TouchPointer::default();
        assert_eq!(touch.down(0, at(5.0, 5.0), 0), vec![Move(at(5.0, 5.0))]);
        assert!(touch.motion(0, at(8.0, 6.0), 50_000).is_empty());
        assert_eq!(touch.up(0, 120_000), vec![Click]);
        assert!(!touch.owns(0));
    }

    #[test]
    fn hold_alone_right_clicks() {
        let mut touch = TouchPointer::default();
        touch.down(0, at(5.0, 5.0), 0);
        assert_eq!(touch.up(0, 600_000), vec![RightClick]);
    }

    #[test]
    fn quick_drag_scrolls_with_the_finger() {
        let mut touch = TouchPointer::default();
        touch.down(0, at(0.0, 100.0), 0);
        assert_eq!(
            touch.motion(0, at(0.0, 120.0), 80_000),
            vec![Scroll(at(0.0, 20.0))]
        );
        assert_eq!(
            touch.motion(0, at(0.0, 130.0), 90_000),
            vec![Scroll(at(0.0, 10.0))]
        );
        assert_eq!(touch.up(0, 100_000), vec![ScrollStop]);
    }

    #[test]
    fn hold_then_drag_holds_the_button_from_the_start() {
        let mut touch = TouchPointer::default();
        touch.down(0, at(10.0, 10.0), 0);
        assert_eq!(
            touch.motion(0, at(40.0, 10.0), 500_000),
            vec![PressFrom(at(10.0, 10.0), at(40.0, 10.0))]
        );
        assert_eq!(
            touch.motion(0, at(60.0, 12.0), 520_000),
            vec![Move(at(60.0, 12.0))]
        );
        assert_eq!(touch.up(0, 600_000), vec![Release]);
    }

    #[test]
    fn other_fingers_are_swallowed_and_cancel_releases() {
        let mut touch = TouchPointer::default();
        touch.down(0, at(0.0, 0.0), 0);
        assert!(touch.down(1, at(50.0, 50.0), 10).is_empty());
        assert!(touch.owns(1));
        assert!(touch.motion(1, at(90.0, 90.0), 20).is_empty());
        assert!(touch.up(1, 30).is_empty());
        touch.motion(0, at(0.0, 40.0), 500_000);
        assert_eq!(touch.cancel(0), vec![Release]);
        assert!(!touch.owns(0));
    }
}
