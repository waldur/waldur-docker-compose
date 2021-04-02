# Expected file list:
- login-logo.png
- sidebar-logo.png
- privacy.html
- privacy-full.html
- tos.html
- favicon.ico

Don't forgret to adjust `config/waldur-homeport/nginx.conf`, e.g.:
```
    location /login-logo.png {
        alias /opt/waldur-homeport/login-logo.png;
        expires 4h;
    }

    location /sidebar-logo.png {
        alias /opt/waldur-homeport/sidebar-logo.png;
        expires 4h;
    }

    location /views/policy/privacy.html {
        alias /opt/waldur-homeport/privacy.html;
    }

    location /views/policy/privacy-full.html {
        alias /opt/waldur-homeport/privacy-full.html;
    }

    location /views/tos/index.html {
        alias /opt/waldur-homeport/tos.html;
    }
```
