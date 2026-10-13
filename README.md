# ChantiPoint

ChantiPoint is a French-language Flutter application for digital employee attendance and external-worksite presence verification. The initial product records check-ins/check-outs at the company's factory/premises and at external worksites, and may later help a designated manager review whether an employee's phone remained near a declared external worksite during an active work session.

Factory attendance does not use GPS. External-worksite location evidence must be treated as limited evidence from a device, not as certain proof of physical employee presence or work performed.

## Engineering Documentation

The project is currently in draft Requirements Specification v0.1. Feature implementation should not begin until the documentation is reviewed and the first approved implementation milestone is selected.

- [Requirements](docs/requirements.md)
- [Architecture](docs/architecture.md)
- [Logical Data Model](docs/data-model.md)
- [Backlog](docs/backlog.md)
- [Location Feasibility Study](docs/location-feasibility.md)
- [Security and Privacy](docs/security-privacy.md)
- [Client Questions in French](docs/client-questions-fr.md)
- [ADR 0001: Technology Stack](docs/decisions/0001-technology-stack.md)
- [ADR 0002: Location Monitoring](docs/decisions/0002-location-monitoring.md)

## Getting Started

This repository currently contains the initial Flutter starter application.

Useful local commands:

```sh
flutter pub get
flutter analyze
flutter test
flutter run
```

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
