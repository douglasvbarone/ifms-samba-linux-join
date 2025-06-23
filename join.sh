#!/bin/bash
echo "Installing necessary packages..."
sudo apt -y install realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit -y >/dev/null
clear
echo "Completed installation of necessary packages. Now printing discovered Kerberos realms..."
realm discover

echo "Your domain and its properties should be printed above. If they are not, check DNS config."
read -p "What is the Kerberos realm? (dom.example.com)? " REALMAD
read -p "What is the domain controllers short hostname ? ('dc' part of dc.dom.example.com)? " REALMDC
read -p "What is the domain admin username? " REALMADMIN
read -p "What is the new hostname? (Ex.: PP-000123) (default: $(hostname)) " NEWHOST

if [ -z "$NEWHOST" ]; then
    NEWHOST=$(hostname)
fi
shorthost=${HOSTNAME%%.*}

if [ "$NEWHOST" != "$shorthost" ]; then
    echo "Setting hostname to $NEWHOST"
    sudo hostnamectl set-hostname "$NEWHOST"
else
    echo "Hostname is already set to $NEWHOST"
fi

# Set the hostname in /etc/hosts
echo "Setting hostname in /etc/hosts"
sudo sed -i "s/^127\.0\.1\.1.*/127.0
.1.1 $NEWHOST $NEWHOST.$REALMAD/" /etc/hosts
# Set the hostname in /etc/hostname
echo "Setting hostname in /etc/hostname"
echo "$NEWHOST" | sudo tee /etc/hostname

mkdir /etc/univention
echo "Connecting to "$REALMDC.$REALMAD" UCS server and pulling UCS config. Password for domain admin will be prompted."
ssh -n root@$REALMDC.$REALMAD 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master
echo "master_ip="$REALMDC.$REALMAD"" >>/etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master

. /etc/univention/ucr_master

# Create an account and save the password
echo "Creating computer account on "$REALMDC.$REALMAD" UCS server. Password for domain admin will be prompted."
password="$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)"
ssh -n root@$REALMDC.$REALMAD udm computers/linux create \
    --position "cn=computers,${ldap_base}" \
    --set name=$(hostname) --set password="${password}" \
    --set operatingSystem="$(lsb_release -is)" \
    --set operatingSystemVersion="$(lsb_release -rs)"
printf '%s' "$password" >/etc/ldap.secret
chmod 0400 /etc/ldap.secret

echo "Performing domain join operation. Password for domain admin will be prompted."
sudo realm join -v -U "$REALMADMIN" "$REALMAD"

# Create ldap.conf
sudo rm /etc/ldap/ldap.conf
echo 'TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base' | sudo tee /etc/ldap/ldap.conf

echo "Activating mkhomedir module..."
echo 'Name: activate mkhomedir
Default: yes
Priority: 900
Session-Type: Additional
Session:
        required  pam_mkhomedir.so umask=0022 skel=/etc/skel' | sudo tee /usr/share/pam-configs/mkhomedir
sudo pam-auth-update --enable mkhomedir
sudo systemctl restart sssd

# Do not require users to type @$REALMAD when logging in
echo "Configuring SSSD to not require domain suffix..."
sudo sed -i 's/^use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
sudo sed -i 's/^fallback_homedir = \/home\/%u/fallback_homedir = \/home\/%u@'$REALMAD'/' /etc/sssd/sssd.conf
sudo chmod 600 /etc/sssd/sssd.conf
sudo systemctl restart sssd

# Make admins group members sudoers
echo "Adding domain admins group to sudoers..."
echo "%Domain\ Admins ALL=(ALL) ALL" | sudo tee /etc/sudoers.d/99_domain_admins
sudo chmod 440 /etc/sudoers.d/99_domain_admins

#prompt
read -r -p "UCS Domain Join Complete! REBOOT NOW? [y/N] " rebootnow
if [[ "$rebootnow" =~ ^([yY][eE][sS]|[yY])+$ ]]; then
    echo "Rebooting!"
    sudo reboot
else
    read -p "Reboot not selected. Press any key to finish with script."
fi
