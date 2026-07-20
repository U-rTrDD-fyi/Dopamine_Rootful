set -e

# The "-ssh" bootstraps are the same Procursus rootfs plus openssh-server,
# -client and -sftp-server, /etc/ssh/sshd_config, and the com.openssh.sshd
# LaunchDaemon (~1.1 MB extra each). launchdhook already loads daemons from
# <jbroot>/Library/LaunchDaemons, and that plist is socket-activated on ports
# 22 and 2222, so sshd comes up on every boot with no extra wiring.
#
# DOBootstrapper's fallback download URL already pointed at the -ssh variant;
# this keeps the bundled copy consistent with it.

curl -L https://apt.procurs.us/bootstraps/1800/bootstrap-ssh-iphoneos-arm64.tar.zst --output bootstrap_1800.tar.zst
curl -L https://apt.procurs.us/bootstraps/1900/bootstrap-ssh-iphoneos-arm64.tar.zst --output bootstrap_1900.tar.zst
