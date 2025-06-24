#!/bin/bash
echo "Instalando pacotes necessários..."
sudo apt-get -y install realmd libnss-sss libpam-sss sssd sssd-tools adcli samba-common-bin oddjob oddjob-mkhomedir packagekit -y >/dev/null
clear

REALMAD=acad.pp.ifms.edu.br
REALMDC=acad

DEFAULTNEWHOST="PP-$(tr -dc A-Za-z0-9 </dev/urandom | head -c6)"

read -p "Qual é o novo nome do host? (Ex.: PP-000123) (padrão: $DEFAULTNEWHOST) " NEWHOST

if [ -z "$NEWHOST" ]; then
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

echo "Executando a operação de ingresso no domínio. A senha do administrador do domínio será solicitada."
sudo realm join -v -U "$REALMADMIN" "$REALMAD"

# Create ldap.conf
sudo rm /etc/ldap/ldap.conf
echo 'URI ldap://$ldap_master:7389
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
read -r -p "Ingresso no Domínio Concluído! REINICIAR AGORA? [s/N] " rebootnow
if [[ "$rebootnow" =~ ^([sS][iI][mM]|[sS])+$ ]]; then
    echo "Reiniciando!"
    sudo reboot
else
    read -p "Reinicialização não selecionada. Pressione qualquer tecla para finalizar o script."
fi
