# Custom SAML2 configuration
WALDUR_AUTH_SAML2.update({
    # PEM formatted certificate chain file
    'cert_file': '/etc/waldur/saml2/credentials/sp.crt',
    # PEM formatted certificate key file
    'key_file': '/etc/waldur/saml2/credentials/sp.pem',
})
