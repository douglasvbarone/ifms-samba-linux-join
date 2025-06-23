#!/bin/bash
echo "Instalando pacotes necessários..."
sudo apt-get -y install realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit -y >/dev/null
clear
REALMAD=acad.pp.ifms.edu.br
REALMDC=acad

DEFAULTNEWHOST="PP-$(tr -dc A-Za-z0-9 </dev/urandom | head -c6)"

read -p "Qual é o novo nome do host? (Ex.: PP-000123) (padrão: $DEFAULTNEWHOST) " NEWHOST

if [ -z "$NEWHOST" ]; then
    # Generate a random hostname if none is provided
    NEWHOST="$DEFAULTNEWHOST"
fi

shorthost=${HOSTNAME%%.*}

if [ "$NEWHOST" != "$shorthost" ]; then
    echo "Definindo o nome do host para $NEWHOST"
    sudo hostnamectl set-hostname "$NEWHOST"
else
    echo "O nome do host já está definido como $NEWHOST"
fi

read -p "Qual é o nome de usuário do administrador do domínio? " REALMADMIN

# Set the hostname in /etc/hosts
echo "Definindo o nome do host em /etc/hosts"
sudo sed -i "s/^127\.0\.1\.1.*/127.0
.1.1 $NEWHOST $NEWHOST.$REALMAD/" /etc/hosts
# Set the hostname in /etc/hostname
echo "Definindo o nome do host em /etc/hostname"
echo "$NEWHOST" | sudo tee /etc/hostname

mkdir /etc/univention
echo "Conectando-se ao servidor UCS "$REALMDC.$REALMAD" e baixando a configuração do UCS. A senha do administrador do domínio será solicitada."
ssh -n root@$REALMDC.$REALMAD 'ucr shell | grep -v ^hostname=' >/etc/univention/ucr_master
echo "master_ip="$REALMDC.$REALMAD"" >>/etc/univention/ucr_master
chmod 660 /etc/univention/ucr_master

. /etc/univention/ucr_master

# Create an account and save the password
echo "Criando conta de computador no servidor UCS "$REALMDC.$REALMAD". A senha do administrador do domínio será solicitada."
password="$(tr -dc A-Za-z0-9_ </dev/urandom | head -c20)"
ssh -n root@$REALMDC.$REALMAD udm computers/linux create \
    --position "cn=computers,${ldap_base}" \
    --set name=$(hostname) --set password="${password}" \
    --set operatingSystem="$(lsb_release -is)" \
    --set operatingSystemVersion="$(lsb_release -rs)"
printf '%s' "$password" >/etc/ldap.secret
chmod 0400 /etc/ldap.secret

echo "Executando a operação de ingresso no domínio. A senha do administrador do domínio será solicitada."
sudo realm join -v -U "$REALMADMIN" "$REALMAD"

# Create ldap.conf
sudo rm /etc/ldap/ldap.conf
echo 'TLS_CACERT /etc/univention/ssl/ucsCA/CAcert.pem
URI ldap://$ldap_master:7389
BASE $ldap_base' | sudo tee /etc/ldap/ldap.conf

echo "Ativando o módulo mkhomedir..."
echo 'Name: activate mkhomedir
Default: yes
Priority: 900
Session-Type: Additional
Session:
        required  pam_mkhomedir.so umask=0022 skel=/etc/skel' | sudo tee /usr/share/pam-configs/mkhomedir
sudo pam-auth-update --enable mkhomedir
sudo systemctl restart sssd

# Do not require users to type @$REALMAD when logging in
echo "Configurando o SSSD para não exigir o sufixo de domínio..."
sudo sed -i 's/^use_fully_qualified_names = True/use_fully_qualified_names = False/' /etc/sssd/sssd.conf
#sudo sed -i 's/^fallback_homedir = \/home\/%u/fallback_homedir = \/home\/%u@'$REALMAD'/' /etc/sssd/sssd.conf
sudo chmod 600 /etc/sssd/sssd.conf
sudo systemctl restart sssd

# Make admins group members sudoers
echo "Adicionando o grupo de administradores do domínio aos sudoers..."
echo "%Domain\ Admins ALL=(ALL) ALL" | sudo tee /etc/sudoers.d/99_domain_admins
sudo chmod 440 /etc/sudoers.d/99_domain_admins

#prompt
read -r -p "Ingresso no Domínio UCS Concluído! REINICIAR AGORA? [s/N] " rebootnow
if [[ "$rebootnow" =~ ^([sS][iI][mM]|[sS])+$ ]]; then
    echo "Reiniciando!"
    sudo reboot
else
    read -p "Reinicialização não selecionada. Pressione qualquer tecla para finalizar o script."
fi
