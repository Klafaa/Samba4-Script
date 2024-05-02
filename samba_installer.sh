
#!/bin/bash

# Ellenőrizzük, hogy a felhasználó sudo-val futtatja-e a scriptet
if [ "$(id -u)" -ne 0 ]; then
    echo "Hiba: A scriptet sudo-val kell futtatni. Példa: sudo ./script.sh" >&2
    exit 1
fi

read -p "Kérem, adja meg az ip címér: [192.168.0.254] " ip_address
ip_address=${ip_address:-192.168.50.52}

read -p "Kérem, adja meg a DNS szerver: [8.8.8.8] " dns_server
dns_server=${dns_server:-8.8.8.8}

read -p "Kérem, adja meg az alapértelmezett átjárót: [$(echo "$ip_address" | cut -d'.' -f1).$(echo "$ip_address" | cut -d'.' -f2).$(echo "$ip_address" | cut -d'.' -f3).1] " default_geatway
default_geatway=${default_geatway:-$(echo "$ip_address" | cut -d'.' -f1).$(echo "$ip_address" | cut -d'.' -f2).$(echo "$ip_address" | cut -d'.' -f3).1}

read -p "Kérem, adja meg az alálozati maszkot: [/24] " default_mask
default_mask=${default_mask:-24}

read -p "Kérem, adja meg a REALM-ot: [DC.SZERVER.LAN] " realm
realm=${realm:-DC.SZERVER.LAN}

read -p "Kérem a WAN network kártyát: [enp0s3] " wan_card
wan_card=${wan_card:-enp0s3}

read -s -p "Kérem az Admin jelszót: [Teszt123456789] " admin_pass
admin_pass=${admin_pass:-Teszt123456789}

timedatectl set-timezone Europe/Budapest
apt update -y
apt upgrade -y

# Hálózati csatolók Fix-Ip címek beállítása

rm -f /etc/netplan/*.yaml

echo "
network:
  version: 2
  ethernets:
    $wan_card:
      addresses: [$ip_address/$default_mask]
      gateway4: $default_geatway
      nameservers:
        addresses: [$dns_server]
        search: [$(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)]" > /etc/netplan/NIC.yaml


# Systemd-Resolved service kiírása
systemctl disable systemd-resolved.service
systemctl stop systemd-resolved


rm -f /etc/resolv.conf

echo "nameserver $dns_server" > /etc/resolv.conf
echo "search $(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)" >> /etc/resolv.conf
echo "domain $(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)" >> /etc/resolv.conf


#DNS beállítása
sed -i '1,2 s/^/# /' /etc/hosts
echo "" >> /etc/hosts
echo "127.0.0.1 localhost" >> /etc/hosts
echo "$ip_address $realm $(echo "$realm" | cut -d'.' -f1)" >> /etc/hosts


# NTP szerver telepítése
apt install chrony -y

# SAMA AD/DC
export DEBIAN_FRONTEND=noninteractive

apt install samba smbclient winbind krb5-user krb5-config -y
rm -f /etc/krb5.conf
rm -f /etc/samba/smb.conf

samba-tool domain provision --use-rfc2307 --option="interfaces=$wan_card lo" --option="bind interfaces only=yes" --realm=$(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3) --domain=$(echo "$realm" | cut -d'.' -f2) --server-role=dc --dns-backend=SAMBA_INTERNAL --adminpass=$admin_pass

cp /var/lib/samba/private/krb5.conf /etc/

systemctl stop smbd nmbd winbind
systemctl disable smbd nmbd winbind
systemctl unmask samba-ad-dc
systemctl start samba-ad-dc
systemctl enable samba-ad-dc

samba-tool dns zonecreate $ip_address $(echo "$ip_address" | cut -d'.' -f3).$(echo "$ip_address" | cut -d'.' -f2).$(echo "$ip_address" | cut -d'.' -f1).in-addr.arpa -U Administrator --password=$admin_pass

echo "nameserver $ip_address" > /etc/resolv.conf
echo "search $(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)" >> /etc/resolv.conf
echo "domain $(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)" >> /etc/resolv.conf



host -t A $realm
host -t SRV _kerberos.udp.$(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)
host -t SRV _ldap._tcp.$(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)

chown root:_chrony /var/lib/samba/ntp_signd/
chmod 750 /var/lib/samba/ntp_signd/

echo "" >> /etc/chrony/chrony.conf
echo "bindcmdaddress $ip_address" >> /etc/chrony/chrony.conf
echo "allow $(echo "$ip_address" | cut -d'.' -f1).$(echo "$ip_address" | cut -d'.' -f2).$(echo "$ip_address" | cut -d'.' -f3).0/$default_mask" >> /etc/chrony/chrony.conf
echo "ntpsigndsocket /var/lib/samba/ntp_signd/" >> /etc/chrony/chrony.conf

chronyc tracking
chronyc sources

# SMB.config
echo "
# Global parameters
[global]
    bind interfaces only = yes
    dns forwarder = $dns_server
    interfaces = $wan_card lo
    inherit acls = yes
    netbios name = $(echo "$realm" | cut -d'.' -f1)
    realm = $(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)
    server role = active directory domain controller
    workgroup = $(echo "$realm" | cut -d'.' -f2)
    store dos attributes = yes
    vfs objects = dfs_samba4, acl_xattr, catia
    idmap_ldb:use rfc2307 = yes
    acl_xattr:ignore system acls = yes
    acl_xattr:default acl style = windows
    mangled names = no
    catia:mappings = 0x22:0xa8,0x2a:0xa4,0x2f:0xf8,0x3a:0xf7,0x3c:0xab,0x3e:0xbb0x3f:0xbf,0x5c:0xff,0x7c:0xa6
[sysvol]
        path = /var/lib/samba/sysvol
        read only = No
[netlogon]
        path = /var/lib/samba/sysvol/$(echo "$realm" | cut -d'.' -f2).$(echo "$realm" | cut -d'.' -f3)/scripts
        read only = No

" > /etc/samba/smb.conf
