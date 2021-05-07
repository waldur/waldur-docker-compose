# TLS credentials

Please add key and certificate files to this folder in the format:

- ``domain.name.key`` - private key, domain.name should be equal to the value of ``WALDUR_DOMAIN``
- ``domain.name.crt`` - certificate, domain.name should be equal to the value of ``WALDUR_DOMAIN``

See [https://github.com/nginx-proxy/nginx-proxy](https://github.com/nginx-proxy/nginx-proxy) for more details.