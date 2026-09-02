# syntax=docker/dockerfile:1.7
# ---------------------------------------------------------------------------
# Nextcloud runtime image (PHP-FPM).
#
# A very thin derivation of the official image. It exists for four reasons:
#
#   1. A real healthcheck. The upstream image declares none, so an unhealthy
#      PHP-FPM is indistinguishable from a healthy one to
#      `depends_on: service_healthy`.
#   2. A managed configuration fragment, rendered by a before-starting hook
#      so it lands AFTER the installer has created the config directory with
#      the right ownership.
#   3. PHP-FPM pool sizing from the environment, so worker count is an
#      operational decision rather than an image rebuild.
#   4. An ImageMagick security policy.
#
# WHAT THIS IMAGE DELIBERATELY DOES NOT DO
#
# It installs no PHP extensions. An earlier draft `pecl install`ed APCu and
# imagick, which meant pulling in a full compiler toolchain at build time.
# Checking the image first showed both are already present -- along with
# redis, memcached, gd, intl, ldap, gmp, bcmath and the rest. That layer added
# build time, a build-dependency surface, and a version skew risk against
# upstream, in exchange for nothing.
#
#   docker run --rm --entrypoint php nextcloud:34.0.3-fpm-alpine -m
#
# is worth running before adding any extension here.
#
# No multi-stage build: the artefact is interpreted PHP installed by the
# upstream maintainer, so there is no compile output to copy forward.
# ---------------------------------------------------------------------------

ARG NEXTCLOUD_VERSION=34.0.3-fpm-alpine
FROM nextcloud:${NEXTCLOUD_VERSION}

# Restated after FROM: an ARG declared before the first FROM is out of scope
# in the build stage, a rule that quietly produces empty labels.
ARG NEXTCLOUD_VERSION
ARG BUILD_DATE
ARG VCS_REF

LABEL org.opencontainers.image.title="nextcloud-private-cloud" \
      org.opencontainers.image.description="Nextcloud PHP-FPM runtime: healthcheck, managed configuration, tuned FPM pool" \
      org.opencontainers.image.source="https://github.com/rthway/nextcloud-private-cloud" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.base.name="docker.io/library/nextcloud:${NEXTCLOUD_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}"

USER root

# PHP reads conf.d in alphabetical order and the last definition of a key
# wins. The upstream image ships `nextcloud.ini` and `opcache-recommended.ini`,
# so anything intended to override them must sort after both -- hence `zz-`.
# Named `10-` (as in an earlier draft) these files load first and are silently
# overridden, which looks like configuration that has no effect.
COPY --chmod=0644 config/php/zz-opcache.ini   /usr/local/etc/php/conf.d/zz-opcache.ini
COPY --chmod=0644 config/php/zz-nextcloud.ini /usr/local/etc/php/conf.d/zz-nextcloud.ini

# ImageMagick is present in the base image and used for previews. Its coder
# set is far wider than thumbnailing needs and has a long CVE history; this
# policy removes what is not required.
COPY --chmod=0644 config/php/imagemagick-policy.xml /etc/ImageMagick-7/policy.xml

# Rendered into Nextcloud's config directory by the before-starting hook.
#
# The mkdir is NOT redundant. `COPY --chmod=0644 <file> /some/new/dir/` applies
# that mode to the directory BuildKit creates as well as to the file -- and a
# directory with mode 0644 has no execute bit, so nothing can traverse into
# it. The file is listed by `docker run ... ls -la` on the parent, and every
# attempt to read it fails. The hook reported "no template ... nothing to do"
# and started a Nextcloud with none of this configuration applied.
#
# Creating the directory explicitly with 0755 first means the --chmod applies
# only to the file, which is what it looks like it does.
RUN mkdir -p /usr/local/share/nextcloud
COPY --chmod=0644 config/nextcloud/zz-managed.config.php.tmpl /usr/local/share/nextcloud/

# The image's documented extension point: scripts here run after install or
# upgrade and before PHP-FPM starts, with /var/www/html already populated and
# correctly owned.
COPY --chmod=0755 docker/nextcloud/hooks/before-starting/ /docker-entrypoint-hooks.d/before-starting/

COPY --chmod=0755 docker/nextcloud/entrypoint.sh  /usr/local/bin/custom-entrypoint.sh
COPY --chmod=0755 docker/nextcloud/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN set -eux; \
    mkdir -p /var/www/html/data; \
    chown -R www-data:www-data /var/www/html

# USER is deliberately left as root, unlike the Odoo project in this
# portfolio. PHP-FPM's master process needs root to create the pool listener
# and to populate the html volume on first start; it drops to www-data for
# every worker, which is where request handling actually happens.
# compose.prod.yml drops all capabilities except those the master uses.

EXPOSE 9000

VOLUME ["/var/www/html"]

# start-period is generous because first start runs the Nextcloud installer,
# which creates the schema. Failures during start-period do not count towards
# retries, so a large value costs nothing when startup is fast.
HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=3 \
    CMD ["/usr/local/bin/healthcheck.sh"]

# The custom entrypoint resolves secrets and sizes the FPM pool, then chains
# to the upstream entrypoint which owns installation, upgrades and the hooks.
# Replacing that logic rather than wrapping it would mean reimplementing
# Nextcloud's upgrade path.
ENTRYPOINT ["/usr/local/bin/custom-entrypoint.sh"]
CMD ["php-fpm"]
