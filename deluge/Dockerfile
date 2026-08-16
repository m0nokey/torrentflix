ARG DELUGE_IMAGE=lscr.io/linuxserver/deluge:2.2.0
FROM ${DELUGE_IMAGE} AS stock
FROM ${DELUGE_IMAGE}

ARG WEB_DIR=/lsiopy/lib/python3.12/site-packages/deluge/ui/web

COPY --from=stock ${WEB_DIR}/icons/ ${WEB_DIR}/icons/
COPY --from=stock ${WEB_DIR}/images/ ${WEB_DIR}/images/
COPY --from=stock ${WEB_DIR}/themes/ ${WEB_DIR}/themes/
COPY theme/icons/ ${WEB_DIR}/icons/
COPY theme/images/ ${WEB_DIR}/images/
COPY theme/themes/ ${WEB_DIR}/themes/

RUN cat >> "${WEB_DIR}/themes/css/xtheme-dark.css" <<'EOF'

/* Deluge 2.2 / ExtJS fixes */
.x-form-field-wrap .x-form-spinner-trigger,
.x-form-field-wrap .x-form-trigger {
    background-image: none !important;
}
.x-form-field-wrap .x-form-spinner-trigger {
    background-color: #4a4a4a !important;
    border-left: 1px solid #555 !important;
}
.x-form-field-wrap .x-form-spinner-over,
.x-form-field-wrap .x-form-spinner-click {
    background-image: none !important;
}

/* Deluge 2.2 / Preferences layout fix */
/* ExtJS sets these fieldsets to height: 132px, hiding the lower controls. */
.x-column-inner .x-fieldset.x-column {
    height: 170px !important;
}
EOF

# LinuxServer runs Deluge with the PUID/PGID supplied at runtime. The base
# image assets may be root-owned with restrictive modes, so keep them readable
# by the runtime user on both Linux and Docker Desktop/macOS.
RUN chmod -R a+rX \
    "${WEB_DIR}/icons" \
    "${WEB_DIR}/images" \
    "${WEB_DIR}/themes"

# ExtJS requests this transparent spacer even when trigger backgrounds are
# disabled. Keep it available in custom/theme builds.
RUN if [ ! -f "${WEB_DIR}/images/s.gif" ]; then \
        printf '%s' 'R0lGODlhAQABAIAAAAAAAP///ywAAAAAAQABAAACAUwAOw==' | base64 -d > "${WEB_DIR}/images/s.gif"; \
    fi
