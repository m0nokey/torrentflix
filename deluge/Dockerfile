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

/* Deluge 2.2 / Preferences layout fixes */
/* Keep the lower Queue fields reachable on short screens. */
body:has(#max_download_speed) .x-window {
    max-height: calc(100vh - 24px) !important;
}

body:has(#max_download_speed) .x-window-body {
    max-height: calc(100vh - 105px) !important;
    overflow-y: auto !important;
    overflow-x: hidden !important;
}

body:has(#max_download_speed) .x-column-inner {
    height: auto !important;
    min-height: 0 !important;
    padding-bottom: 18px !important;
}

body:has(#max_download_speed) .x-fieldset {
    margin-bottom: 10px !important;
}
EOF

# LinuxServer runs Deluge with the PUID/PGID supplied at runtime. The base
# image assets may be root-owned with restrictive modes, so keep them readable
# by the runtime user on both Linux and Docker Desktop/macOS.
RUN chmod -R a+rX \
    "${WEB_DIR}/icons" \
    "${WEB_DIR}/images" \
    "${WEB_DIR}/themes"
