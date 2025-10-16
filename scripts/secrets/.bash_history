cd /var/log
ls -la
cat syslog
whoami
su root
# Oops! I typed my password instead of username
super_secret_password_123
su root
# There we go
ssh admin@bank.poo
# Password: admin123
cd /etc
cat shadow
grep root /etc/passwd
find / -name "*.key"
find / -name "*.pem"
# Found some SSH keys!
cat /home/admin/.ssh/id_rsa
# This could be useful...
history
history -c
# Nice try, but I already logged your history!
