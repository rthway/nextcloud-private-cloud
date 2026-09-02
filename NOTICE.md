# Third-party components

This repository contains infrastructure code only. It builds no application
source of its own; it orchestrates upstream software downloaded at build or
run time.

| Component | Version pinned here | Upstream licence | Role |
|---|---|---|---|
| Nextcloud Server | `34.0.3-fpm-alpine` | AGPL-3.0-or-later | Application (PHP-FPM) |
| MariaDB | `11.8.9-noble` | GPL-2.0-only (server) | Primary datastore |
| Redis | `8.8.2-alpine3.23` | RSALv2 / SSPLv1 (see below) | Distributed cache and file locking |
| nginx | `1.31.4-alpine3.24` | BSD-2-Clause | TLS termination, static serving, reverse proxy |
| Prometheus | `v3.14.0` | Apache-2.0 | Metrics collection |
| Grafana OSS | `13.2.1` | AGPL-3.0-only | Dashboards |
| Loki | `3.6.11` | AGPL-3.0-only | Log aggregation |
| Promtail | `3.6.11` | AGPL-3.0-only | Log shipping |
| mysqld_exporter | `v0.19.0` | Apache-2.0 | MariaDB metrics |
| redis_exporter | `v1.83.0` | MIT | Redis metrics |
| nginx-prometheus-exporter | `1.5.3` | Apache-2.0 | nginx metrics |
| blackbox_exporter | `v0.28.0` | Apache-2.0 | External health probing |
| cAdvisor | `v0.55.1` | Apache-2.0 | Container resource metrics |
| node_exporter | `v1.12.1` | Apache-2.0 | Host metrics |

## Notes on obligations

**Nextcloud (AGPL-3.0).** Run here as an unmodified upstream container. The
AGPL's network clause obliges anyone who *modifies* Nextcloud and offers it
over a network to publish their modified source. This repository modifies
nothing in Nextcloud; it supplies configuration, which is not a derivative
work of the server. If you fork Nextcloud itself, the AGPL applies to your
fork and not to this infrastructure code.

**Redis licensing.** Redis moved from BSD-3-Clause to a dual RSALv2 / SSPLv1
model at 7.4, and added AGPLv3 as a third option from 8.0. None of these are
OSI-approved "open source" in the way the old BSD licence was, and the SSPL in
particular has obligations for anyone offering Redis *as a service*.

This deployment uses Redis as an internal component of a self-hosted
application, which is squarely within what the licence permits. If you are
building a hosted offering, take your own advice — and note that **Valkey**
(BSD-3-Clause, a fork of Redis 7.2) is a drop-in replacement. See
`docs/adr/004-redis-and-caching.md`.

**Grafana and Loki (AGPL-3.0).** Unmodified upstream containers. Running an
unmodified AGPL service imposes no source obligation on the surrounding
infrastructure code, which remains MIT.

**Nextcloud apps** installed from the app store carry their own licences, most
commonly AGPL-3.0. None are bundled here.
