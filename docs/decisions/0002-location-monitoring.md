# ADR 0002: Geofencing as Preferred Location-Monitoring Candidate

Date: 2026-10-12

Status: Proposed; emulator feasibility completed, pending real-device validation and client approval

## Context

The core business concern is that an employee may check in at an external worksite, leave for an extended period, and later check out, making the session appear uninterrupted.

The product should provide location-based evidence about whether the employee's phone remained near the declared external worksite during an active work session. It must not claim certainty about physical presence or work activity. Factory/company-premises attendance does not use GPS or geofencing.

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

If a reliable exit event is received, the candidate grace period is 10 minutes from application/backend receipt of that event. If the employee returns during the grace period, the session continues and exit/return events are retained. If the departure persists beyond the grace period and sufficient reliable evidence exists, proposed behavior is automatic checkout followed by employee notification.

This rule does not guarantee checkout 10 minutes after physical departure because background events can be delayed or missed.

## Consequences

- Early development should prioritize the Android feasibility prototype before major administrator-application investment.
- Location monitoring code must record unavailable or inconclusive states.
- Reliable detection of disabled location or revoked permission may trigger an approved closure procedure, but immediate detection must not be promised.
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
