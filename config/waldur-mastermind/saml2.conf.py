# Custom SAML2 configuration
WALDUR_AUTH_SAML2.update({
    # PEM formatted certificate chain file
    'CERT_FILE': '/etc/waldur/saml2/credentials/sp.crt',
    # PEM formatted certificate key file
    'KEY_FILE': '/etc/waldur/saml2/credentials/sp.pem',
})
