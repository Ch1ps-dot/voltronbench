#!/bin/bash
subjects=(lightftp-vol bftpd-vol proftpd-vol pure-ftpd-vol exim-vol live555-vol kamailio-vol forked-daapd-vol lighttpd1-vol dnsmasq-vol tinydtls-vol openssh-vol openssl-vol)
for subject in ${subjects[@]};
do
    # Delete All containers based on the image
    { docker ps -a -q  --filter ancestor=${subject}:latest | xargs docker stop 2> /dev/null | xargs docker rm 2> /dev/null ; } 2>&1 > /dev/null
    # Delete the image
    docker rmi $subject 2> /dev/null
done

echo "Clean complete"
