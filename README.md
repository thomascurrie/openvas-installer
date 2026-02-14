Do a dnf update -y && dnf install -y nano
# Disable selinux
nano -w /etc/selinux/config
# SELINUX=disabled

Reboot then run 

sudo bash atomic-openvas-install.sh
