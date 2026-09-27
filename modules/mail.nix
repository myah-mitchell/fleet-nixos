# Postfix, for mail the host itself sends, such as a failed job's report.
# It listens on no network port. Mail for root goes to the admin list.
{ config, lib, ... }:
let
  cfg = config.fleet;
in
{
  config = lib.mkIf cfg.features.mail {
    services.postfix = {
      enable = true;
      rootAlias = cfg.adminList;
      settings.main = {
        myhostname = cfg.fqdn;
        mydestination = [
          cfg.fqdn
          "localhost.${cfg.locationDomain}"
          "localhost.${cfg.domainName}"
          "localhost"
        ];
        smtpd_banner = "$myhostname ESMTP";
        master_service_disable = "inet";
      };
    };

    environment.etc.mailname.text = "${cfg.fqdn}\n";
  };
}
