# ADR-007: Security headers at the proxy; no CSP of our own

**Status:** Accepted · 2026-09-02

## Context

Nextcloud holds an organisation's files. A compromised session means access to
every document a user can see, and share links are unauthenticated by design.

## Decision

TLS 1.2 and 1.3 only, forward secrecy only, and seven response headers set at
nginx with `always` — so they survive 4xx and 5xx responses, which is
precisely when an error page might reflect attacker-controlled content.

| Header | Value |
|---|---|
| `Strict-Transport-Security` | `max-age=63072000; includeSubDomains`, **not** preloaded |
| `X-Frame-Options` | `SAMEORIGIN` |
| `X-Content-Type-Options` | `nosniff` |
| `Referrer-Policy` | `no-referrer` |
| `X-Robots-Tag` | `noindex, nofollow` |
| `X-Permitted-Cross-Domain-Policies` | `none` |
| `Permissions-Policy` | camera, microphone, geolocation, payment, USB off |

## Why no Content-Security-Policy here

**This is the opposite situation to the Odoo project in this portfolio.**

There, no useful CSP is possible at all: Odoo's QWeb layer evaluates generated
JavaScript, so a policy strict enough to matter breaks the client and one
loose enough to work provides no protection.

Here, **Nextcloud already ships a good CSP** — generated per request by its
`ContentSecurityPolicyManager`, and extended at runtime by apps that need it.

Adding a static policy at nginx would either be weaker than Nextcloud's,
achieving nothing while looking thorough, or conflict with it and break the
web UI. The correct action is to not interfere.

The general lesson: "add a CSP" is not a checklist item. Whether to add one,
and where, depends on what the application already does.

## Header de-duplication

Nextcloud sets several of these itself. nginx's `add_header` **appends** rather
than replaces, so without intervention the response carries each header twice.

Duplicated security headers are not merely untidy: where two values disagree,
browsers do not resolve them consistently and the weaker value can win.
`fastcgi_hide_header` drops the upstream copies first, and the smoke suite
asserts each header appears exactly once. The first implementation shipped
duplicates; testing found it.

## `X-Robots-Tag: noindex`

Specific to this application. Share links are unauthenticated by design —
that is the feature. Indexing them makes them findable, which turns "anyone
with the link" into "anyone with a search engine".

## Why HSTS is not preloaded

Preload submission is effectively irreversible for the apex domain and
everything under it. That is a decision for whoever owns the domain, not for a
deployment template.

**A related trap:** browsers that have seen the HSTS header will not let users
click through a certificate warning, and sync clients never would. So the
"swap in a self-signed certificate as a stopgap" recovery does not work here.
The certificate runbook says so.

## Paths that must never be served

Not headers, but the same category of control and more consequential:

```nginx
location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
```

`config/` contains the database password; `data/` contains every user's files.
A vhost missing this is a known way to lose a Nextcloud instance entirely.

Equally, PHP execution is restricted to Nextcloud's entry points. An open
`location ~ \.php$` would let any uploaded `.php` file in the data directory
execute — which, on a server that accepts arbitrary uploads, is remote code
execution by design. The configuration suite asserts both.

## Consequences

- A scanner will report "no Content-Security-Policy header from the proxy".
  That finding is correct as far as it goes, and this ADR is the answer.
- HSTS with a two-year max-age makes a misissued certificate a hard outage for
  returning visitors and all sync clients. That is the point of HSTS.
- Header presence and uniqueness are asserted in CI, so a regression fails the
  build rather than being noticed by a scanner months later.
