# Expected file list

- login-logo.png
- sidebar-logo.png
- privacy.html
- privacy-full.html
- tos.html
- favicon.ico

Don't forget to adjust `config/waldur-homeport/nginx.conf`, e.g.:

```nginx
    location /login-logo.png {
        alias /opt/waldur-homeport/login-logo.png;
    }

    location /sidebar-logo.png {
        alias /opt/waldur-homeport/sidebar-logo.png;
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
