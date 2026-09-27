# Node Exporter serves the host's metrics on port 9100, over TLS and behind
# a password. The scraper is the vmagent container on the same host, which
# mounts two files from /etc/node-exporter: the certificate, to check the
# exporter against, and the password, to log in with.
#
# The password and the certificate are made on the host, the first time it
# boots, and kept under /srv/persist. They are in no repository.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.fleet;
  state = "/srv/persist/host/node-exporter";
  shared = "/etc/node-exporter";
  scrapeUser = "node-exporter-user";

  # The user id and group id that container uid 1000 has on the host.
  scrapeOwner = "101000";
in
{
  config = lib.mkIf cfg.features.nodeExporter {
    systemd.services.node-exporter-credentials = {
      description = "Password and certificate for Node Exporter";
      wantedBy = [ "multi-user.target" ];
      requiredBy = [ "prometheus-node-exporter.service" ];
      # Docker would make a folder where a container mounts a file that is
      # not there yet, so the files exist before Docker starts.
      before = [
        "prometheus-node-exporter.service"
        "docker.service"
      ];
      unitConfig.RequiresMountsFor = "/srv/persist";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "node-exporter";
        RuntimeDirectoryMode = "0700";
      };
      path = [
        pkgs.coreutils
        pkgs.diffutils
        pkgs.mkpasswd
        pkgs.openssl
      ];
      script = ''
        umask 077
        mkdir -p ${state}

        if [ ! -s ${state}/scrape-password ]; then
          password=$(openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c 40)
          printf '%s' "$password" > ${state}/scrape-password
        fi

        if [ ! -s ${state}/node_exporter.key ] || [ ! -s ${state}/node_exporter.crt ]; then
          openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
            -keyout ${state}/node_exporter.key \
            -out ${state}/node_exporter.crt \
            -subj "/C=US/ST=MyState/L=MyCity/O=MyOrg/CN=node-exporter" \
            -addext "subjectAltName=DNS:${cfg.fqdn}"
        fi

        # A file that is already right is left alone. A container that has
        # it mounted would otherwise keep reading the replaced copy.
        mkdir -p -m 0755 ${shared}
        chmod 0755 ${shared}
        if ! cmp -s ${state}/node_exporter.crt ${shared}/node_exporter.crt; then
          install -m 0644 ${state}/node_exporter.crt ${shared}/node_exporter.crt
        fi
        if ! cmp -s ${state}/scrape-password ${shared}/scrape-password; then
          install -m 0400 ${state}/scrape-password ${shared}/scrape-password
        fi
        chown ${scrapeOwner}:${scrapeOwner} ${shared}/scrape-password

        # The exporter is given the bcrypt hash of the password, never the
        # password itself.
        hash=$(mkpasswd -m bcrypt -R 12 --stdin < ${state}/scrape-password)
        cat > /run/node-exporter/web.yml <<END
        tls_server_config:
          cert_file: node_exporter.crt
          key_file: node_exporter.key
        basic_auth_users:
          ${scrapeUser}: "$hash"
        END
      '';
    };

    services.prometheus.exporters.node = {
      enable = true;
      port = 9100;
      openFirewall = true;
      # %d is the folder systemd puts the credentials below in, readable by
      # the exporter's own user and by nobody else.
      extraFlags = [ "--web.config.file=%d/web.yml" ];
    };

    systemd.services.prometheus-node-exporter.serviceConfig.LoadCredential = [
      "web.yml:/run/node-exporter/web.yml"
      "node_exporter.crt:${state}/node_exporter.crt"
      "node_exporter.key:${state}/node_exporter.key"
    ];
  };
}
