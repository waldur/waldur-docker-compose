# HomePort customisation

This folder is mounted at `/opt/waldur-homeport` in the `waldur-homeport`
container, but the HomePort image reads nothing from it. Files placed here have
no effect. Customise the portal where the settings are actually read:

- **Logos and favicon**: put the images in `config/whitelabeling/` and refer to
  them in `config/waldur-mastermind/whitelabeling.yaml` as
  `/etc/waldur/icons/<file name>`, for example `login_logo`, `sidebar_logo`
  and `favicon`. HomePort fetches them from the API.
- **Terms of service and privacy policy**: these are stored by mastermind and
  loaded from HTML files by the `waldur-mastermind-db-migration` service. See
  "Terms of service and privacy policy" in the top-level `README.md`.
- **Page title**: `WALDUR_TITLE` in `.env`.
- **Content-Security-Policy and other response headers**: the image generates
  its nginx configuration at start; set the `CSP_*` variables in `.env`.
