# The Linux audit system: the kernel records the events the rules ask for,
# and auditd writes them to /var/log/audit.
#
# The rules that name no store path are the files in auditd-rules, loaded
# in the order of their names. A line that starts with # is a comment.
{
  config,
  lib,
  ...
}:
let
  cfg = config.fleet;

  ruleFiles = lib.filter (lib.hasSuffix ".rules") (lib.attrNames (builtins.readDir ./auditd-rules));

  rulesIn =
    file:
    lib.filter (line: line != "" && !lib.hasPrefix "#" line) (
      map lib.trim (lib.splitString "\n" (builtins.readFile (./auditd-rules + "/${file}")))
    );

  # The programs behind these rules live in the store, under a path that
  # changes with every new version, so the rules are written here, where
  # the path is known. A rule has to name the file itself. One that names
  # a link to it, as the entries in /run/current-system/sw/bin are, would
  # never match.
  auditTools = map (tool: "${config.security.audit.package}/bin/${tool}") [
    "ausearch"
    "aureport"
    "aulast"
    "aulastlog"
  ];

  storePathRules = [
    # systemd-run starts a program as any user, without sudo.
    "-a always,exit -F path=${config.systemd.package}/bin/systemd-run -F perm=x -F auid!=unset -F key=maybe-escalation"

    # A session that becomes root through su or sudo.
    "-a always,exit -F arch=b64 -S setuid -F a0=0 -F exe=${config.security.wrappers.su.source} -F key=elevated-privs-session"
    "-a always,exit -F arch=b32 -S setuid -F a0=0 -F exe=${config.security.wrappers.su.source} -F key=elevated-privs-session"
    "-a always,exit -F arch=b64 -S setresuid -F a0=0 -F exe=${config.security.wrappers.sudo.source} -F key=elevated-privs-session"
    "-a always,exit -F arch=b32 -S setresuid -F a0=0 -F exe=${config.security.wrappers.sudo.source} -F key=elevated-privs-session"
  ]
  # The tools that read the audit log.
  ++ map (tool: "-a always,exit -F path=${tool} -F perm=x -F key=access-audit-trail") auditTools;

  # Records what root and the admin type in a session they reached through
  # sudo or su, and nobody else's keystrokes.
  keystrokes = {
    ttyAudit = {
      enable = true;
      disablePattern = "*";
      enablePattern = "root,${cfg.adminName}";
    };
  };
in
{
  config = lib.mkIf cfg.features.auditd {
    security.auditd.enable = true;
    security.audit = {
      enable = true;
      backlogLimit = 8192;
      failureMode = "printk";
      rules = lib.concatMap rulesIn ruleFiles ++ storePathRules;
    };

    # Some rules name files and folders that are made during boot, and a
    # rule for a path that does not exist cannot be loaded. The rules are
    # therefore loaded after the services that make those paths.
    systemd.tmpfiles.settings."20-auditd"."/var/log/audit".d = {
      user = "root";
      group = "root";
      mode = "0700";
    };
    systemd.services.audit-rules-nixos.after = [
      "systemd-tmpfiles-setup.service"
      "suid-sgid-wrappers.service"
    ];

    security.pam.services = lib.genAttrs [
      "sudo"
      "su"
    ] (_: keystrokes);
  };
}
