# Adds the fleet's own certificate authorities to the system trust store.
{ config, lib, ... }:
{
  security.pki.certificates = map (
    certificate: if lib.isString certificate then certificate else certificate.content
  ) config.fleet.caCertificates;
}
