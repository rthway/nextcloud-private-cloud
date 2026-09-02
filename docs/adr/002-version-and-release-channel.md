# ADR-002: Newest stable Nextcloud, pinned to a patch version

**Status:** Accepted · 2026-09-02

## Context

Nextcloud releases roughly three major versions a year and maintains several
in parallel. As of September 2026, 34 is current and 33 and 32 are still
supported.

Docker Hub publishes `latest`, `stable`, `production`, floating majors like
`34`, and immutable patch tags like `34.0.3-fpm-alpine`.

## Decision

`34.0.3-fpm-alpine` — the newest stable line, pinned to a patch version, with
Dependabot watching for updates.

## Why this differs from the Odoo project in this portfolio

That project deliberately runs one major version behind, because the OCA addon
ecosystem lags and a deployment's addons are the reason to self-host at all.

**Applying the same rule here would be cargo-culting.** Nextcloud's situation
is materially different:

- `occ upgrade` is a supported, well-exercised path, and apps are
  compatibility-checked at upgrade time and **disabled rather than loaded** if
  incompatible. That is a safe failure mode; Odoo's module migrations are not.
- Security support is best on the newest line.
- Nextcloud does not support skipping major versions, so trailing means the
  eventual catch-up is several sequential upgrades rather than one.

The general lesson is that "always trail by one" is not a principle — it is a
conclusion that depends on the upgrade mechanics and the ecosystem, and those
differ per application.

## Alternatives considered

**`stable` or `production`.** The `production` channel is more conservative
and would be reasonable. Rejected because both are floating tags republished
in place: two builds a week apart produce different images, so "the same
version" becomes a statement about intent rather than about bytes.

**A floating `34` tag.** Picks up security rebuilds automatically. Rejected
for the same reproducibility reason — and because a patch upgrade still runs
database migrations, which should be a deliberate act.

**Trailing to 33.** Rejected per the reasoning above.

## Consequences

**Accepted:**

- Security updates are not automatic. This is the real cost, mitigated by
  Dependabot, the weekly scheduled rebuild in `release.yml`, and the
  `apk upgrade` layer that patches inherited OS packages at build time. **A
  pin without an update mechanism is just an old image with extra steps** —
  the mechanism is the load-bearing part.
- Major upgrades must be sequential.

**Gained:**

- A build today and a build in six months produce the same image.
- Rollback means running a known digest.
- `NOTICE.md` states exactly what is deployed, and a test asserts they agree.

## Evidence

Trivy against the built image on 2026-09-02: 0 fixable HIGH/CRITICAL — after
the `apk upgrade` layer fixed two real CVEs in libexpat that the upstream image
had not yet picked up. That is a point-in-time measurement of this pin, and
precisely why the scheduled rebuild exists.
