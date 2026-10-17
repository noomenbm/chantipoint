# ADR 0002: Geofencing as Preferred Location-Monitoring Candidate

Date: 2026-10-12

Status: Proposed; emulator feasibility completed, pending real-device validation and client approval

## Context

The core business concern is that an employee may check in at an external worksite, leave for an extended period, and later check out, making the session appear uninterrupted.

The product should provide location-based evidence about whether the employee's phone remained near the declared external worksite during an active work session. It must not claim certainty about physical presence or work activity. The original factory-no-GPS assumption is superseded by the approved M2.3b target for individual foreground attendance fixes. That target does not implement or approve factory geofencing/background monitoring; M2.3b.1 adds schema foundations only. The historical M1 findings and the separate geofencing approval gates remain unchanged.

Android and iOS may delay, suppress, or restrict background location and geofence events. Personal devices also vary by operating-system version, settings, battery optimization, permissions, hardware accuracy, connectivity, and whether location services remain enabled.

## Decision

Use geofencing as the preferred technical candidate for external-worksite verification, not as an approved production commitment.

The first spike used an isolated Android emulator prototype with simulated GPS movement. It tested:

- Geofence registration.
- Simulated exit and return events.
- Candidate 100m radius behavior; a 150m option existed but was not separately tested in M1.
- Callback/receipt timestamp capture and explicit handling when an original native event timestamp is unavailable.
- Delayed event handling.
- Simulated 10-minute grace period.
- Monitoring disabled or unavailable states.
- Simulated automatic checkout candidate behavior.
- Cleanup and unregistering of geofences.

Automatic checkout remains disabled in production until:

- Emulator feasibility findings are reviewed.
- Later real-device field testing is planned and completed.
- Evidence rules and thresholds are approved.
- Privacy and platform release gates are satisfied.
- The client explicitly approves the behavior and exceptions.

## Proposed Business Rule Under Test

The M1 spike tested a simulated grace-period checkout candidate; the following final-review policies are provisional planning decisions, not additional M1 results. They require client, privacy, and technical approval before production and are not implemented in M2.3b.1.

- **Geofence exit:** a proposed 10-minute grace period starts from reliable application/backend receipt of sufficiently credible EXIT evidence. Return evidence keeps the session active and preserves exit/return history. Send a checkout notification; if the employee continues, allow another hour before reevaluation and another notification. No response after 30 minutes permits automatic checkout only if approved evidence requirements are still satisfied. Preserve evidence and flag automatic closure for administrator review. Grace expiry or silence alone is insufficient.
- **Location failure:** loss of permission, services, or monitoring availability is not an EXIT event. Record the technical reason when reliably detected, unavailable/inconclusive status, and administrator review flag; notify the employee when the future feature supports it. After 30 minutes without acknowledgment, record that fact and keep the session active; remind again after approximately one hour if the problem persists. Failure or unanswered notifications alone must never cause automatic checkout.
- **Excessive duration:** a separate proposed configurable 16-hour maximum has a reminder at 8 hours, stronger warning at 12 hours, final warning at 15 hours 30 minutes, and proposed automatic closure at 16 hours with mandatory administrator review. Closure does not prove that all elapsed time was worked.

Keep the session active until authorized checkout or a separately approved closure based on sufficient independent evidence. Exact notification/grace timing, evidence thresholds, duration exceptions, delivery/acknowledgment handling, and closure timestamps need an approved contract. No notifications, timers, geofencing, or automatic checkout are introduced in M2.3b.1.

This rule does not guarantee checkout 10 minutes after physical departure because background events can be delayed or missed.

## Consequences

- Early development should prioritize the Android feasibility prototype before major administrator-application investment.
- Location monitoring code must record unavailable or inconclusive states.
- Reliable detection of disabled location, revoked permission, or monitoring failure records the technical reason and unavailable/inconclusive state for review and notification; it never, by itself, triggers checkout. Immediate detection or notification delivery must not be promised.
- A single inaccurate GPS point must not trigger automatic checkout.
- Grace periods cannot eliminate operating-system delivery delays.
- The system must stop collecting location data after checkout.
- The administrator experience should expose automatic closure source, reason, evidence summary, and review status.
- Real-device testing remains required before production validation.

## Related Requirements

- REQ-LOC-001 through REQ-LOC-008
- REQ-DATA-005
- REQ-PRIV-001
- REQ-PRIV-002
- REQ-PRIV-003

## References

- [Location Feasibility Study](../location-feasibility.md)
