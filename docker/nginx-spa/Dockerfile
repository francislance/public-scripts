# -----------------------------------------------------------------------------
# STAGE: nginx-base
# -----------------------------------------------------------------------------
FROM image AS nginx-base
LABEL maintainer="@lance"

# -----------------------------------------------------------------------------
# ORIGINAL (commented)
# - Kept here for traceability vs. changes requested
# -----------------------------------------------------------------------------
# RUN set -x && \
#     microdnf update -y && \
#     microdnf upgrade -y && \
#     microdnf --refresh --best --noplugins --setopt=install_weak_deps=0 --nodocs install shadow-utils diffutils findutils gettext nginx -y && \
#     mv /usr/bin/envsubst /tmp/ && \
#     microdnf remove gettext -y && \
#     mv /tmp/envsubst /usr/local/bin/ && \
#     microdnf clean all -y && \
#     mkdir -p /docker-entrypoint.d /tmp/nginx/conf.d && \
#     chmod u=rwx,g=rwx,o=rwx /tmp/nginx/conf.d && \
#     ln -sf /dev/stdout /var/log/nginx/access.log && \
#     ln -sf /dev/stderr /var/log/nginx/error.log
#
# ENTRYPOINT ["/entrypoint.sh"]
#   ^^^ REMOVED because it runs nginx itself and then receives CMD args that ALSO start with "nginx"
#       -> causes "nginx ... nginx ..." -> nginx: invalid option: "nginx"
#
# CMD ["nginx", "-g", "daemon off;"]
#   ^^^ REMOVED because final stage already defines CMD; this one is ignored anyway.

# -----------------------------------------------------------------------------
# UPDATED (active)
# - Keep nginx
# - Keep envsubst capability (your original installed gettext then moved envsubst)
# - Remove redundant "upgrade" (optional) and avoid /tmp nginx config paths
# - Create writable paths for non-root (USER daemon)
# -----------------------------------------------------------------------------
RUN microdnf -y update \
 && microdnf --refresh --best --noplugins --setopt=install_weak_deps=0 --nodocs install nginx gettext -y \
 && mv /usr/bin/envsubst /usr/local/bin/envsubst \
 && microdnf remove -y gettext \
 && microdnf clean all -y \
 && mkdir -p \
      /var/cache/nginx/client_temp \
      /var/cache/nginx/proxy_temp \
      /var/cache/nginx/fastcgi_temp \
      /var/cache/nginx/uwsgi_temp \
      /var/cache/nginx/scgi_temp \
      /var/log/nginx \
      /run/nginx \
      /usr/share/nginx/html \
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && chown -R daemon:0 /var/cache/nginx /var/log/nginx /run/nginx /usr/share/nginx /etc/nginx \
 && chmod -R g=u /var/cache/nginx /var/log/nginx /run/nginx /usr/share/nginx /etc/nginx

STOPSIGNAL SIGQUIT


# -----------------------------------------------------------------------------
# STAGE: final
# -----------------------------------------------------------------------------
FROM nginx-base

# -----------------------------------------------------------------------------
# ORIGINAL (commented)
# -----------------------------------------------------------------------------
# USER root
# ENV WEB_INSTANCE_HOME /docker-files
# ENV PIL_DOC_ROOT /tmp/nginx
# WORKDIR $PIL_DOC_ROOT
# RUN pwd && ls -lrt
#
# COPY --chmod=755 dist /opt/static-html
#   ^^^ CHANGED: nginx.conf in your screenshot uses root /usr/share/nginx/html,
#       so dist should be copied there (standard nginx webroot).
#
# COPY --chmod=755 ./docker-files /docker-files
#   ^^^ REMOVED: only needed because of external entrypoint.sh (you prefer no external entrypoint)
#
# COPY --chmod=755 docker-files/nginx/nginx.conf /tmp/nginx/nginx.conf
#   ^^^ CHANGED: don't store nginx config under /tmp; use /etc/nginx/nginx.conf
#
# RUN chmod +x /docker-files/entrypoint.sh && \
#     cp /docker-files/entrypoint.sh /entrypoint.sh
#   ^^^ REMOVED: eliminates double-nginx issue and removes external entrypoint
#
# RUN pwd && ls -lrt
# USER daemon
# EXPOSE 8080
# CMD ["nginx", "-c", "/tmp/nginx/nginx.conf", "-g", "daemon off;"]
#   ^^^ CHANGED: config is now at /etc/nginx/nginx.conf, so no -c needed.

# -----------------------------------------------------------------------------
# UPDATED (active)
# -----------------------------------------------------------------------------
USER root

# Copy SPA assets into standard nginx docroot
COPY --chown=daemon:0 dist/ /usr/share/nginx/html/

# Put nginx config in the standard location (NOT /tmp)
COPY --chown=daemon:0 docker-files/nginx/nginx.conf /etc/nginx/nginx.conf

USER daemon
EXPOSE 8080

# Single, simple startup (no ENTRYPOINT)
CMD ["nginx", "-g", "daemon off;"]
