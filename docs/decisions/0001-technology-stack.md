# ADR 0001: Flutter and Supabase Technology Stack

Date: 2026-10-12

Status: Accepted for v0.1 planning; not a signed client approval

## Context

ChantiPoint needs a French-language, Android-first employee mobile app, a practical administrator interface, secure authentication, server-controlled authorization, and a maintainable backend for a solo developer working approximately 5-7 hours per week.

The existing repository is a Flutter starter project with Android, iOS, web, and test scaffolding.

## Decision

Use the following starting architecture:

- Flutter and Dart for the employee mobile app.
- Android-first implementation.
- iOS retained as a target platform, but not the first deployment priority.
- Flutter Web as the initial preferred candidate for the administrator interface.
- Supabase Auth for authentication.
- Supabase PostgreSQL with Row Level Security for data storage and authorization.
- Secure server-side operations, such as Supabase Edge Functions or Postgres RPC, where client-side enforcement is insufficient.
- Private GitHub repository for source control.

## Consequences

- One codebase and language can cover mobile and web UI work.
- Supabase can reduce backend setup time while still supporting PostgreSQL, RLS, and auditable data design.
- RLS and server-side commands must be designed carefully before storing real employee data.
- Flutter clients must never receive service-role credentials.
- iOS delivery still needs separate planning, Apple Developer access, build infrastructure, and real-device testing.
- Supabase setup, migrations, and production resources are deferred until approved implementation work begins.

## Related Requirements

- REQ-AUTH-001
- REQ-DATA-001 through REQ-DATA-006
- REQ-SEC-001
- REQ-PRIV-001
